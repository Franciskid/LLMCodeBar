#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/.build"
SOURCES=()
for source in "$ROOT"/src/*.swift; do
  [[ "$source" == "$ROOT/src/main.swift" ]] || SOURCES+=("$source")
done
swiftc -module-cache-path "$ROOT/.build/module-cache" -framework AppKit -framework Foundation -framework Security "${SOURCES[@]}" "$ROOT/tests/main.swift" -o "$ROOT/.build/tests"
"$ROOT/.build/tests" "$@"
