#!/usr/bin/env python3
"""Measure what the pet costs while a hand moves her: a CPU reading, then a profile.

This is the **mechanism**, not the experiment. What to do with her hand is data, in a
scenarios file (`scenarios.json` beside this script by default); which bundle to run, how
long a window lasts, and which instruments to use are flags. So a new scenario is a JSON
edit, a new experiment is a command line, and neither is an edit to this file.

Every round is one launch and up to two phases, run back to back:

    Enter -> 5 s settle -> `ps` 15 s -> Time Profiler 15 s

**One Enter per round.** It is a gate, not part of the window: it is there so that reading
the instruction — and moving her into position, which is what the throwing scenarios ask
for — never eats into the measurement. The settle after it is what makes the window open
on a hand that is already where it meant to be.

**The hand never stops between the phases.** They are two instruments on one activity:
the `ps` phase is the reading and the profiler phase is the attribution *of that same
reading*, so a pause between them would leave the profile describing a hand that had
already started doing something else. Instructions are printed once for the same reason.
`--phase-gap` puts a pause there if it is ever wanted; the default is none.

The two instruments are **never overlapped**: the profiler's sampler runs inside the
process being measured, so a CPU reading taken while it is attached is not the app's own
cost. Every figure in `Docs/Internal/performance.md` was taken the same way.

The headline number is the delta of `ps -o time=` (cumulative user+system CPU — what
`getrusage` reports) over the wall time of the phase. `ps -o %cpu` is sampled every
second beside it as a second, independent view; it is not the metric.

Quiet mode is forced on, so that wherever she is not being moved she is at rest rather
than off on some errand — the same pet in every round, which is what makes the numbers
comparable (`Docs/Internal/performance.md`, "测 idle 前先把她的状态钉死"). **Which rest**
— resting awake or asleep — is the scenario's business, through its `sleepiness`: quiet
mode leaves her that choice and how sleepy she is decides it, and the two states do not
cost the same. The batch's default pins it high (asleep). Both files are snapshotted per
batch and put back afterwards.

A scenario is an instruction to a person plus, where it can be checked, the evidence that
they followed it:

    {
      "key": "boxthrow",
      "title": "窗口内抛起",
      "prep": "先在某个窗口的中间松手，让她落进窗口内部（盒子）里。",
      "gesture": "等她落到盒底，抓住她在盒子内部向上快速甩一下……",
      "expect": ["WindowEnclosureImpact"],
      "note": "每帧都在全屏表面上，所以气泡几乎全程在"
    }

`expect` and `forbid` are event names the round's log must (must not) contain, checked and
reported per round; `note` is the half a person has to judge, printed with the instruction.
`wait` holds the round until a heartbeat reports the state it needs, and `seconds` /
`settle` override the flags for one scenario. Unknown keys are an error — a misspelled
`expect` would otherwise check nothing, quietly.

Launching: the build command once for the whole batch (default: `make rerun`'s), then
`pkill` + `open -n` per round — the same LaunchServices path `make rerun` takes, without
rebuilding and re-signing ten times, each of which is a 1Password round trip. The running
process names its own renderer, live-read source and fall-refresh rate in the log, and
the harness records its executable's path and sha256: those are what make a round
attributable to a *file*. The `Bundle` field in the log is not — it is
`AppEnvironment.bundleIdentifier`, a constant.

**The bundle it launches has to be the bundle that was built.** Plain `make sign`
assembles `NuonuoChuuby.app`, while the `make rerun` path launches
`.build/app/NuonuoChuuby-Dev.app`: building the former leaves the latter stale, which is
worse than not building at all, because the round then looks freshly built while running
yesterday's code. `--bundle PATH` says which `.app` a round opens, `--build-cmd CMD` what
builds it, and `--no-build` uses whatever is already on disk.

**The log window opens when the measurement window opens**, never at launch: reading from
the launch counts everything that happened while the instruction was being read and she
was being moved into position as evidence for a round that had not begun.

Attribution needs an analyser for the exported trace (`top_symbols.py`, beside this
script; `--analyzer CMD` for another one — without any, the trace is still recorded, just
not parsed). A comparison needs the two bundles to **alternate**, one per round, which
`--bundles a=…,b=…` does; it refuses to run without `--no-build`, since both have to be
built beforehand. And `%核` tracks how much she was moved, so rounds are compared in pairs
with the same amount of it — the per-round event counts in the report are what to pair on.

Usage:
    measure.py                                    every scenario, two rounds each
    measure.py --scenarios idle,drag              a subset
    measure.py --phases ps                        the reading only, no profiler
    measure.py --phase-gap 3                      pause between the phases (default: none)
    measure.py --scenarios-file mine.json         a scenario set of one's own
    measure.py --bundles before=…,after=… --no-build   an A/B, alternating per round
    measure.py --report                           what has been collected so far
    measure.py --fresh                            discard earlier runs first
"""

import argparse
import json
import re
import shlex
import shutil
import subprocess
import sys
import time
from collections import Counter
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

ROOT = Path(__file__).resolve().parents[2]
SCRIPT_DIR = Path(__file__).resolve().parent
EXECUTABLE = "Contents/MacOS/NuonuoChuuby"
SUPPORT = Path.home() / "Library" / "Application Support" / "NuonuoChuuby"
LOG = SUPPORT / "activity.log"
SETTINGS = SUPPORT / "settings.json"
LIFE = SUPPORT / "life-state.json"

DEFAULT_OUT = ROOT / ".build" / "scenario-bench"
DEFAULT_SCENARIOS = SCRIPT_DIR / "scenarios.json"
DEFAULT_BUNDLE = ROOT / ".build" / "app" / "NuonuoChuuby-Dev.app"
# `make rerun`'s flags, so a measured round is the binary hand-testing would launch.
DEFAULT_BUILD = [
    "make",
    "sign",
    "CONFIG=release",
    "FLAGS=-Xswiftc -g",
    "APP_SUFFIX=-Dev",
    "DEV_ASSETS=1",
]
# `--json` belongs to the default analyser, not to the harness: `--analyzer CMD` is called
# as `CMD <xml>` and has to print the same JSON shape.
DEFAULT_ANALYZER = [sys.executable, str(SCRIPT_DIR / "top_symbols.py"), "--json"]
# The move counter is a local monitor — it changes nothing about delivery — and it is the
# only evidence of what the hand actually did (a CPU reading alone cannot tell a drag from
# a run where she was never picked up). One closure call per already-delivered event and
# one log line a second, in every round, so the numbers stay comparable.
#
# NOTE: it matches `.mouseMoved` only. A drag delivers `.mouseDragged`, which this does
# not count, so a low `moves/s` in the drag scenario is expected and says nothing about
# whether the drag happened — the `dragging` heartbeat and transition are what show that.
DEFAULT_APP_ARGS = ["--mouse-move-count"]

