#!/usr/bin/env python3
"""Top symbols by inclusive and self sample time, from a Time Profiler export.

Counting the samples whose call chain **contains** a symbol is the only attribution
that survives this trace's noise: the leaves are allocator / CoreFoundation / CA-submit
chatter with no single hotspot, so ranking by leaf overweights whatever is cheapest and
most frequent (see `Docs/Internal/performance.md`).

The export deduplicates elements: the first occurrence of a `frame`, `backtrace`,
`weight`, `thread` or `thread-state` carries its value inline and every later one is a
bare `ref`. All five are resolved through one id table here — treating an inline first
occurrence as unresolved drops whole samples and understates every symbol's share.

Usage:
    top_symbols.py run.xml                  main thread, top 20 by inclusive
    top_symbols.py run.xml --json           machine-readable, for the harness
    top_symbols.py run.xml --all-threads
    top_symbols.py run.xml --symbol step    print the chains containing a symbol
"""

import argparse
import json
import re
import sys
import xml.etree.ElementTree as ET

# Named areas, so a run says *where* its CPU went rather than only which single symbol
# was heaviest. The patterns are matched against every frame name in the chain, so an
# area's total is the time spent anywhere under that code.
AREAS = {
    "tick": [r"PetController\.step\(_:\)"],
    "terrain": [
        r"SurfaceProvider",
        r"SurfaceBuilder",
        r"MacOSPlatform\.(windows|publicWindows)\(\)",
    ],
    "enclosure": [r"WindowEnclosurePhysics", r"updateWindowEnclosure"],
    "live-read": [r"liveBounds", r"liveWindowSurface", r"GetWindowBounds"],
    "window-list": [r"SLWindowListCopyWindowInfo", r"CGWindowListCopyWindowInfo"],
    "animation": [r"SpriteAnimator", r"PetAnimator", r"animator"],
    "compositing": [
        r"CATransaction",
        r"CA::Transaction",
        r"CALayer",
        r"CA::Layer",
        r"displayIfNeeded",
    ],
    "sprite": [r"argb32", r"CGImage", r"resample"],
    "window-move": [r"setFrame", r"SetWindowBounds", r"CGSMoveWindow"],
    "input": [r"sendEvent", r"mouseDragged", r"NSEvent", r"nextEvent"],
    "logging": [r"writeEvent", r"DiagnosticsLog"],
    "accessibility": [r"AXUIElement", r"AX[A-Z]\w+"],
    "voice": [r"AVSpeech", r"NSSpeech", r"SpeechSynthesizer"],
    "run-loop": [r"__CFRunLoop", r"CFRunLoopRun"],
}


def resolve(element, values, default):
    if element is None:
        return default
    # The first occurrence is inline and carries an `id`; every later one is a `ref`.
    key = element.get("ref")
    if key is None:
        key = element.get("id")
    if key is None:
        return default
    return values.get(key, default)


