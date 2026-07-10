#!/bin/bash
# Assemble dist/ClaudeStatusBar.app from SwiftPM release binaries.
# No Xcode required — plist + codesign only need Command Line Tools.
#
# KNOWN ISSUE (discovered while writing this script): SwiftPM's generated
# Bundle.module accessor (.build/*/release/*/DerivedSources/resource_bundle_accessor.swift)
# resolves the resource bundle via `Bundle.main.bundleURL.appendingPathComponent(name)`,
# falling back to an absolute build-machine path baked in at compile time.
# Inside a real .app, Bundle.main.bundleURL is the .app package root itself
# (sibling of Contents/) — verified empirically — which codesign refuses to
# sign with loose content ("unsealed contents present in the bundle root").
# So the primary lookup path can never resolve in a validly-signed, portable
# .app, and the build-machine-absolute fallback will not exist once the DMG
# is installed on another machine: Bundle.module's lazy init will
# Swift.fatalError(), crashing the app on first render of the menu bar icon
# (MenuBarLabelView.swift). Fixing this needs a source-level resource lookup
# (e.g. also checking Bundle.main.resourceURL) — out of scope here, since
# this task may not touch Package.swift or Swift source. Flagged for a
# follow-up task; do not assume the packaged .app works away from this box
# until that lands.
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="${VERSION:-0.1.0}"
APP="dist/ClaudeStatusBar.app"
BIN=".build/release"

swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN/ClaudeStatusBar" "$APP/Contents/MacOS/"
cp "$BIN/claude-status-hook" "$APP/Contents/MacOS/"

# SwiftPM resource bundle (Clawd PNGs). .app convention is Contents/Resources.
# NOTE: a copy was also placed in Contents/MacOS in an earlier draft of this
# script, matching Bundle.module's "next to the executable" fallback path —
# but codesign rejects a loose *.bundle directory living next to Mach-O
# executables ("bundle format unrecognized, invalid, or unsuitable"), so only
# Contents/Resources is populated here. See KNOWN ISSUE below.
BUNDLE="$BIN/claude-status-bar-macos_ClaudeStatusBar.bundle"
if [ -d "$BUNDLE" ]; then
  cp -R "$BUNDLE" "$APP/Contents/Resources/"
else
  echo "warning: resource bundle not found at $BUNDLE" >&2
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.juzser.ClaudeStatusBar</string>
    <key>CFBundleName</key>
    <string>ClaudeStatusBar</string>
    <key>CFBundleExecutable</key>
    <string>ClaudeStatusBar</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>MIT License. Clawd artwork © clawd-tank (MIT).</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"
echo "Built $APP (version $VERSION)"
