#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/build.sh"
cp -R "$ROOT/dist/LLM Usage Bar.app" /Applications/
open "/Applications/LLM Usage Bar.app"