def analyze(path, thread_filter, top, symbol):
    values = {}
    total_ms = 0.0
    total_samples = 0
    thread_ms = 0.0
    thread_samples = 0
    inclusive = {}
    self_ms = {}
    samples = {}
    areas = {label: 0.0 for label in AREAS}
    compiled = {
        label: [re.compile(p) for p in patterns] for label, patterns in AREAS.items()
    }
    chains = []
    needle = re.compile(symbol) if symbol else None

    for _, element in ET.iterparse(path, events=("end",)):
        tag = element.tag
        identifier = element.get("id")

        if tag == "frame":
            values[identifier] = element.get("name", "")
            continue
        if tag == "backtrace":
            values[identifier] = [
                values.get(frame.get("ref")) or frame.get("name", "")
                for frame in element
            ]
            continue
        if tag == "weight":
            values[identifier] = int(element.text or 0)
            continue
        if tag in ("thread", "thread-state"):
            values[identifier] = element.get("fmt", "")
            continue
        if tag != "row":
            continue

        weight = resolve(element.find("weight"), values, 0)
        state = resolve(element.find("thread-state"), values, None)
        thread = resolve(element.find("thread"), values, "")
        stack = resolve(element.find("backtrace"), values, [])
        element.clear()

        # The export carries blocked samples too, and no CPU is spent while blocked.
        if state not in (None, "Running"):
            continue
        milliseconds = int(weight) / 1e6
        total_ms += milliseconds
        total_samples += 1
        if thread_filter and thread_filter not in thread:
            continue

        thread_ms += milliseconds
        thread_samples += 1
        if needle and any(needle.search(name) for name in stack):
            chains.append({"ms": round(milliseconds, 3), "stack": stack})
        for name in set(stack):
            inclusive[name] = inclusive.get(name, 0.0) + milliseconds
            samples[name] = samples.get(name, 0) + 1
        if stack:
            self_ms[stack[0]] = self_ms.get(stack[0], 0.0) + milliseconds
        for label, patterns in compiled.items():
            if any(pattern.search(name) for name in stack for pattern in patterns):
                areas[label] += milliseconds

    def ranking(table):
        return [
            {
                "name": name,
                "inclusive_ms": round(inclusive.get(name, 0.0), 1),
                "self_ms": round(self_ms.get(name, 0.0), 1),
                "samples": samples.get(name, 0),
                "share_of_thread": round(100 * inclusive.get(name, 0.0) / thread_ms, 2)
                if thread_ms
                else 0,
            }
            for name in sorted(table, key=lambda key: table[key], reverse=True)[:top]
        ]

    return {
        "total_ms": round(total_ms, 1),
        "total_samples": total_samples,
        "thread": thread_filter or "(all)",
        "thread_ms": round(thread_ms, 1),
        "thread_samples": thread_samples,
        "thread_share_of_total": round(100 * thread_ms / total_ms, 1)
        if total_ms
        else 0,
        "top_inclusive": ranking(inclusive),
        "top_self": ranking(self_ms),
        "areas": {
            label: {
                "inclusive_ms": round(value, 1),
                "share_of_thread": round(100 * value / thread_ms, 2)
                if thread_ms
                else 0,
            }
            for label, value in sorted(
                areas.items(), key=lambda item: item[1], reverse=True
            )
        },
        "chains": sorted(chains, key=lambda entry: entry["ms"], reverse=True)[:5],
    }


def print_report(result):
    print(
        f"main thread {result['thread_ms'] / 1000:.2f} s of {result['total_ms'] / 1000:.2f} s"
        f" total ({result['thread_share_of_total']}%)"
        f"  samples {result['thread_samples']}"
    )
    print()
    print(f"{'inclusive':>10} {'%':>6} {'self':>9}  symbol")
    for entry in result["top_inclusive"]:
        print(
            f"{entry['inclusive_ms']:>10.1f} {entry['share_of_thread']:>6.2f}"
            f" {entry['self_ms']:>9.1f}  {entry['name'][:90]}"
        )
    print()
    print("areas (inclusive, share of main thread)")
    for label, value in result["areas"].items():
        if value["inclusive_ms"] <= 0:
            continue
        print(
            f"{value['inclusive_ms']:>10.1f} {value['share_of_thread']:>6.2f}%  {label}"
        )
    if result["chains"]:
        print()
        print("heaviest chains containing the symbol (leaf first)")
        for entry in result["chains"]:
            print(f"  {entry['ms']:>8.2f} ms")
            for depth, name in enumerate(entry["stack"][:8]):
                print(f"    {depth}: {name[:100]}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("path")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--top", type=int, default=20)
    parser.add_argument("--thread", default="Main Thread")
    parser.add_argument("--all-threads", action="store_true")
    parser.add_argument(
        "--symbol", default=None, help="also print chains containing this regex"
    )
    options = parser.parse_args()

    thread = "" if options.all_threads else options.thread
    result = analyze(options.path, thread, options.top, options.symbol)
    if options.json:
        json.dump(result, sys.stdout)
        sys.stdout.write("\n")
        return
    print_report(result)


if __name__ == "__main__":
    main()
