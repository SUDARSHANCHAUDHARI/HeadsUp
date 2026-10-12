#!/usr/bin/env bash
# Start HeadsUp at login, via a per-user LaunchAgent.
# Usage: scripts/login-item.sh install | uninstall | status
set -euo pipefail

label="com.sudarshantechlabs.headsup"
plist="$HOME/Library/LaunchAgents/$label.plist"
repo=$(cd "$(dirname "$0")/.." && pwd)
bin="$repo/.build/out/Products/Release/HeadsUp"
domain="gui/$(id -u)"

install_agent() {
  [ -x "$bin" ] || { echo "not built: $bin" >&2; echo "run ./build.sh first" >&2; exit 1; }
  mkdir -p "$(dirname "$plist")"
  cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key><array><string>$bin</string></array>
  <key>RunAtLoad</key><true/>
  <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
PLIST
  /usr/bin/plutil -lint "$plist" >/dev/null || { echo "generated plist is invalid: $plist" >&2; exit 1; }
  # Replace any previous registration; bootout fails harmlessly when absent.
  launchctl bootout "$domain/$label" 2>/dev/null || true
  launchctl bootstrap "$domain" "$plist"
  echo "installed: $plist"
  echo "HeadsUp will start at every login, and is starting now."
}

uninstall_agent() {
  launchctl bootout "$domain/$label" 2>/dev/null || true
  if [ -f "$plist" ]; then rm -f "$plist"; echo "removed: $plist"; else echo "nothing to remove"; fi
}

status_agent() {
  if [ -f "$plist" ]; then echo "plist:   $plist"; else echo "plist:   not installed"; fi
  if launchctl print "$domain/$label" >/dev/null 2>&1; then echo "agent:   loaded"; else echo "agent:   not loaded"; fi
  if pgrep -f "$bin" >/dev/null 2>&1; then echo "running: yes"; else echo "running: no"; fi
}

case "${1:-}" in
  install) install_agent ;;
  uninstall) uninstall_agent ;;
  status) status_agent ;;
  *) echo "usage: $0 install | uninstall | status" >&2; exit 2 ;;
esac