SETTLE_SECONDS = 5.0
PHASE_SECONDS = 15.0
ROUNDS = 2
# Quiet mode leaves her a choice between resting and sleeping and the two states do not
# cost the same; pinning the sleepiness high makes the choice unanimous, so every round
# measures the same pet.
FORCED_SLEEPINESS = 100

# Set by `configure()` from this batch's options. Module-level because the file is one
# batch's worth of work with one set of paths; threading an options object all the way
# down to `log_offset()` would not make anything clearer.
OUT = DEFAULT_OUT
TRACES = OUT / "traces"
RESULTS = OUT / "runs.jsonl"
# Present only while a batch is in flight. Its absence is what tells a later batch that
# the files on disk are the user's rather than the harness's.
MARKER = OUT / "batch-in-progress"
SETTINGS_BACKUP = OUT / "settings.backup.json"
LIFE_BACKUP = OUT / "life-state.backup.json"
APP_ARGS = list(DEFAULT_APP_ARGS)
ANALYZER = list(DEFAULT_ANALYZER)

EVENT = re.compile(r"event=(\w+)")
FIELDS = re.compile(r'(\w+)="([^"]*)"')


def configure(options):
    """Points the harness at the paths and commands this batch runs with."""
    global \
        OUT, \
        TRACES, \
        RESULTS, \
        MARKER, \
        SETTINGS_BACKUP, \
        LIFE_BACKUP, \
        APP_ARGS, \
        ANALYZER
    OUT = Path(options.out_dir).expanduser().resolve()
    TRACES = OUT / "traces"
    RESULTS = OUT / "runs.jsonl"
    MARKER = OUT / "batch-in-progress"
    SETTINGS_BACKUP = OUT / "settings.backup.json"
    LIFE_BACKUP = OUT / "life-state.backup.json"
    APP_ARGS = options.app_args.split() if options.app_args else []
    ANALYZER = options.analyzer.split() if options.analyzer else list(DEFAULT_ANALYZER)


def analyser_available() -> bool:
    """Whether the trace analyser can actually be run.

    It is a separate script, and the harness records the trace either way rather than
    failing the round over attribution it may not need.
    """
    if not ANALYZER:
        return False
    command = ANALYZER[0]
    return bool(shutil.which(command)) or Path(command).exists()


@dataclass(frozen=True)
class Scenario:
    """One hand-driven scenario, as data rather than code.

    `expect`/`forbid` turn the instruction's prose ("this should show …") into something
    the harness can fail: a round where the hand did not do what the scenario describes is
    then visible in the report instead of having to be remembered. `note` is what is left
    for a person to judge — how much she moved, how long she was still.
    """

    key: str
    title: str
    prep: str
    gesture: str
    expect: tuple = ()
    forbid: tuple = ()
    # A heartbeat state to wait for before the first window: a scenario about her being at
    # rest is only comparable if she really is at rest when its window opens.
    wait: Optional[str] = None
    seconds: Optional[float] = None
    settle: Optional[float] = None
    # Overrides the batch's pin. Quiet mode leaves her a choice between resting and
    # sleeping, and which one she picks is decided by how sleepy she is — so a scenario
    # about her *awake* and still (`.idle`) pins this low, and one about her asleep pins it
    # high. Pinning it at all is what makes every round measure the same pet.
    sleepiness: Optional[float] = None
    note: str = ""


REQUIRED_SCENARIO_KEYS = ("key", "title", "prep", "gesture")


def load_scenarios(path: Path):
    """Reads a scenarios file: `{"scenarios": [{…}]}`, one object per scenario.

    Unknown keys are refused rather than ignored: a misspelled `expect` would otherwise
    check nothing, which is the one failure that field exists to prevent.
    """
    try:
        data = json.loads(Path(path).read_text())
    except FileNotFoundError:
        raise SystemExit(f"no scenarios file at {path}")
    except json.JSONDecodeError as error:
        raise SystemExit(f"{path} is not valid JSON: {error}")
    entries = data.get("scenarios")
    if not isinstance(entries, list) or not entries:
        raise SystemExit(f"{path} has no non-empty 'scenarios' list")

    scenarios = []
    for index, entry in enumerate(entries):
        missing = [name for name in REQUIRED_SCENARIO_KEYS if not entry.get(name)]
        if missing:
            raise SystemExit(
                f"{path}: scenario {index} is missing {', '.join(missing)}"
            )
        unknown = sorted(set(entry) - set(Scenario.__dataclass_fields__))
        if unknown:
            raise SystemExit(
                f"{path}: scenario '{entry.get('key', index)}' has unknown keys {unknown}"
            )
        scenarios.append(
            Scenario(
                key=entry["key"],
                title=entry["title"],
                prep=entry["prep"],
                gesture=entry["gesture"],
                expect=tuple(entry.get("expect", ())),
                forbid=tuple(entry.get("forbid", ())),
                wait=entry.get("wait"),
                seconds=entry.get("seconds"),
                settle=entry.get("settle"),
                sleepiness=entry.get("sleepiness"),
                note=entry.get("note", ""),
            )
        )
    keys = [scenario.key for scenario in scenarios]
    repeated = sorted(key for key, count in Counter(keys).items() if count > 1)
    if repeated:
        raise SystemExit(f"{path}: duplicate scenario keys {repeated}")
    return scenarios


# MARK: - process and log plumbing


def log_offset() -> int:
    try:
        return LOG.stat().st_size
    except FileNotFoundError:
        return 0


def read_new(offset: int, pending: str):
    """Lines appended since `offset`, plus the offset and any partial line to carry."""
    try:
        with LOG.open("r", errors="replace") as handle:
            handle.seek(offset)
            chunk = handle.read()
            offset = handle.tell()
    except FileNotFoundError:
        return [], offset, pending
    text = pending + chunk
    lines = text.split("\n")
    pending = lines.pop()
    return lines, offset, pending


