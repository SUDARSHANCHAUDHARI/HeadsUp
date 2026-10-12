#!/usr/bin/env bash
# Start HeadsUp at login, via a per-user LaunchAgent.
# Usage: scripts/login-item.sh install | uninstall | status
#
# The app itself owns the LaunchAgent, so this is a thin wrapper around
# `HeadsUp --login-item`. The same code runs behind the menu bar's
# "Start at Login" toggle.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
bin="$repo/.build/out/Products/Release/HeadsUp"

case "${1:-}" in
  install|uninstall|status) ;;
  *) echo "usage: $0 install | uninstall | status" >&2; exit 2 ;;
esac

[ -x "$bin" ] || { echo "not built: $bin" >&2; echo "run ./build.sh first" >&2; exit 1; }

"$bin" --login-item "$1"

if [ "$1" = status ]; then
  if pgrep -f "$bin" >/dev/null 2>&1; then echo "running: yes"; else echo "running: no"; fi
fi
