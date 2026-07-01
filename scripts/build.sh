#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/LLM Usage Bar.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
CACHE="$ROOT/.build/module-cache"

rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES" "$CACHE"

swiftc \
  -target arm64-apple-macos13.0 \
  -O \
  -module-cache-path "$CACHE" \
  -framework AppKit \
  -framework Foundation \
  -framework Security \
  "$ROOT/src/main.swift" \
  -o "$MACOS/LLMUsageBar"

cp "$ROOT/Info.plist" "$CONTENTS/Info.plist"
codesign --force --deep --sign - "$APP" >/dev/null

echo "Built: $APP"
