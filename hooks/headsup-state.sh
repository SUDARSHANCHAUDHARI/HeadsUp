#!/usr/bin/env bash
# Claude Code hook: map the hook event on stdin to a robot state and write it
# to ~/.headsup/sessions/<session id>.state, so each live session gets its own
# head. Two lines: the state, then the folder the session is working in, which
# the app shows under the head so you can tell the heads apart.
# Never blocks Claude: always exits 0, prints nothing.
dir="$HOME/.headsup"
mkdir -p "$dir/sessions" 2>/dev/null || exit 0

input=$(cat)
event=$(printf '%s' "$input" | /usr/bin/plutil -extract hook_event_name raw -o - - 2>/dev/null)
tool=$(printf '%s' "$input" | /usr/bin/plutil -extract tool_name raw -o - - 2>/dev/null)
session=$(printf '%s' "$input" | /usr/bin/plutil -extract session_id raw -o - - 2>/dev/null)
cwd=$(printf '%s' "$input" | /usr/bin/plutil -extract cwd raw -o - - 2>/dev/null)
# The folder's name is what a person calls the project; one line, no newlines.
name=$(basename "$cwd" 2>/dev/null | tr -d '\n\r')

# Line three: what the tool is actually doing, so the head says "page.tsx"
# rather than only "working". plutil takes a key path, which keeps this hook
# free of a JSON parser — it runs on every event, so it stays cheap.
field() { printf '%s' "$input" | /usr/bin/plutil -extract "tool_input.$1" raw -o - - 2>/dev/null | tr -d '\n\r'; }
detail=""
case "$tool" in
  Bash) detail=$(field command) ;;
  Edit|Write|NotebookEdit) detail=$(basename "$(field file_path)" 2>/dev/null | tr -d '\n\r') ;;
  Read) detail=$(basename "$(field file_path)" 2>/dev/null | tr -d '\n\r') ;;
  Grep) detail=$(field pattern) ;;
  Glob) detail=$(field pattern) ;;
  WebFetch) detail=$(field url) ;;
  WebSearch) detail=$(field query) ;;
  Task) detail=$(field description) ;;
  ExitPlanMode) detail="plan ready" ;;
esac
# A label, not a text view: one short line.
[ "${#detail}" -gt 60 ] && detail="$(printf '%.59s' "$detail")…"

# The id reaches the filesystem, so keep it to characters that cannot escape
# the directory. Without one, fall back to a single shared head.
session=$(printf '%s' "$session" | tr -c 'A-Za-z0-9._-' '-')
case "$session" in
  "" | -* | .*) session=session ;;
esac

case "$event" in
  UserPromptSubmit|PostToolUse) state=thinking; detail="" ;;
  PreToolUse)
    case "$tool" in
      Read|Grep|Glob|WebSearch|WebFetch) state=searching ;;
      *) state=working ;;
    esac ;;
  Notification|PermissionRequest) state=listening ;;
  # A finished or failed turn is not doing anything, so it says nothing.
  Stop) state=happy; detail="" ;;
  StopFailure) state=error; detail="" ;;
  SessionEnd) state=sleeping; detail="" ;;
  *) exit 0 ;;
esac

# Write then rename so the app never reads a half-written file.
out="$dir/sessions/$session.state"
tmp="$dir/sessions/.$session.$$"
printf '%s\n%s\n%s\n' "$state" "$name" "$detail" > "$tmp" 2>/dev/null && mv -f "$tmp" "$out" 2>/dev/null
exit 0
