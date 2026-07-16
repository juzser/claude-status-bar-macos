#!/bin/bash
# Assemble dist/ClaudeStatusBar.app from SwiftPM release binaries.
# No Xcode required — plist + codesign only need Command Line Tools.
#
# The app resolves its resource bundle itself (Sources/ClaudeStatusBar/ResourceBundle.swift)
# by checking Contents/Resources first, so the bundle belongs there rather
# than next to the executable — see the copy step below.
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="${VERSION:-0.1.5}"
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

# App icon: derive AppIcon.icns from the source PNG at build time rather
# than committing a generated binary — assets/icon.png stays the one source
# of truth.
ICON_SRC="assets/icon.png"
if [ -f "$ICON_SRC" ]; then
  ICONSET=$(mktemp -d)/AppIcon.iconset
  mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$ICON_SRC" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$ICON_SRC" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
  rm -rf "$(dirname "$ICONSET")"
else
  echo "warning: $ICON_SRC not found, app will use the default icon" >&2
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
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
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

source scripts/ensure-signing-identity.sh
codesign --force --deep --sign "$SIGNING_IDENTITY" "$APP"
echo "Built $APP (version $VERSION)"
