#!/usr/bin/env bash
# Build, sign and publish the version in Info.plist as a GitHub release.
# Usage: scripts/release.sh <notes-file>
#
# No Apple Developer account involved. The disk image gets an Ed25519 signature
# (LLMCodeBar.dmg.sig) from the key in the login keychain, and installed copies only
# take an update whose signature checks out against the public key in Updater.swift.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NOTES="${1:?usage: scripts/release.sh <notes-file>}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Info.plist")"
TAG="v$VERSION"
DMG="$ROOT/dist/LLMCodeBar.dmg"
SIGNER="$ROOT/.build/update-signing"
PUBLIC_KEY="$(sed -n 's/.*static let signingPublicKey = "\(.*\)".*/\1/p' "$ROOT/src/Updater.swift")"

if [ -n "$(git -C "$ROOT" status --porcelain)" ]; then
  echo "Commit your changes first." >&2
  exit 1
fi
git -C "$ROOT" fetch -q origin
if ! git -C "$ROOT" merge-base --is-ancestor origin/main HEAD; then
  echo "This checkout is behind origin/main. Bring it up to date first." >&2
  exit 1
fi

mkdir -p "$ROOT/.build"
swiftc -O "$ROOT/scripts/update-signing.swift" -o "$SIGNER"
[ "$("$SIGNER" public-key)" = "$PUBLIC_KEY" ] || { echo "The keychain's signing key doesn't match Updater.swift." >&2; exit 1; }
REQUIRE_SIGNING_IDENTITY=1 "$ROOT/scripts/dmg.sh"

BUILT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/dist/LLMCodeBar.app/Contents/Info.plist")"
[ "$BUILT" = "$VERSION" ] || { echo "Built $BUILT, expected $VERSION." >&2; exit 1; }

"$SIGNER" sign "$DMG"
"$SIGNER" verify "$DMG" "$PUBLIC_KEY"
(cd "$ROOT/dist" && shasum -a 256 LLMCodeBar.dmg > SHA256SUMS)
git -C "$ROOT" push origin HEAD:main
gh release create "$TAG" "$DMG" "$DMG.sig" "$ROOT/dist/SHA256SUMS" --target "$(git -C "$ROOT" rev-parse HEAD)" --title "LLMCodeBar $TAG" --notes-file "$NOTES"
echo "Published $TAG"
