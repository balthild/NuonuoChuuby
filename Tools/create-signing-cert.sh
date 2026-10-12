#!/bin/sh
#
# Create the self-signed certificate NuonuoChuuby is signed with.
#
#   Tools/create-signing-cert.sh [output-directory]     (default: .build/signing)
#
# Writes <output>/NuonuoChuuby-Signing.p12 — a certificate and its private key,
# ready to import — and prints the password protecting it.
#
# The certificate is valid for 100 years on purpose. macOS pins an app's
# automation grants to the signing certificate, so what forces a user to
# re-authorise is *replacing* the certificate, not it expiring. Keep this one.
#
# Whoever holds the .p12 can sign software macOS will treat as this app, so move
# it into 1Password and delete the local copy; the printed steps say how.
set -eu

name=NuonuoChuuby-Signing
out_dir=${1:-.build/signing}
password=$(openssl rand -hex 24)

mkdir -p "$out_dir"
p12="$out_dir/$name.p12"

work=$(mktemp -d "${TMPDIR:-/tmp}/nuonuochuuby-cert.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM

# LibreSSL (what macOS ships) supports -addext. The code-signing EKU is what
# makes codesign consider the certificate an identity at all.
openssl req -x509 -newkey rsa:2048 -nodes -days 36500 \
	-keyout "$work/key.pem" -out "$work/cert.pem" \
	-subj "/CN=$name/O=NuonuoChuuby" \
	-addext "keyUsage=critical,digitalSignature" \
	-addext "extendedKeyUsage=critical,codeSigning" \
	-addext "basicConstraints=critical,CA:false" 2>/dev/null

openssl pkcs12 -export -out "$p12" \
	-inkey "$work/key.pem" -in "$work/cert.pem" \
	-name "$name" -passout "pass:$password"

fingerprint=$(openssl x509 -in "$work/cert.pem" -noout -fingerprint -sha1 | cut -d= -f2)

printf '\n'
printf '%s\n' "Created $p12"
printf '%s\n' "  password:  $password"
printf '%s\n' "  SHA-1:     $fingerprint"
printf '\n'
printf '%s\n' "Next:"
printf '%s\n' "  1. In 1Password, add an item named \"NuonuoChuuby Signing\"."
printf '%s\n' "  2. Add a text field labelled \"p12\" and paste the certificate into it:"
printf '%s\n' "       openssl base64 -A -in '$p12' | pbcopy"
printf '%s\n' "  3. Set the item's own password field to the password above."
printf '%s\n' "  4. Delete the local copy:"
printf '%s\n' "       rm -rf '$out_dir'"
printf '\n'
printf '%s\n' "Until a dedicated certificate exists, keep OP_ITEM_REF pointing at"
printf '%s\n' "\"CalendarShouter Signing\" so this app shares its identity."
