#!/bin/sh
#
# Hard-link the runtime assets straight out of the upstream submodule into a
# destination folder.
#
#   Tools/link-assets.sh <upstream-repo> <destination>
#
# Hard links mean the app bundle and the test folder carry the artwork without
# copying it out of the submodule. Both callers build into a fresh directory, so
# nothing here removes stale files.
set -eu

here=$(dirname "$0")
src=${1:?usage: link-assets.sh <upstream-repo> <destination>}
dst=${2:?usage: link-assets.sh <upstream-repo> <destination>}

list=$(mktemp "${TMPDIR:-/tmp}/nuonuo-asset-files.XXXXXX")
trap 'rm -f "$list"' EXIT HUP INT TERM
"$here/asset-files.sh" "$src" > "$list"

tab=$(printf '\t')
count=0
while IFS=$tab read -r destination source; do
	target="$dst/$destination"
	mkdir -p "$(dirname "$target")"
	ln -f "$src/$source" "$target"
	count=$((count + 1))
done < "$list"

printf '%s\n' "Linked $count files into $dst"