def cpu_seconds(pid: int):
    """Cumulative user+system CPU of a process, which is what `getrusage` reports."""
    out = subprocess.run(
        ["ps", "-o", "time=", "-p", str(pid)], capture_output=True, text=True
    ).stdout.strip()
    if not out:
        return None
    parts = out.split(":")
    try:
        if len(parts) == 2:
            return int(parts[0]) * 60 + float(parts[1])
        if len(parts) == 3:
            return int(parts[0]) * 3600 + int(parts[1]) * 60 + float(parts[2])
    except ValueError:
        return None
    return None


def percent_cpu(pid: int):
    out = subprocess.run(
        ["ps", "-o", "%cpu=", "-p", str(pid)], capture_output=True, text=True
    ).stdout.strip()
    try:
        return float(out)
    except ValueError:
        return None


def window_server_pid():
    out = subprocess.run(
        ["pgrep", "-x", "WindowServer"], capture_output=True, text=True
    ).stdout.split()
    return int(out[0]) if out else None


def pet_pids():
    out = subprocess.run(
        ["pgrep", "-f", EXECUTABLE], capture_output=True, text=True
    ).stdout.split()
    return {int(value) for value in out}


def kill_pet():
    subprocess.run(["pkill", "-f", EXECUTABLE], capture_output=True)
    for _ in range(60):
        if not pet_pids():
            return
        time.sleep(0.1)
    raise SystemExit("the previous instance did not exit")


def fields(line: str):
    return dict(FIELDS.findall(line))


def event(line: str):
    found = EVENT.search(line)
    return found.group(1) if found else None


# MARK: - pet state on disk


def snapshot_state():
    """Captures the settings and life-state this batch is about to modify.

    Taken per batch, not once ever — otherwise a later batch puts back values from hours
    ago, silently discarding whatever she ate since. A leftover marker means the previous
    batch died with the harness's forced values still on disk, and the older snapshot is
    then the only pristine copy left; overwriting it would make those values permanent.
    """
    if MARKER.exists():
        print(f"  ⚠ 上一次测量没有正常收尾（{MARKER.name} 还在），沿用更早的备份")
        return
    if not SETTINGS.exists() or not LIFE.exists():
        raise SystemExit(f"no settings or life-state in {SUPPORT} — run the app once")
    SETTINGS_BACKUP.write_text(SETTINGS.read_text())
    LIFE_BACKUP.write_text(LIFE.read_text())
    MARKER.write_text(time.strftime("%Y-%m-%d %H:%M:%S") + "\n")


def force_settings():
    """Quiet mode and logging on — the two settings a measurement needs."""
    settings = json.loads(SETTINGS.read_text())
    settings["quietMode"] = True
    settings["loggingEnabled"] = True
    SETTINGS.write_text(json.dumps(settings, indent=2))


def restore_state():
    """Puts the snapshot back, rewriting only the keys the batch touched.

    Must run with nothing alive: the app owns both files while it is up
    (`settingsStore.save` on every menu toggle, `persistLifeState` on exit).
    """
    if SETTINGS_BACKUP.exists() and SETTINGS.exists():
        original = json.loads(SETTINGS_BACKUP.read_text())
        settings = json.loads(SETTINGS.read_text())
        settings["quietMode"] = original.get("quietMode")
        settings["loggingEnabled"] = original.get("loggingEnabled")
        SETTINGS.write_text(json.dumps(settings, indent=2))
    if LIFE_BACKUP.exists():
        LIFE.write_text(LIFE_BACKUP.read_text())
    MARKER.unlink(missing_ok=True)


def force_sleepiness(sleepiness: float):
    """Pins the sleepiness on disk, right before each launch.

    Every launch's exit saves the decayed state back, so this is re-applied per round
    rather than once for the batch — otherwise the later rounds start near a threshold
    and flip her back to the other of rest and sleep.
    """
    if not LIFE.exists():
        raise SystemExit(f"no pet state at {LIFE} — run the app once")
    state = json.loads(LIFE.read_text())
    state["sleepiness"] = sleepiness
    LIFE.write_text(json.dumps(state, indent=2))


# MARK: - launching


def build(command=None):
    """Builds and signs the bundle once for the whole batch.

    The default command is `make rerun`'s, and it has to produce the same bundle the
    rounds open: plain `make sign` assembles `NuonuoChuuby.app`, which nothing here
    launches, so building that leaves the launched `-Dev` bundle stale.
    """
    argv = shlex.split(command) if command else list(DEFAULT_BUILD)
    print(f"  building: {' '.join(argv)}")
    result = subprocess.run(argv, cwd=ROOT, capture_output=True, text=True)
    if result.returncode != 0:
        raise SystemExit(
            f"build failed:\n{result.stdout[-2000:]}\n{result.stderr[-2000:]}"
        )


def launch(bundle: Path, sleepiness: Optional[float] = None):
    """Relaunches `bundle` through LaunchServices, as `make rerun` does."""
    kill_pet()
    force_sleepiness(sleepiness if sleepiness is not None else FORCED_SLEEPINESS)
    offset = log_offset()
    subprocess.run(
        ["open", "-n", str(bundle), "--args", *APP_ARGS], capture_output=True
    )
    deadline = time.time() + 40
    while time.time() < deadline:
        pids = pet_pids()
        if pids:
            pid = max(pids)
            # Which *file* is running, not which bundle id the log claims: a bundle
            # swapped in between rounds is only attributable this way.
            path = subprocess.run(
                ["ps", "-o", "comm=", "-p", str(pid)], capture_output=True, text=True
            ).stdout.strip()
            print(f"  launched pid {pid}: {path or '?'}")
            return pid, offset, path
        time.sleep(0.2)
    raise SystemExit("the app did not start")


def wait_for(offset: int, pending: str, predicate, timeout: float):
    """Reads the log until a line satisfies `predicate`.

    Returns everything read either way, plus whether the predicate was met, so a caller
    that only needs a warning can tell the two apart.
    """
    deadline = time.time() + timeout
    seen = []
    while time.time() < deadline:
        lines, offset, pending = read_new(offset, pending)
        seen.extend(lines)
        if any(predicate(line) for line in lines):
            return offset, pending, seen, True
        if not pet_pids():
            raise SystemExit("the app exited while waiting for a log line")
        time.sleep(0.25)
    return offset, pending, seen, False


