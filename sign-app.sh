#!/bin/bash
set -euo pipefail
bundle=${1:?Pass the app bundle to sign}
identifier=org.telugish.dictation
sign_dir="$HOME/Library/Application Support/Telugish Flow Signing"

if [[ -n "${TELUGISH_SIGNING_IDENTITY:-}" ]]; then
    [[ "$TELUGISH_SIGNING_IDENTITY" != "-" ]] || { echo "A persistent signing identity is required." >&2; exit 1; }
    codesign --force --sign "$TELUGISH_SIGNING_IDENTITY" --identifier "$identifier" "$bundle"
else
    pem="$sign_dir/identity.pem"
    signer="$sign_dir/rcodesign"
    if [[ ! -r "$pem" || ! -x "$signer" ]]; then
        echo "Set TELUGISH_SIGNING_IDENTITY to a Keychain signing certificate fingerprint, or restore your local signing identity and rcodesign." >&2
        exit 1
    fi
    cert_hash=$(openssl x509 -in "$pem" -outform DER | shasum | cut -d' ' -f1)
    requirement="identifier \"$identifier\" and certificate leaf = H\"$cert_hash\""
    req_file=$(mktemp)
    trap 'unlink "$req_file"' EXIT
    csreq -r "=$requirement" -b "$req_file"
    "$signer" sign --config-file /dev/null --timestamp-url none --pem-file "$pem" --shallow --code-requirements-file "$req_file" "$bundle"
    codesign --verify --strict -R="$requirement" "$bundle"
fi
codesign --verify --strict "$bundle"
