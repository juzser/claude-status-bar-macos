#!/bin/bash
# Ensures a stable, self-signed code-signing identity exists in the login
# keychain, and exports its name as SIGNING_IDENTITY. Meant to be sourced
# by scripts/make-app.sh before its codesign step, not run standalone.
#
# Ad-hoc signing (`codesign --sign -`) derives its designated requirement
# from a hash of the binary's own bytes, so it changes on every rebuild.
# macOS ties Keychain "Always Allow" grants (e.g. for the cux credentials
# this app reads) to the requesting app's designated requirement, so an
# identity that changes on every build invalidates those grants and forces
# a re-prompt on every launch. Signing with a real certificate — even a
# self-signed one — anchors the requirement to the certificate instead of
# the binary content, so it survives rebuilds.
set -euo pipefail

SIGNING_IDENTITY_NAME="ClaudeStatusBar Local Signing"
LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# find-identity filters by trust validity, which a self-signed leaf cert
# never satisfies (no trusted anchor) even once codesign is already using
# it successfully — so check for the certificate's existence directly
# instead of asking whether it's a "valid" identity.
if ! security find-certificate -c "$SIGNING_IDENTITY_NAME" "$LOGIN_KEYCHAIN" >/dev/null 2>&1; then
  echo "No local signing identity found — creating '$SIGNING_IDENTITY_NAME'..." >&2
  WORKDIR=$(mktemp -d)
  trap 'rm -rf "$WORKDIR"' EXIT

  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$WORKDIR/key.pem" -out "$WORKDIR/cert.pem" \
    -subj "/CN=$SIGNING_IDENTITY_NAME" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -addext "basicConstraints=critical,CA:FALSE" >/dev/null 2>&1

  # -legacy: keeps the p12 in an encoding `security import` reliably reads
  # (OpenSSL 3's default pkcs12 cipher is newer than what Security.framework
  # expects). The export password is a fixed placeholder, not a secret — the
  # p12 file is deleted with $WORKDIR right after import; the private key's
  # real protection is the login keychain's own ACLs.
  openssl pkcs12 -export -legacy -passout pass:claude-status-bar \
    -inkey "$WORKDIR/key.pem" -in "$WORKDIR/cert.pem" \
    -out "$WORKDIR/identity.p12"

  # -T trusts codesign/security to use the key, but on a real login keychain
  # (as opposed to an isolated test keychain) that trust alone still leaves
  # the very first signing attempt blocked on an interactive "codesign wants
  # to use your key" GUI prompt. set-key-partition-list pre-authorizes that
  # access up front instead, at the cost of one native macOS password prompt
  # here, right now, at identity-creation time — never again on later builds.
  security import "$WORKDIR/identity.p12" -k "$LOGIN_KEYCHAIN" -P claude-status-bar \
    -T /usr/bin/codesign -T /usr/bin/security

  # No -k here: that flag takes the keychain's literal unlock password, not
  # a path, and we deliberately never handle or hardcode that password —
  # omitting it makes security prompt the user via the native GUI instead.
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s "$LOGIN_KEYCHAIN"
fi

export SIGNING_IDENTITY="$SIGNING_IDENTITY_NAME"