def confirm_running(offset: int, pending: str):
    """Waits for the process's own self-label, which is what makes a round attributable."""
    offset, pending, seen, found = wait_for(
        offset, pending, lambda line: event(line) == "PetPresenter", 40
    )
    if not found:
        raise SystemExit("no PetPresenter line appeared — is logging enabled?")
    labels = {}
    for line in seen:
        if event(line) == "ProcessStarted":
            labels["bundle"] = fields(line).get("Bundle")
        if event(line) == "PetPresenter":
            labels["presenter"] = fields(line).get("Kind")
        if event(line) == "PetFallRefresh":
            labels["fall_refresh"] = fields(line).get("Rate")
        if event(line) == "WindowBoundsSource":
            data = fields(line)
            labels["live_read"] = f"{data.get('Kind')}/{data.get('Available')}"
    print(
        f"  pid running as {labels.get('presenter')} renderer,"
        f" live read {labels.get('live_read')}, fall refresh {labels.get('fall_refresh')}"
    )
    return offset, pending, labels


def wait_until_state(offset: int, pending: str, state: str, timeout: float = 25.0):
    """Holds the round until a heartbeat reports `state`.

    A scenario about her being at rest is only comparable if she really is at rest when
    its window opens, and quiet mode otherwise leaves that to a coin flip. The heartbeat
    fires every 10 s, so this costs up to that much per round.
    """
    deadline = time.time() + timeout
    while time.time() < deadline:
        offset, pending, seen, found = wait_for(
            offset, pending, lambda line: event(line) == "StatusHeartbeat", 12
        )
        states = [
            fields(line).get("State")
            for line in seen
            if event(line) == "StatusHeartbeat"
        ]
        if states and states[-1] == state:
            print(f"  heartbeats confirm she is {states[-1]}")
            return offset, pending
        if not found:
            break
    print(f"  ⚠ no '{state}' heartbeat yet — measuring anyway")
    return offset, pending


# MARK: - the two phases


def wait_for_enter(prompt: str):
    """Blocks until the user presses Enter.

    The settle used to double as reading time, which tied the start of the measurement
    window to how fast the instruction was read: five seconds is not always enough, and
    the hand cannot be in position while the eye is still on the screen. The keypress
    moves that cost outside the window, leaving the settle to do only what it is for.
    """
    print(prompt, end="", flush=True)
    try:
        sys.stdin.readline()
    except (EOFError, OSError):
        # Not a terminal (piped in, or closed stdin): go straight on rather than hang.
        print()


def countdown(seconds: float, label: str):
    """Counts down where the hand can see it, then wipes the line."""
    for remaining in range(int(seconds), 0, -1):
        print(f"\r      {label} {remaining:2d}s ...   ", end="", flush=True)
        time.sleep(1)
    if seconds:
        print("\r" + " " * 34 + "\r", end="", flush=True)


PHASE_TITLES = {"ps": "ps 采样", "trace": "Time Profiler"}


def begin_phase(index: int, count: int, key: str, seconds: float, pause: float):
    """Prints a phase's boundary, and counts the hand into the first one.

    Only the first phase waits for a person — it is the one whose instructions were just
    read — so `pause` is the settle there and the gap between phases everywhere else. The
    rest follow the one before them **without a stop**, and without an Enter: they are
    instruments on the same activity, and a pause would mean the second was measured on a
    hand already doing something else.
    """
    print()
    print(
        f"  ━━ 第 {index}/{count} 段：{PHASE_TITLES.get(key, key)} {seconds:.0f} 秒 ━━"
    )
    if index > 1:
        print("  ➜ 紧接着上一段，动作不要停。")
    countdown(pause, "settle" if index == 1 else "间隔")
    if index == 1:
        print("  ▶▶ 现在开始！")


def summarize(lines):
    """The counters that say whether the round happened the way it was meant to.

    Every event the app logs is counted, by name: a diagnostic added to the app shows up
    here without this file changing, and a scenario can then expect it by name.
    """
    events = Counter()
    states = Counter()
    transitions = Counter()
    falls = Counter()
    moves = []
    profiles = []
    for line in lines:
        name = event(line)
        if name is None:
            continue
        events[name] += 1
        if name == "StatusHeartbeat":
            states[fields(line).get("State")] += 1
        elif name == "StateTransition":
            data = fields(line)
            transitions[f"{data.get('From')}→{data.get('To')}"] += 1
        elif name == "FallStarted":
            falls[fields(line).get("Reason")] += 1
        elif name == "FallProfile":
            data = fields(line)
            profiles.append(
                {
                    "distance": data.get("Distance"),
                    "refresh_hz": data.get("RefreshHz"),
                    "refreshes": data.get("Refreshes"),
                    "ticks": data.get("Ticks"),
                }
            )
        elif name == "MouseMoveCount":
            value = fields(line).get("PerSecond")
            if value is not None:
                moves.append(int(value))
    return {
        "heartbeat_states": dict(states),
        "transitions": dict(transitions),
        "fall_reasons": dict(falls),
        "events": dict(events),
        "moves_per_second": round(sum(moves) / len(moves), 1) if moves else None,
        "fall_profiles": profiles,
    }


def verdict(scenario: Scenario, control):
    """Whether the round's evidence is what the scenario says it should be.

    The checked half of a scenario; `note` is the half a person reads.
    """
    events = control.get("events") or {}
    missing = [name for name in scenario.expect if not events.get(name)]
    forbidden = [name for name in scenario.forbid if events.get(name)]
    checked = bool(scenario.expect or scenario.forbid)
    return {
        "checked": checked,
        # None rather than False when there is nothing to check: a ✓ that means "nothing to
        # complain about" would read as "the hand was verified", which it was not.
        "passed": (not missing and not forbidden) if checked else None,
        "expected": list(scenario.expect),
        "missing": missing,
        "forbidden": forbidden,
    }


