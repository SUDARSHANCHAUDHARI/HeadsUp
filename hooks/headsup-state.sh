#!/usr/bin/env bash
# Claude Code hook: map the hook event on stdin to a robot state and write it
# to ~/.headsup/state. Never blocks Claude: always exits 0, prints nothing.
dir="$HOME/.headsup"
mkdir -p "$dir" 2>/dev/null || exit 0

input=$(cat)
event=$(printf '%s' "$input" | /usr/bin/plutil -extract hook_event_name raw -o - - 2>/dev/null)
tool=$(printf '%s' "$input" | /usr/bin/plutil -extract tool_name raw -o - - 2>/dev/null)

case "$event" in
  UserPromptSubmit|PostToolUse) state=thinking ;;
  PreToolUse)
    case "$tool" in
      Read|Grep|Glob|WebSearch|WebFetch) state=searching ;;
      *) state=working ;;
    esac ;;
  Notification|PermissionRequest) state=listening ;;
  Stop) state=happy ;;
  StopFailure) state=error ;;
  SessionEnd) state=sleeping ;;
  *) exit 0 ;;
esac

# Write then rename so the app never reads a half-written file.
tmp="$dir/state.$$"
printf '%s\n' "$state" > "$tmp" 2>/dev/null && mv -f "$tmp" "$dir/state" 2>/dev/null
exit 0
