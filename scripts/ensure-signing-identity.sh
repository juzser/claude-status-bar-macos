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

# The identity name is overridable only under CSB_SIGNING_DRY_RUN=1, via
# CSB_SIGNING_IDENTITY_NAME; every other build uses the bare literal below,
# so the environment can never choose which CN a real build creates or
# which label -l binds.
if [ "${CSB_SIGNING_DRY_RUN:-}" = "1" ]
then
  SIGNING_IDENTITY_NAME="${CSB_SIGNING_IDENTITY_NAME-ClaudeStatusBar Local Signing}"
else
  SIGNING_IDENTITY_NAME="ClaudeStatusBar Local Signing"
fi
LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# set-key-partition-list below binds its target to this name with -l; an
# empty name would make -l a no-op and fall back to "every key", which is
# exactly the blast radius this script exists to avoid.
if [ -z "$SIGNING_IDENTITY_NAME" ]
then
  echo "ensure-signing-identity: refusing to run set-key-partition-list with an empty identity name" >&2
  exit 1
fi

source "$(dirname "${BASH_SOURCE[0]}")/lib/signing-run.sh"

# find-identity filters by trust validity, which a self-signed leaf cert
# never satisfies (no trusted anchor) even once codesign is already using
# it successfully — so check for the certificate's existence directly
# instead of asking whether it's a "valid" identity.
if ! security find-certificate -c "$SIGNING_IDENTITY_NAME" "$LOGIN_KEYCHAIN" >/dev/null 2>&1; then
  echo "No local signing identity found — creating '$SIGNING_IDENTITY_NAME'..." >&2
  WORKDIR=$(mktemp -d)
  trap 'rm -rf "$WORKDIR"' EXIT

  csb_signing_run openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$WORKDIR/key.pem" -out "$WORKDIR/cert.pem" \
    -subj "/CN=$SIGNING_IDENTITY_NAME" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -addext "basicConstraints=critical,CA:FALSE" 2>/dev/null

  # -legacy: keeps the p12 in an encoding `security import` reliably reads
  # (OpenSSL 3's default pkcs12 cipher is newer than what Security.framework
  # expects). The export password is a fixed placeholder, not a secret — the
  # p12 file is deleted with $WORKDIR right after import; the private key's
  # real protection is the login keychain's own ACLs.
  csb_signing_run openssl pkcs12 -export -name "$SIGNING_IDENTITY_NAME" -legacy -passout pass:claude-status-bar \
    -inkey "$WORKDIR/key.pem" -in "$WORKDIR/cert.pem" \
    -out "$WORKDIR/identity.p12"

  # -T trusts codesign/security to use the key, but on a real login keychain
  # (as opposed to an isolated test keychain) that trust alone still leaves
  # the very first signing attempt blocked on an interactive "codesign wants
  # to use your key" GUI prompt. set-key-partition-list pre-authorizes that
  # access up front instead, at the cost of one native macOS password prompt
  # here, right now, at identity-creation time — never again on later builds.
  csb_signing_run security import "$WORKDIR/identity.p12" -k "$LOGIN_KEYCHAIN" -P claude-status-bar \
    -T /usr/bin/codesign -T /usr/bin/security

  # No -k here: that flag takes the keychain's literal unlock password, not
  # a path, and we deliberately never handle or hardcode that password —
  # omitting it makes security prompt the user via the native GUI instead.
  #
  # -l "$SIGNING_IDENTITY_NAME", not -s: -s takes no operand, so a trailing
  # "$LOGIN_KEYCHAIN" after it is swallowed as the positional keychain
  # argument and the whole login keychain's partition list is rewritten for
  # EVERY signing private key in it, not just this one.
  #
  # What -l bounds: it matches the private key's *print name* (keychain
  # attribute 0x00000001) — not the certificate's CN, and not "the label" in
  # any looser sense. That print name is whatever friendlyName the p12
  # carried, which is why the -name on the export above and this line are one
  # change and not two: without -name, security import leaves the print name
  # at macOS's placeholder "<key>" and this selector matches nothing. The
  # keychain therefore remains the trailing positional argument, since -l
  # consumes exactly its own operand and nothing after it.
  #
  # A selector that matches no key is a no-op, not a widening — so a non-zero
  # exit here is warned about and the build continues; aborting under set -e
  # would leave the cert and key imported but the build dead, which is worse
  # than an unauthorized key that prompts once.
  #
  # $SIGNING_IDENTITY_NAME is overridable only under CSB_SIGNING_DRY_RUN=1
  # (see the top of this file), so no environment can steer which key a real
  # build authorizes.
  set +e
  csb_signing_run security set-key-partition-list -S apple-tool:,apple:,codesign: -l "$SIGNING_IDENTITY_NAME" "$LOGIN_KEYCHAIN"
  CSB_PARTITION_RC=$?
  set -e
  if [ "$CSB_PARTITION_RC" -ne 0 ]; then
    echo "ensure-signing-identity: set-key-partition-list exited $CSB_PARTITION_RC; no key matched -l \"$SIGNING_IDENTITY_NAME\" or the prompt was declined. Signing may prompt once per build." >&2
  fi
fi

export SIGNING_IDENTITY="$SIGNING_IDENTITY_NAME"