def phase_window(
    pid: int, ws_pid, seconds: float, offset: int, pending: str, label: str
):
    """Times one window: the CPU deltas of the app and of Window Server, plus the log."""
    # The CPU window opens here, so the log window has to open here too. `offset` was
    # seeded back when the app launched; reading on from there counts everything that
    # happened while the instruction was being read and she was being moved into position
    # — her heartbeats, her waking and sleeping, the drag that put her in the box — as if
    # it were this round's evidence. A round that began six minutes after launch collected
    # 48 lines of that and looked like a different pet from the two-minute ones. The CPU
    # number was never affected (`cpu_start` is taken below, after the settle); only the
    # control it is judged by was.
    offset = log_offset()
    pending = ""
    wall_start = time.time()
    cpu_start = cpu_seconds(pid)
    ws_start = cpu_seconds(ws_pid) if ws_pid else None
    percent = []
    seen = []
    next_sample = wall_start + 1
    while True:
        elapsed = time.time() - wall_start
        if elapsed >= seconds:
            break
        print(
            f"\r      {label} {elapsed:4.1f}/{seconds:.0f}s ...   ", end="", flush=True
        )
        if time.time() >= next_sample:
            value = percent_cpu(pid)
            if value is not None:
                percent.append(value)
            next_sample += 1
        lines, offset, pending = read_new(offset, pending)
        seen.extend(lines)
        if not pet_pids() & {pid}:
            raise SystemExit("the app exited while being measured")
        time.sleep(0.2)
    wall = time.time() - wall_start
    cpu_end = cpu_seconds(pid)
    ws_end = cpu_seconds(ws_pid) if ws_pid else None
    print()
    cpu = (
        (cpu_end - cpu_start)
        if (cpu_end is not None and cpu_start is not None)
        else None
    )
    ws = (ws_end - ws_start) if (ws_end is not None and ws_start is not None) else None
    return (
        {
            "wall_seconds": round(wall, 2),
            "cpu_seconds": cpu,
            "cpu_percent_of_one_core": round(100 * cpu / wall, 2) if cpu else None,
            "percent_cpu_samples": percent,
            "percent_cpu_sample_mean": round(sum(percent) / len(percent), 2)
            if percent
            else None,
            "window_server_cpu_seconds": ws,
            "window_server_percent": round(100 * ws / wall, 2)
            if ws is not None
            else None,
            **summarize(seen),
        },
        offset,
        pending,
    )


def ps_phase(pid, scenario, seconds, offset, pending):
    ws_pid = window_server_pid()
    measurement, offset, pending = phase_window(
        pid, ws_pid, seconds, offset, pending, "ps"
    )
    # Judged against the scenario, so the round says for itself whether the hand did what
    # it was asked to; the alternative is remembering these counts from the console.
    measurement["verdict"] = verdict(scenario, measurement)
    print(
        f"      ps {measurement['cpu_percent_of_one_core']}% of one core"
        f"（{measurement['cpu_seconds']:.2f} s CPU / {measurement['wall_seconds']:.2f} s）"
        f"  ws {measurement['window_server_percent']}%"
        f"  ps %cpu 采样均值 {measurement['percent_cpu_sample_mean']}"
    )
    print(f"      控制：{control_line(measurement)}")
    return measurement, offset, pending


def trace_phase(pid, scenario, seconds, offset, pending, label):
    trace = TRACES / f"{label}.trace"
    xml = TRACES / f"{label}.xml"
    for path in (trace, xml):
        if path.exists():
            subprocess.run(["rm", "-rf", str(path)])
    log_file = TRACES / f"{label}.xctrace.log"
    ws_pid = window_server_pid()
    # Same as `phase_window`: the log window opens when the measurement does.
    offset = log_offset()
    pending = ""
    wall_start = time.time()
    cpu_start = cpu_seconds(pid)
    ws_start = cpu_seconds(ws_pid) if ws_pid else None
    seen = []
    with log_file.open("w") as sink:
        recorder = subprocess.Popen(
            [
                "xcrun",
                "xctrace",
                "record",
                "--template",
                "Time Profiler",
                "--attach",
                str(pid),
                "--time-limit",
                f"{int(seconds)}s",
                "--output",
                str(trace),
            ],
            stdout=sink,
            stderr=subprocess.STDOUT,
        )
        # The recorder's own 15 s start at attach time, a second or two after this call;
        # the driver keeps the gesture going until the script says stop, so the recorded
        # window is covered either way.
        while recorder.poll() is None:
            elapsed = time.time() - wall_start
            print(f"\r      录制中 {elapsed:4.1f}s ...   ", end="", flush=True)
            lines, offset, pending = read_new(offset, pending)
            seen.extend(lines)
            if not pet_pids() & {pid}:
                recorder.kill()
                raise SystemExit("the app exited while being traced")
            time.sleep(0.25)
    recorder.wait()
    wall = time.time() - wall_start
    cpu_end = cpu_seconds(pid)
    ws_end = cpu_seconds(ws_pid) if ws_pid else None
    print(f"\r      录制结束（{wall:.1f}s）          ")

    if not trace.exists():
        print(f"  ⚠ 录制失败，见 {log_file}")
        return None, offset, pending

    print("      导出并解析 trace ...")
    exported = subprocess.run(
        [
            "xcrun",
            "xctrace",
            "export",
            "--input",
            str(trace),
            "--xpath",
            '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]',
            "--output",
            str(xml),
        ],
        capture_output=True,
        text=True,
    )
    if exported.returncode != 0:
        print(f"  ⚠ 导出失败：{exported.stderr.strip()[:300]}")
        return None, offset, pending
    if not analyser_available():
        print(f"  ⚠ 没有分析器（{' '.join(ANALYZER)}）")
        print("     trace 与 XML 会留下，但不解析（--analyzer 可以指定别的）")
        return (
            {"trace": str(trace), "xml": str(xml), "analysed": False},
            offset,
            pending,
        )
    analysis = subprocess.run(
        [*ANALYZER, str(xml)],
        capture_output=True,
        text=True,
    )
    if analysis.returncode != 0:
        print(f"  ⚠ 解析失败：{analysis.stderr.strip()[:300]}")
        return None, offset, pending

    result = json.loads(analysis.stdout)
    result["wall_seconds"] = round(wall, 2)
    result["app_cpu_seconds_during_trace"] = (
        (cpu_end - cpu_start)
        if (cpu_end is not None and cpu_start is not None)
        else None
    )
    result["app_percent_during_trace"] = (
        round(100 * result["app_cpu_seconds_during_trace"] / wall, 2)
        if result["app_cpu_seconds_during_trace"]
        else None
    )
    result["window_server_percent_during_trace"] = (
        round(100 * (ws_end - ws_start) / wall, 2)
        if (ws_end is not None and ws_start is not None)
        else None
    )
    result["log"] = summarize(seen)
    result["log"]["verdict"] = verdict(scenario, result["log"])
    top = result["top_inclusive"][:5]
    print(
        f"      主线程 {result['thread_ms'] / 1000:.2f} s / 总 {result['total_ms'] / 1000:.2f} s"
        f"（{result['thread_share_of_total']}%）"
        f"  含采样器开销的进程 CPU {result['app_percent_during_trace']}%"
    )
    for entry in top:
        print(
            f"        {entry['inclusive_ms']:>8.1f} ms {entry['share_of_thread']:>6.2f}%  {entry['name'][:80]}"
        )
    return result, offset, pending


