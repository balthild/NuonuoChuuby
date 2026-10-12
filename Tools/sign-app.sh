#!/bin/sh
#
# Sign an app bundle, fetching the signing identity from a secret first when it
# is not already in a keychain.
#
#   Tools/sign-app.sh <app-bundle>
#
# Configuration comes from the environment (the Makefile passes it through):
#
#   SIGN_IDENTITY   auto       materialise the identity from SIGNING_SOURCE, then sign
#                   -          ad-hoc
#                   <name|hash> an identity already in a keychain
#   SIGN_OPTIONS               extra flags for codesign
#
# With SIGN_IDENTITY=auto, SIGNING_SOURCE names where the certificate comes from:
#
#   op   (default) 1Password. OP_ITEM_REF names the item; it needs a text field
#                  `p12` holding the base64 .p12 and a `password` field.
#   env            $SIGNING_P12_BASE64 and $SIGNING_P12_PASSWORD (for CI).
#
# Why this is a script and not Makefile shell: a materialised identity has to sit
# in a throwaway keychain that is *added to the keychain search list* for codesign
# to find it — `codesign --keychain` alone does not (verified) — and both the
# keychain and the search list must be undone however this exits.
set -eu

app=${1:?usage: sign-app.sh <app-bundle>}
identity=${SIGN_IDENTITY:--}
options=${SIGN_OPTIONS:-}

# Sign nested executables before the bundle that contains them.
sign_tree() {
	signer=$1
	main="$app/Contents/MacOS/$(basename "$app" .app)"
	for nested in "$app/Contents/MacOS/"*; do
		[ -f "$nested" ] || continue
		[ "$nested" = "$main" ] && continue
		case "$(file -b "$nested")" in
		Mach-O*) # shellcheck disable=SC2086
			codesign --force $options --sign "$signer" "$nested" ;;
		esac
	done
	# shellcheck disable=SC2086
	codesign --force $options --sign "$signer" "$app"
}

if [ "$identity" != auto ]; then
	sign_tree "$identity"
	exit
fi

case "${SIGNING_SOURCE:-op}" in
op)
	item=${OP_ITEM_REF:-}
	if [ -z "$item" ]; then
		printf '%s\n' "sign-app.sh: OP_ITEM_REF is not set." \
			"  Locally, export the 1Password item that holds the certificate:" \
			"    set -Ux OP_ITEM_REF 'NuonuoChuuby Signing'" >&2
		exit 1
	fi
	p12_base64=$(op item get "$item" --fields label=p12 --reveal)
	p12_password=$(op item get "$item" --fields label=password --reveal)
	;;
env)
	if [ -z "${SIGNING_P12_BASE64:-}" ] || [ -z "${SIGNING_P12_PASSWORD:-}" ]; then
		printf '%s\n' "sign-app.sh: set SIGNING_P12_BASE64 and SIGNING_P12_PASSWORD (for CI)." >&2
		exit 1
	fi
	p12_base64=$SIGNING_P12_BASE64
	p12_password=$SIGNING_P12_PASSWORD
	;;
*)
	printf '%s\n' "sign-app.sh: unknown SIGNING_SOURCE '${SIGNING_SOURCE}' (expected 'op' or 'env')" >&2
	exit 1
	;;
esac

work=$(mktemp -d "${TMPDIR:-/tmp}/nuonuochuuby-sign.XXXXXX")
keychain="$work/signing.keychain-db"
keychain_password=$(openssl rand -hex 16)

# security prints the search list quoted and indented; strip both so the unquoted
# expansion in the trap word-splits back into separate arguments.
search_list=$(security list-keychains -d user | tr -d ' "')
trap 'security list-keychains -d user -s $search_list >/dev/null 2>&1 || true; security delete-keychain "$keychain" >/dev/null 2>&1 || true; rm -rf "$work"' EXIT HUP INT TERM

printf '%s' "$p12_base64" | tr -d '\n\r' | openssl base64 -d -A > "$work/identity.p12"

security create-keychain -p "$keychain_password" "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
security import "$work/identity.p12" -k "$keychain" -P "$p12_password" \
	-T /usr/bin/codesign -T /usr/bin/security
# Without this, codesign is not allowed to use the key it just imported.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
	-k "$keychain_password" "$keychain" >/dev/null
rm -f "$work/identity.p12"

security list-keychains -d user -s "$keychain" $search_list

# The certificate is self-signed, so `find-identity -v` will not list it — it is
# not trusted. Read the hash straight off the certificate instead.
fingerprint=$(security find-certificate -a -Z "$keychain" | awk '/SHA-1 hash:/ { print $3; exit }')

sign_tree "$fingerprint"
