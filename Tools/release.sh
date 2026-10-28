#!/bin/sh
set -eu

kind="${1:-}"

case "$kind" in
	major | minor | patch) ;;
	*)
		echo "USAGE: $0 <major|minor|patch>" >&2
		exit 1
		;;
esac

if [ -n "$(git status --porcelain)" ]; then
	echo "git working tree is not clean" >&2
	exit 1
fi

semver="$(nix run nixpkgs#svu -- --tag.prefix="" "$kind")"
version="v$semver"

echo "Releasing $version"

if gh release view "$version" >/dev/null 2>&1; then
	echo "release $version already exists" >&2
	exit 1
fi

make clean
make test CONFIG=release
make package CONFIG=release SEMVER="$semver"

asset=".build/dist/NuonuoChuuby-$version.dmg"
test -f "$asset" || { echo "missing artifact: $asset" >&2; exit 1; }

# Only this side has the assembled image to hash; the tap stamps the value into
# the cask from the workflow dispatched below.
sha256="$(shasum -a 256 "$asset" | awk '{print $1}')"

git tag "$version"
git push origin "$version"
gh release create "$version" "$asset" --notes "Release $version"

gh workflow run update-cask.yml \
	--repo balthild/homebrew-tap \
	-f name="nuonuo-chuuby" \
	-f semver="$semver" \
	-f sha256="$sha256"
