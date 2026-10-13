#!/bin/sh
#
# List the runtime files the app needs, as "<destination><TAB><source>" lines in
# destination order, where <source> is a path inside the upstream repository.
#
#   Tools/asset-files.sh <upstream-repo>
#
# The linker and the manifest generator both read this, so which files the app
# ships and how they map upstream live in exactly one place. Generation sources,
# keyframes, `pinch` (superseded by the procedural cheek-pinch renderer) and
# Feibi's art are left behind.
set -eu

src=${1:?usage: asset-files.sh <upstream-repo>}

[ -d "$src/assets/sprites/runtime" ] || {
	printf '%s\n' "asset-files.sh: $src/assets/sprites/runtime not found." \
		"Run 'git submodule update --init' first." >&2
	exit 1
}

tab=$(printf '\t')

{
	for dir in "$src"/assets/sprites/runtime/*/; do
		[ -d "$dir" ] || continue
		name=$(basename "$dir")
		[ "$name" = pinch ] && continue
		for frame in "$dir"frame_*.png; do
			[ -f "$frame" ] || continue
			base=$(basename "$frame")
			printf '%s%s%s\n' "sprites/runtime/$name/$base" "$tab" "assets/sprites/runtime/$name/$base"
		done
	done
	for voice in "$src"/音效/*.wav; do
		[ -f "$voice" ] || continue
		base=$(basename "$voice")
		printf '%s%s%s\n' "audio/voice/$base" "$tab" "音效/$base"
	done
	printf '%s%s%s\n' "audio/voice-levels.json" "$tab" "assets/audio/voice-levels.json"
} | LC_ALL=C sort
