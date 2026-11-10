#!/usr/bin/env bash
# Renders the app views offscreen (demo data, no system permission needed) in light and dark.
# Usage: scripts/screenshots.sh [outdir] [scene-name-filter] [--language fr]
#        scripts/screenshots.sh --readme   (refreshes docs/images: the README scenes, English)
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "$(xcode-select -p)" == "/Library/Developer/CommandLineTools" ]]; then
  export DEVELOPER_DIR="$(ls -d /Applications/Xcode*.app | sort | tail -1)/Contents/Developer"
fi

xcodegen generate --quiet
xcodebuild -project Navette.xcodeproj -scheme NavetteScreenshots -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath build -quiet build

BIN=build/Build/Products/Debug/NavetteScreenshots.app/Contents/MacOS/NavetteScreenshots
README_SCENES=(browser browser-inspector transfers connection-sftp prompt-host-key deletion)

if [[ "${1:-}" == "--readme" ]]; then
  STAGE=build/readme-shots
  rm -rf "$STAGE" && mkdir -p "$STAGE" docs/images
  for scene in "${README_SCENES[@]}"; do
    "$BIN" "$STAGE" "$scene" >/dev/null
    for theme in light dark; do
      cp "$STAGE/$scene-$theme.png" "docs/images/$scene-$theme.png"
    done
  done
  if command -v pngquant >/dev/null; then pngquant --force --skip-if-larger --ext .png docs/images/*-*.png || true; fi
  du -ch docs/images/*.png | tail -1
  exit 0
fi

OUT="${1:-build/screenshots}"
shift || true
"$BIN" "$OUT" "$@"
