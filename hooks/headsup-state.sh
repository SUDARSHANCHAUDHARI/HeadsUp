#!/usr/bin/env bash
# Claude Code hook: map the hook event on stdin to a robot state and write it
# to ~/.headsup/sessions/<session id>.state, so each live session gets its own
# head. Never blocks Claude: always exits 0, prints nothing.
dir="$HOME/.headsup"
mkdir -p "$dir/sessions" 2>/dev/null || exit 0

input=$(cat)
event=$(printf '%s' "$input" | /usr/bin/plutil -extract hook_event_name raw -o - - 2>/dev/null)
tool=$(printf '%s' "$input" | /usr/bin/plutil -extract tool_name raw -o - - 2>/dev/null)
session=$(printf '%s' "$input" | /usr/bin/plutil -extract session_id raw -o - - 2>/dev/null)

# The id reaches the filesystem, so keep it to characters that cannot escape
# the directory. Without one, fall back to a single shared head.
session=$(printf '%s' "$session" | tr -c 'A-Za-z0-9._-' '-')
case "$session" in
  "" | -* | .*) session=session ;;
esac

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
out="$dir/sessions/$session.state"
tmp="$dir/sessions/.$session.$$"
printf '%s\n' "$state" > "$tmp" 2>/dev/null && mv -f "$tmp" "$out" 2>/dev/null
exit 0
