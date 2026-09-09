#!/bin/bash
# Assemble dist/ClaudeStatusBar.app from SwiftPM release binaries.
# No Xcode required — plist + codesign only need Command Line Tools.
#
# The app resolves its resource bundle itself (Sources/ClaudeStatusBar/ResourceBundle.swift)
# by checking Contents/Resources first, so the bundle belongs there rather
# than next to the executable — see the copy step below.
set -euo pipefail

# Refuse to build a real, signed artifact while the signing indirection is
# in dry-run mode: a dry run only ever asserts on printed argv, never on a
# real codesign result, and running it here would be silent no-op signing
# rather than the refusal the dry-run mode promises.
if [ "${CSB_SIGNING_DRY_RUN:-}" = "1" ]
then
  echo "make-app: refusing to build a real artifact with CSB_SIGNING_DRY_RUN set" >&2
  exit 1
fi

cd "$(dirname "$0")/.."
VERSION="${VERSION:-1.0.2}"
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

# Sign inside-out and without --deep: --deep re-signs nested code with
# whatever ad-hoc/unhardened signature it finds baked into the SwiftPM
# binary, which is how the previous single --force --deep --sign left the
# final bundle unhardened (flags=0x0(none)) despite specifying a real
# identity. Each executable gets --options runtime (hardened runtime) and
# --timestamp explicitly, nested ones before the bundle that embeds them,
# and set -euo pipefail above already makes a failed --timestamp fatal.
for NESTED_BIN in "$APP/Contents/MacOS"/*; do
  if [ "$(basename "$NESTED_BIN")" = "ClaudeStatusBar" ]; then
    continue
  fi
  codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$NESTED_BIN"
done
codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP"
echo "Built $APP (version $VERSION)"
