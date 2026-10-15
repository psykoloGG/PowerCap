#!/bin/bash
# Renders Resources/AppIcon.svg into Resources/AppIcon.icns and docs/icon.png. Needs rsvg-convert (brew install librsvg).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"

for size in 16 32 128 256 512; do
    rsvg-convert -w $size -h $size "$ROOT/Resources/AppIcon.svg" -o "$ICONSET/icon_${size}x${size}.png"
    rsvg-convert -w $((size * 2)) -h $((size * 2)) "$ROOT/Resources/AppIcon.svg" -o "$ICONSET/icon_${size}x${size}@2x.png"
done
iconutil -c icns "$ICONSET" -o "$ROOT/Resources/AppIcon.icns"
rsvg-convert -w 256 -h 256 "$ROOT/Resources/AppIcon.svg" -o "$ROOT/docs/icon.png"
