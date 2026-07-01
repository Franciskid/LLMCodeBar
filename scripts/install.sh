#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="/Applications/LLMCodeBar.app"
"$ROOT/scripts/build.sh"

# Stop any running instance (old or new name), then fully replace the installed
# bundle and remove the previous "LLM Usage Bar.app" copy.
pkill -f "LLMCodeBar.app/Contents/MacOS/LLMCodeBar" 2>/dev/null || true
pkill -f "LLM Usage Bar.app/Contents/MacOS/LLMUsageBar" 2>/dev/null || true
sleep 1
rm -rf "$DEST" "/Applications/LLM Usage Bar.app"
cp -R "$ROOT/dist/LLMCodeBar.app" "$DEST"
open "$DEST"
echo "Installed and launched: $DEST"
