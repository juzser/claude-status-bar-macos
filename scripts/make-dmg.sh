#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT

cp -R dist/ClaudeStatusBar.app "$STAGING/"
ln -s /Applications "$STAGING/Applications"

rm -f dist/ClaudeStatusBar.dmg
hdiutil create -volname ClaudeStatusBar -srcfolder "$STAGING" \
  -ov -format UDZO dist/ClaudeStatusBar.dmg
