#!/bin/sh
#
# Write the asset manifest that a release build uses to fetch its artwork.
#
#   Tools/generate-asset-manifest.sh <upstream-repo> <seeded-assets-dir> <output>
#
# The manifest pins one upstream commit and lists, for every runtime file the app
# needs, both its place inside the app's asset folder and the path it comes from
# upstream. Listing the sources explicitly (rather than deriving them at runtime)
# keeps the mapping — including Nuonuo's voice clips, which live in a Chinese-
# named folder at the repository root — in one reviewable place.
#
# The manifest contains only paths and a commit id: no asset bytes, and nothing
# that needs a redistribution grant.
set -eu

src=${1:?usage: generate-asset-manifest.sh <upstream-repo> <seeded-assets-dir> <output>}
assets=${2:?usage: generate-asset-manifest.sh <upstream-repo> <seeded-assets-dir> <output>}
out=${3:?usage: generate-asset-manifest.sh <upstream-repo> <seeded-assets-dir> <output>}

[ -d "$assets/sprites/runtime" ] || {
	printf '%s\n' "generate-asset-manifest.sh: $assets has no sprites; run 'make assets' first." >&2
	exit 1
}

commit=$(git -C "$src" rev-parse HEAD)
upstream=$(git -C "$src" config --get remote.origin.url | sed 's/\.git$//')

work=$(mktemp "${TMPDIR:-/tmp}/nuonuo-manifest.XXXXXX")
trap 'rm -f "$work"' EXIT HUP INT TERM

# Source path for a file inside the app's asset folder.
source_for() {
	case "$1" in
	audio/voice/*) printf '%s' "音效/$(basename "$1")" ;;
	audio/voice-levels.json) printf '%s' "assets/audio/voice-levels.json" ;;
	*) printf '%s' "assets/$1" ;;
	esac
}

total=0
(
	cd "$assets"
	find . -type f ! -name '.asset-commit' | sed 's|^\./||' | LC_ALL=C sort
) > "$work"

printf '%s\n' '{' \
	"  \"upstream\": \"$upstream\"," \
	"  \"commit\": \"$commit\"," \
	'  "files": [' > "$out"

while IFS= read -r path; do
	total=$((total + 1))
	[ "$total" -gt 1 ] && printf '%s\n' ',' >> "$out"
	printf '    { "path": "%s", "source": "%s" }' "$path" "$(source_for "$path")" >> "$out"
done < "$work"

printf '\n%s\n' '  ]' '}' >> "$out"

printf '%s\n' "Wrote $out" "  commit: $commit" "  files:  $total"