def cell(value, fallback="-"):
    """A table cell: a number that was never taken is a dash, not a crash."""
    return fallback if value is None else value


def short_event(name: str) -> str:
    """`盒Impact` rather than `WindowEnclosureImpact`, to fit a table row."""
    if name.startswith("WindowEnclosure"):
        return "盒" + name[len("WindowEnclosure") :]
    return name


def enumerated(pairs, limit=6) -> str:
    """`a×1, b×2` for the first few, with a marker when there are more."""
    items = [f"{key}×{value}" for key, value in pairs[:limit]]
    if len(pairs) > limit:
        items.append(f"…+{len(pairs) - limit}")
    return ", ".join(items)


def control_line(control):
    """The evidence a round is judged by, as one line.

    What the scenario *expected* comes first, because that is the part the harness
    checked; the rest (her state, how much the hand moved her) is what a person pairs
    rounds on when comparing two arms.
    """
    bits = []
    result = control.get("verdict")
    if result is not None and result.get("checked"):
        if result.get("passed"):
            bits.append("判据 ✓")
        else:
            detail = []
            if result.get("missing"):
                detail.append(
                    "缺 " + ", ".join(short_event(n) for n in result["missing"])
                )
            if result.get("forbidden"):
                detail.append(
                    "多 " + ", ".join(short_event(n) for n in result["forbidden"])
                )
            bits.append("判据 ✗ " + "；".join(detail))
        if result.get("expected"):
            events = control.get("events") or {}
            bits.append(
                "事件 "
                + ", ".join(
                    f"{short_event(name)}×{events.get(name, 0)}"
                    for name in result["expected"]
                )
            )
    states = control.get("heartbeat_states") or {}
    if states:
        bits.append("状态 " + enumerated(list(states.items())))
    if control.get("moves_per_second") is not None:
        bits.append(f"鼠标 {control['moves_per_second']:.0f}/s")
    if control.get("transitions"):
        bits.append("转换 " + enumerated(sorted(control["transitions"].items())))
    if control.get("fall_reasons"):
        bits.append("下落 " + enumerated(sorted(control["fall_reasons"].items())))
    if control.get("fall_profiles"):
        rates = [profile["refresh_hz"] for profile in control["fall_profiles"]]
        bits.append("腾空重建 " + "/".join(rates) + " Hz")
    return "；".join(bits) if bits else "（窗口内没有事件）"


# MARK: - one round, and the batch


def one_round(
    scenario: Scenario,
    round_index: int,
    rounds: int,
    phases,
    seconds: float,
    settle: float,
    gap: float,
    bundle: Path,
    arm=None,
    head=None,
):
    seconds = scenario.seconds or seconds
    settle = scenario.settle or settle

    print()
    print("═" * 78)
    print(f"  场景「{scenario.title}」 第 {round_index}/{rounds} 轮")
    print(
        f"  {'arm 「' + arm + '」' if arm else ''} {bundle.name}（HEAD {head}）".rstrip()
    )
    if scenario.note:
        print(f"  判据（人看）：{scenario.note}")
    if scenario.expect or scenario.forbid:
        print(
            "  自动判据："
            + (("要出现 " + ", ".join(scenario.expect)) if scenario.expect else "")
            + ("；" if scenario.expect and scenario.forbid else "")
            + (("不准出现 " + ", ".join(scenario.forbid)) if scenario.forbid else "")
        )
    print("═" * 78)

    pid, offset, exe = launch(bundle, scenario.sleepiness)
    pending = ""
    offset, pending, labels = confirm_running(offset, pending)
    digest = subprocess.run(
        ["shasum", "-a", "256", exe], capture_output=True, text=True
    ).stdout.split()
    labels["exe"] = exe
    labels["sha256"] = digest[0] if digest else None
    if scenario.wait:
        offset, pending = wait_until_state(offset, pending, scenario.wait)

    # Read and acted on **before** the windows, and once for the round rather than once per
    # phase: positioning her is part of the preparation, and it is why the Enter exists.
    # Unlimited, because that step is not something a fixed countdown can fit.
    print(f"  ➜ 准备：{scenario.prep}")
    print(f"  ➜ 等下要做：{scenario.gesture}")
    wait_for_enter("  ⌨  读完上面两行、并把她的位置摆好后，按 Enter ▸ ")

    # The arm is in the trace's file name: two arms of one scenario otherwise collide when
    # they land in the same second, and one arm's profile would be read as the other's.
    label = "-".join(
        part
        for part in (time.strftime("%H%M%S"), scenario.key, f"r{round_index}", arm)
        if part
    )
    ps = None
    trace = None
    for index, phase in enumerate(phases, start=1):
        begin_phase(index, len(phases), phase, seconds, settle if index == 1 else gap)
        if phase == "ps":
            ps, offset, pending = ps_phase(pid, scenario, seconds, offset, pending)
        else:
            # Never overlapped with the reading: the profiler's sampler runs inside the
            # measured process, so a CPU number taken while it is attached is not the
            # app's. Which phase comes first is the caller's business.
            trace, offset, pending = trace_phase(
                pid, scenario, seconds, offset, pending, label
            )
    print("  ■ 这一轮结束，手停下。")
    kill_pet()

    record = {
        "scenario": scenario.key,
        "title": scenario.title,
        "round": round_index,
        "label": label,
        "arm": arm,
        "head": head,
        "bundle": str(bundle),
        "phases": list(phases),
        "window_seconds": seconds,
        "launch": labels,
        "ps": ps,
        "trace": trace,
    }
    with RESULTS.open("a") as handle:
        handle.write(json.dumps(record, ensure_ascii=False) + "\n")
    return record


