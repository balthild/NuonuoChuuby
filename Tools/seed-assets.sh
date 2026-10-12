#!/bin/sh
#
# Copy the pet's runtime assets out of the upstream submodule into the SwiftPM
# resource folder, so a development build can run without a download.
#
#   Tools/seed-assets.sh <upstream-repo> <destination>
#
# The upstream repository is tracked as a submodule and is expected to be
# checked out. Only the files the app needs at runtime are copied: 糯糯's sprite
# frames, her voice clips, and the voice loudness index. Generation sources,
# keyframes and Feibi's art stay behind.
set -eu

src=${1:?usage: seed-assets.sh <upstream-repo> <destination>}
dst=${2:?usage: seed-assets.sh <upstream-repo> <destination>}

[ -d "$src/assets/sprites/runtime" ] || {
	printf '%s\n' "seed-assets.sh: $src/assets/sprites/runtime not found." \
		"Run 'git submodule update --init' first." >&2
	exit 1
}

rm -rf "$dst"
mkdir -p "$dst/sprites/runtime" "$dst/audio/voice"

frames=0
for dir in "$src/assets/sprites/runtime"/*/; do
	[ -d "$dir" ] || continue
	name=$(basename "$dir")
	# `pinch` is superseded by the procedural cheek-pinch renderer.
	[ "$name" = pinch ] && continue
	mkdir -p "$dst/sprites/runtime/$name"
	cp "$dir"frame_*.png "$dst/sprites/runtime/$name/"
	frames=$((frames + $(ls "$dir" | wc -l | tr -d ' ')))
done

cp "$src/音效"/*.wav "$dst/audio/voice/"
cp "$src/assets/audio/voice-levels.json" "$dst/audio/voice-levels.json"

commit=$(git -C "$src" rev-parse HEAD)
printf '%s\n' "$commit" > "$dst/.asset-commit"
printf '%s\n' "Seeded assets from $commit" "  frames: $frames" "  voices: $(ls "$dst/audio/voice" | wc -l | tr -d ' ')"
