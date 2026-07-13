#!/bin/bash
# Bake PNG frames from clawd-tank's CSS-animated SVGs (assets/clawd-svg).
# NSImage renders SVG statically only, so the menu bar cycles pre-baked
# frames instead: each SVG is wrapped in an HTML page, every animation is
# paused at a fixed timestamp via the Web Animations API, and headless
# Chrome screenshots the result. 8 frames over 1.6s — the same period as
# ShimmerText, so the icon loop and the text shimmer stay in sync.
set -euo pipefail

CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/assets/clawd-svg"
OUT="$ROOT/Sources/ClaudeStatusBar/Resources/clawd/anim"
FRAMES=8
PERIOD_MS=1600
RENDER=512 # oversample, then sips-downscale to 48 (24 pt @2x) for smooth edges
FINAL=48

[ -x "$CHROME" ] || { echo "Chrome not found at $CHROME" >&2; exit 1; }
mkdir -p "$OUT"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

for svg in "$SRC"/*.svg; do
  name="$(basename "$svg" .svg)"
  for k in $(seq 0 $((FRAMES - 1))); do
    t=$((k * PERIOD_MS / FRAMES))
    html="$WORK/$name-$k.html"
    {
      echo '<!doctype html><meta charset="utf-8">'
      echo "<style>body{margin:0}svg{width:${RENDER}px;height:${RENDER}px;display:block}</style>"
      cat "$svg"
      echo "<script>document.getAnimations().forEach(a=>{a.pause();a.currentTime=$t});</script>"
    } > "$html"
    "$CHROME" --headless=new --disable-gpu --hide-scrollbars \
      --default-background-color=00000000 \
      --window-size="$RENDER,$RENDER" \
      --screenshot="$WORK/$name-$k.png" \
      "file://$html" >/dev/null 2>&1
    printf '.'
  done
  # Crop the icon's frames to their shared content box (the roomy clawd-tank
  # viewBox would otherwise leave the character tiny) and downscale.
  swift "$ROOT/scripts/crop-frames.swift" "$OUT" "$FINAL" "$WORK/$name"-*.png
done
echo
echo "Baked $(ls "$OUT" | wc -l | tr -d ' ') frames into $OUT"