def report():
    """Everything collected in this output directory, as a table per round and per arm.

    The per-round rows are the raw evidence. Grouping them by arm is what answers "did the
    change move the cost", and the grouping is by **arm × scenario** because the number
    tracks how much she was moved: rounds of one scenario in one arm are the same pet and
    the same hand, so their spread is this measurement's noise floor — and a difference
    between two arms only means something if it is bigger than that.
    """
    if not RESULTS.exists():
        raise SystemExit(f"nothing collected yet ({RESULTS})")
    records = [
        json.loads(line) for line in RESULTS.read_text().splitlines() if line.strip()
    ]
    header = (
        f"{'arm':<12} {'场景':<14} {'轮':<3} {'ps %核':>7} {'CPU s':>7} {'ws %':>6}"
        f" {'鼠标/s':>7} {'含开销%':>8} {'主线程%':>8}  控制"
    )
    print(header)
    print("-" * 150)
    for record in records:
        ps = record.get("ps") or {}
        trace = record.get("trace") or {}
        # Whichever phase collected the log: a trace-only round still has its evidence,
        # just under the other key.
        control = ps or (trace.get("log") or {})
        print(
            f"{record.get('arm') or '-':<12}"
            f" {record['title']:<14} r{record['round']:<2}"
            f" {cell(ps.get('cpu_percent_of_one_core')):>7}"
            f" {cell(ps.get('cpu_seconds')):>7}"
            f" {cell(ps.get('window_server_percent')):>6}"
            f" {cell(ps.get('moves_per_second')):>7}"
            f" {cell(trace.get('app_percent_during_trace')):>8}"
            f" {cell(trace.get('thread_share_of_total')):>8}"
            f"  {control_line(control)[:80]}"
        )
    print("-" * 150)

    groups = []
    for record in records:
        key = (record.get("arm"), record["scenario"])
        if key not in groups:
            groups.append(key)

    if any(arm for arm, _ in groups):
        print()
        print("按 arm × 场景（ps 段；同一组内平均，括号里是各轮）")
        print(
            f"{'arm':<12} {'场景':<14} {'轮数':>4} {'ps %核':>9} {'各轮':>24}"
            f"  判据  二进制"
        )
        for arm, scenario_key in groups:
            rows = [
                r
                for r in records
                if r.get("arm") == arm and r["scenario"] == scenario_key
            ]
            values = [r["ps"]["cpu_percent_of_one_core"] for r in rows if r.get("ps")]
            if not values:
                continue
            passed = [
                (r.get("ps") or {}).get("verdict", {}).get("passed") for r in rows
            ]
            marks = "".join(
                "✓" if value else ("✗" if value is False else "-") for value in passed
            )
            digest = ((rows[0].get("launch") or {}).get("sha256") or "?")[:12]
            print(
                f"{arm or '-':<12} {rows[0]['title']:<14} {len(values):>4}"
                f" {sum(values) / len(values):>9.2f}"
                f" {'/'.join(str(v) for v in values):>24}  {marks:<4} {digest}"
            )

    print()
    print("每场景（ps 段，不分 arm）")
    print(f"{'场景':<14} {'ps %核':>9} {'各轮':>28} {'ws %':>7} {'鼠标/s':>7}")
    for scenario_key in dict.fromkeys(record["scenario"] for record in records):
        rows = [r for r in records if r["scenario"] == scenario_key]
        values = [r["ps"]["cpu_percent_of_one_core"] for r in rows if r.get("ps")]
        if not values:
            continue
        ws = [(r.get("ps") or {}).get("window_server_percent", 0) for r in rows]
        moves = [((r.get("ps") or {}).get("moves_per_second") or 0) for r in rows]
        print(
            f"{rows[0]['title']:<14} {sum(values) / len(values):>9.2f}"
            f" {'/'.join(str(v) for v in values):>28}"
            f" {sum(ws) / len(ws):>7.2f} {sum(moves) / len(moves):>7.0f}"
        )

    print()
    print("跑过的二进制（按 arm 去重）")
    seen = set()
    for record in records:
        launch = record.get("launch") or {}
        name = record.get("arm") or "-"
        if name in seen:
            continue
        seen.add(name)
        print(
            f"  {name:<12} {launch.get('sha256') or '?':<16} {launch.get('exe') or '?'}"
        )


def resolve_bundles(options):
    """Which `.app` each round opens, and what that round is called.

    One bundle is the normal case. Several **alternate**, one per round, which is the A/B
    form: an arm measured in a block after the other one carries whatever drifted in
    between, and that drift is easily larger than the effect being looked for.
    """
    if not options.bundles:
        return [(options.arm, Path(options.bundle).expanduser().resolve())]
    if not options.no_build:
        raise SystemExit(
            "--bundles 要求 --no-build：两边的 bundle 必须各自预先建好，"
            "而构建命令只会重建其中一个"
        )
    bundles = []
    for spec in options.bundles.split(","):
        spec = spec.strip()
        if not spec:
            continue
        name, separator, path = spec.partition("=")
        if not separator:
            name, path = Path(spec).stem, spec
        bundles.append((name, Path(path).expanduser().resolve()))
    if len(bundles) < 2:
        raise SystemExit("--bundles 要两个及以上，写法 name=path,name=path")
    return bundles


def describe_bundles(bundles):
    """Path, sha256 and build time of what each arm will run.

    The sha256 is the only evidence of *which file* ran — the log's own `Bundle` field is
    a constant, and the HEAD line is the tree at the time of recording, which is not the
    same thing when bundles are built from different commits.
    """
    for name, bundle in bundles:
        executable = bundle / EXECUTABLE
        if not executable.exists():
            raise SystemExit(f"{bundle} 里没有 {EXECUTABLE}（它必须先建好）")
        digest = subprocess.run(
            ["shasum", "-a", "256", str(executable)], capture_output=True, text=True
        ).stdout.split()
        stamp = time.strftime(
            "%Y-%m-%d %H:%M:%S", time.localtime(executable.stat().st_mtime)
        )
        print(f"  {name or '-':<12} {bundle}")
        print(f"  {'':<12} sha256 {digest[0][:16] if digest else '?'}  built {stamp}")


