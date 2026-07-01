#!/usr/bin/env bash
# Rebuild, replace the installed app in /Applications, and relaunch it.
# Using /Applications keeps a single canonical copy you can also launch from
# Launchpad, and keeps the autostart LaunchAgent pointing at a stable path.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec "$ROOT/scripts/install.sh"
