#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/LLMCodeBar.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
CACHE="$ROOT/.build/module-cache"

# Clean this build and any leftover from the old app name.
rm -rf "$APP" "$ROOT/dist/LLM Usage Bar.app"
mkdir -p "$MACOS" "$RESOURCES" "$CACHE"

# Compile every Swift source in src/ into the single executable module, once per
# architecture, then lipo them into a universal binary (Apple Silicon + Intel).
SOURCES=("$ROOT"/src/*.swift)
compile() { # <target-triple> <output>
  swiftc \
    -target "$1" \
    -O \
    -module-cache-path "$CACHE" \
    -framework AppKit \
    -framework Foundation \
    -framework Security \
    "${SOURCES[@]}" \
    -o "$2"
}
compile "arm64-apple-macos13.0"  "$MACOS/LLMCodeBar-arm64"
compile "x86_64-apple-macos13.0" "$MACOS/LLMCodeBar-x86_64"
lipo -create "$MACOS/LLMCodeBar-arm64" "$MACOS/LLMCodeBar-x86_64" -o "$MACOS/LLMCodeBar"
rm -f "$MACOS/LLMCodeBar-arm64" "$MACOS/LLMCodeBar-x86_64"

cp "$ROOT/Info.plist" "$CONTENTS/Info.plist"
[ -f "$ROOT/assets/AppIcon.icns" ] && cp "$ROOT/assets/AppIcon.icns" "$RESOURCES/AppIcon.icns"
# Signed with the "LLMCodeBar Signing" certificate when this Mac has it, so the app
# keeps the same identity from one build to the next and macOS remembers what you allowed
# it (Accessibility, keychain items). Without it, an ad-hoc signature: it runs, but every
# build looks like a new app to macOS.
IDENTITY="LLMCodeBar Signing"
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
    codesign --force --deep --sign "$IDENTITY" "$APP" >/dev/null
else
    echo "warning: signing ad hoc, no \"$IDENTITY\" certificate in the keychain" >&2
    codesign --force --deep --sign - "$APP" >/dev/null
fi

echo "Built: $APP"