def main():
    parser = argparse.ArgumentParser(
        description="Measure what the pet costs while a hand moves her.",
        epilog="scenario fields: " + ", ".join(Scenario.__dataclass_fields__),
    )
    parser.add_argument(
        "--scenarios",
        default=None,
        help="comma-separated keys to run; default is every scenario in the file",
    )
    parser.add_argument(
        "--scenarios-file",
        default=str(DEFAULT_SCENARIOS),
        help="JSON file defining them (default: scenarios.json beside this script)",
    )
    parser.add_argument("--rounds", type=int, default=ROUNDS)
    parser.add_argument(
        "--phases", default="ps,trace", help="any of ps,trace, in that order"
    )
    parser.add_argument("--seconds", type=float, default=PHASE_SECONDS)
    parser.add_argument("--settle", type=float, default=SETTLE_SECONDS)
    parser.add_argument(
        "--phase-gap",
        type=float,
        default=0.0,
        help="pause between the phases; 0 keeps the hand moving through the boundary",
    )
    parser.add_argument(
        "--bundle",
        default=str(DEFAULT_BUNDLE),
        help="the .app a round opens (default: the one make rerun builds)",
    )
    parser.add_argument(
        "--bundles",
        default=None,
        help="name=path pairs, alternated one per round — the A/B form (needs --no-build)",
    )
    parser.add_argument("--arm", default=None, help="label recorded with every round")
    parser.add_argument(
        "--build-cmd",
        default=None,
        help="run once before the batch (default: make sign with make rerun's flags)",
    )
    parser.add_argument(
        "--no-build",
        action="store_true",
        help="build nothing; use the bundle(s) already on disk",
    )
    parser.add_argument(
        "--app-args",
        default=" ".join(DEFAULT_APP_ARGS),
        help="flags handed to the app (default: the mouse-move counter)",
    )
    parser.add_argument(
        "--analyzer",
        default=None,
        help="called as `<analyzer> <xml>`, printing JSON (default: top_symbols.py --json)",
    )
    parser.add_argument(
        "--out-dir",
        default=str(DEFAULT_OUT),
        help="where runs.jsonl and traces/ go (default: .build/scenario-bench)",
    )
    parser.add_argument("--report", action="store_true")
    parser.add_argument("--fresh", action="store_true")
    options = parser.parse_args()

    configure(options)
    OUT.mkdir(parents=True, exist_ok=True)
    if options.report:
        report()
        return
    if options.fresh:
        # "Earlier runs" includes their traces: a stale profile left beside this batch's
        # would be indistinguishable from one of them.
        if RESULTS.exists():
            RESULTS.unlink()
        if TRACES.exists():
            shutil.rmtree(TRACES)
    TRACES.mkdir(parents=True, exist_ok=True)

    phases = [phase.strip() for phase in options.phases.split(",") if phase.strip()]
    unknown = sorted(set(phases) - {"ps", "trace"})
    if unknown:
        raise SystemExit(f"--phases 不认识 {unknown}（只有 ps 与 trace）")
    if not phases:
        raise SystemExit("--phases 是空的")
    if "ps" not in phases:
        print("  ⚠ 这一批没有 ps 段，读数会带着采样器开销（见 --phases）")
    if "trace" in phases and not analyser_available():
        print(f"  ⚠ 没有分析器（{' '.join(ANALYZER)}）：trace 会录，但不会被解析")
    scenarios = load_scenarios(options.scenarios_file)
    if options.scenarios:
        wanted = [key.strip() for key in options.scenarios.split(",") if key.strip()]
        known = {scenario.key for scenario in scenarios}
        missing = [key for key in wanted if key not in known]
        if missing:
            raise SystemExit(
                f"{options.scenarios_file} 里没有 {missing}；它有 {sorted(known)}"
            )
        chosen = [scenario for scenario in scenarios if scenario.key in wanted]
    else:
        chosen = list(scenarios)
    bundles = resolve_bundles(options)

    total_rounds = len(chosen) * options.rounds
    per_round = options.settle + options.phase_gap * (len(phases) - 1)
    per_round += options.seconds * len(phases)
    # The timeline as it will feel to the hand: one gate, then the phases with only
    # `--phase-gap` between them.
    pieces = []
    for index, phase in enumerate(phases):
        if index and options.phase_gap:
            pieces.append(f"{options.phase_gap:.0f}s 间隔")
        pieces.append(f"{options.seconds:.0f}s {phase}")
    print("  ── 交互场景 CPU 基准 ──")
    print(f"  场景：{options.scenarios_file}（{len(chosen)}/{len(scenarios)} 个）")
    print(f"  {total_rounds} 轮 = {len(chosen)} 个场景 × {options.rounds} 轮")
    print(
        "  每轮 = "
        + " + ".join(["Enter", f"{options.settle:.0f}s settle", *pieces])
        + f"（约 {per_round * total_rounds / 60:.0f} 分钟，不含读指令的时间）"
    )
    print(f"  启动参数：{' '.join(APP_ARGS) or '（无）'}")
    print("  安静模式开 + sleepiness 钉在 100")
    print("  settings.json / life-state.json 批次结束后还原")
    git = subprocess.run(
        ["git", "status", "--porcelain"], cwd=ROOT, capture_output=True, text=True
    ).stdout.strip()
    head = subprocess.run(
        ["git", "rev-parse", "--short", "HEAD"],
        cwd=ROOT,
        capture_output=True,
        text=True,
    ).stdout.strip()
    print(
        f"  HEAD {head}，工作树{'干净' if not git else '不干净：' + git.replace(chr(10), ' | ')}"
    )
    print(
        "  （HEAD 是记录时的树；跑的是哪个文件以 --bundle/--bundles"
        " 与下面的 sha256 为准）"
    )

    snapshot_state()
    force_settings()
    try:
        if options.no_build:
            print("  --no-build：不重建，直接用磁盘上的 bundle")
        else:
            build(options.build_cmd)
        print("  将要运行：")
        describe_bundles(bundles)
        if len(bundles) > 1:
            print("  每轮换一个 bundle（跨进程交替）；arm 名就是上面那一列")
        batch_round = 0
        for scenario in chosen:
            for round_index in range(1, options.rounds + 1):
                arm, bundle = bundles[batch_round % len(bundles)]
                batch_round += 1
                one_round(
                    scenario,
                    round_index,
                    options.rounds,
                    phases,
                    options.seconds,
                    options.settle,
                    options.phase_gap,
                    bundle,
                    arm=arm,
                    head=head,
                )
    finally:
        # Nothing may be running when the files are put back: the app owns them while it
        # is alive (`settingsStore.save` on every menu toggle, `persistLifeState` on exit).
        kill_pet()
        restore_state()
        print()
        print("（settings.json 与 life-state.json 已还原）")

    print()
    print("═" * 78)
    print("  结果")
    print("═" * 78)
    report()
    print()
    print(f"  明细：{RESULTS}")
    print(f"  trace 与 XML：{TRACES}")
    print(f"  单看一条 trace：{' '.join(ANALYZER)} <xml>")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)
