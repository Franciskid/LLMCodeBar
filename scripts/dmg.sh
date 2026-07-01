#!/usr/bin/env bash
# Build the app and package it into a drag-to-install .dmg.
# No Developer ID needed — the image just carries the app plus an /Applications
# shortcut. (Users bypass Gatekeeper once on first launch; see the README.)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/LLMCodeBar.app"
DMG="$ROOT/dist/LLMCodeBar.dmg"
STAGE="$(mktemp -d)"

"$ROOT/scripts/build.sh"

# Stage the app next to an /Applications symlink so users can drag-and-drop.
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create \
  -volname "LLMCodeBar" \
  -srcfolder "$STAGE" \
  -ov -format UDZO \
  "$DMG" >/dev/null

rm -rf "$STAGE"
echo "Packaged: $DMG"
