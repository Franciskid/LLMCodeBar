#!/usr/bin/env bash
set -euo pipefail
# Runs each file in tests/ against the app's own code: every source in src/ except
# main.swift, plus one test file as the entry point. Arguments go to tests/main.swift.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/.build/test-runs"
mkdir -p "$OUT" "$ROOT/.build/module-cache"
SOURCES=()
for source in "$ROOT"/src/*.swift; do
  [[ "$source" == "$ROOT/src/main.swift" ]] || SOURCES+=("$source")
done
for test in "$ROOT"/tests/*.swift; do
  name="$(basename "$test" .swift)"
  mkdir -p "$OUT/$name"
  cp "$test" "$OUT/$name/main.swift"
  swiftc -suppress-warnings -module-cache-path "$ROOT/.build/module-cache" -framework AppKit -framework Foundation -framework Security \
    "${SOURCES[@]}" "$OUT/$name/main.swift" -o "$OUT/$name/run"
  if [[ "$name" == main ]]; then (cd "$ROOT" && "$OUT/$name/run" "$@"); else (cd "$ROOT" && "$OUT/$name/run"); fi
done
