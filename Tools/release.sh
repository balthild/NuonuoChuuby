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

asset=".build/dist/NuonuoChuuby-$version.zip"
test -f "$asset" || { echo "missing artifact: $asset" >&2; exit 1; }

# The checksum can only be taken from the assembled zip, so the cask is stamped
# after packaging and the stamp travels in the release commit.
sha256="$(shasum -a 256 "$asset" | awk '{print $1}')"

cask=Casks/nuonuo-chubby.rb
sed -i '' -E "s/^([[:space:]]*)version .*/\1version \"$semver\"/" "$cask"
sed -i '' -E "s/^([[:space:]]*)sha256 .*/\1sha256 \"$sha256\"/" "$cask"
grep -q "version \"$semver\"" "$cask" || { echo "failed to stamp version in $cask" >&2; exit 1; }
grep -q "sha256 \"$sha256\"" "$cask" || { echo "failed to stamp sha256 in $cask" >&2; exit 1; }

git add "$cask"
git commit -m "Release $version"

git tag "$version"
git push origin HEAD
git push origin "$version"
gh release create "$version" "$asset" --notes "Release $version"
