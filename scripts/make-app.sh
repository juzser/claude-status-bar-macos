#!/bin/bash
# Assemble dist/ClaudeStatusBar.app from SwiftPM release binaries.
# No Xcode required — plist + codesign only need Command Line Tools.
#
# The app resolves its resource bundle itself (Sources/ClaudeStatusBar/ResourceBundle.swift)
# by checking Contents/Resources first, so the bundle belongs there rather
# than next to the executable — see the copy step below.
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

# SwiftPM resource bundle (Clawd PNGs). .app convention is Contents/Resources,
# and that's the first place ResourceBundle.swift looks.
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
