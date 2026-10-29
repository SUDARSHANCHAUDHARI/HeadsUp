#!/usr/bin/env bash
# Claude Code PermissionRequest hook: let the head answer instead of the terminal.
#
# Unlike headsup-state.sh this one *blocks*. It writes the pending request to
# ~/.headsup/ask/<session>.<pid>.json, waits for the app to drop a matching
# .answer file, then prints the decision on stdout. Printing nothing hands the
# decision back to Claude Code's own path, so the terminal dialog still works.
#
# Fails open: if HeadsUp is not running, this exits 0 at once and a permission
# prompt behaves exactly as it would without HeadsUp installed. That matters
# more than the feature — a hook that hangs would make every prompt wait.
dir="$HOME/.headsup"
ask="$dir/ask"
alive="$dir/alive"

# 300s, matching TwoCode. Confirmed in a real session on 30 Oct 2026: Claude
# Code shows its own dialog at the same time as the head, and whichever is
# answered first wins, so a long wait is never a stuck prompt — the terminal
# is always still there to answer.
# The two overrides are a seam for the tests; a real session never sets them.
timeout_s=${HEADSUP_ASK_TIMEOUT:-300}
poll_s=${HEADSUP_ASK_POLL:-0.2}
# A heartbeat older than this means the app died without clearing the file.
stale_s=30

input=$(cat)

# ---- fail open ----------------------------------------------------------
# No app, no waiting. Every branch here exits 0 and prints nothing.
[ -f "$alive" ] || exit 0
pid=$(tr -dc '0-9' < "$alive" 2>/dev/null)
[ -n "$pid" ] || exit 0
kill -0 "$pid" 2>/dev/null || exit 0
# Being alive is not enough: the pid could have been recycled onto something
# else entirely, so the file must also have been touched recently.
age=$(python3 -I -c 'import os,sys,time; print(int(time.time()-os.path.getmtime(sys.argv[1])))' "$alive" 2>/dev/null) || exit 0
[ "$age" -le "$stale_s" ] 2>/dev/null || exit 0

mkdir -p "$ask" 2>/dev/null || exit 0

# ---- write the request --------------------------------------------------
# $$ is this hook's own pid, which makes the name unique: Claude Code runs
# tools in parallel, so a key of session id alone would let a second request
# overwrite the first. The event carries no tool-call id to use instead.
req="$$"
id=""
# The event goes through a file, not stdin and not the environment: stdin is
# already taken by the script below, and a long ExitPlanMode plan could run up
# against the environment size limit.
raw=$(mktemp "${TMPDIR:-/tmp}/headsup-ask.XXXXXX") || exit 0
printf '%s' "$input" > "$raw"
trap 'rm -f "$raw" 2>/dev/null' EXIT

if ! id=$(HEADSUP_ASK_DIR="$ask" HEADSUP_REQ="$req" HEADSUP_ASK_EVENT="$raw" python3 -I - <<'PY'
import json, os, re, sys

ask = os.environ["HEADSUP_ASK_DIR"]
req = os.environ["HEADSUP_REQ"]
try:
    with open(os.environ["HEADSUP_ASK_EVENT"], encoding="utf-8") as f:
        event = json.load(f)
except (OSError, ValueError):
    sys.exit(1)

# The id reaches the filesystem, so keep it to characters that cannot escape
# the directory, the same way headsup-state.sh does.
session = re.sub(r"[^A-Za-z0-9._-]", "-", str(event.get("session_id") or ""))
if not session or session.startswith(("-", ".")):
    session = "session"

tool = str(event.get("tool_name") or "")
raw = event.get("tool_input")
raw = raw if isinstance(raw, dict) else {}


def first_line(value, limit=90):
    """One short line: these land in a label, not a text view."""
    text = " ".join(str(value).split())
    return text[: limit - 1] + "…" if len(text) > limit else text


# What a person needs to see to judge the request. Bash carries a written
# description as well as the command, and it reads better than the command.
if tool == "Bash":
    detail = first_line(raw.get("command") or raw.get("description") or "")
elif tool in ("Edit", "Write", "NotebookEdit"):
    detail = first_line(os.path.basename(str(raw.get("file_path") or "")))
elif tool == "ExitPlanMode":
    plan = str(raw.get("plan") or "")
    detail = first_line(plan.lstrip("# ").splitlines()[0] if plan.strip() else "plan ready")
else:
    detail = first_line(raw.get("description") or raw.get("pattern") or raw.get("url") or "")

request = {
    "session": str(event.get("session_id") or ""),
    "project": os.path.basename(str(event.get("cwd") or "")),
    "tool": tool,
    "detail": detail,
    "plan": tool == "ExitPlanMode",
    "at": __import__("time").time(),
}

name = f"{session}.{req}"
tmp = os.path.join(ask, f".{name}.tmp")
try:
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(request, f)
    os.replace(tmp, os.path.join(ask, f"{name}.json"))
except OSError:
    sys.exit(1)
print(name)
PY
); then
  exit 0  # could not write the request: behave as if HeadsUp were closed
fi
[ -n "$id" ] || exit 0

json="$ask/$id.json"
answer="$ask/$id.answer"
# Leave nothing behind for the next scan to find, however this hook ends.
trap 'rm -f "$raw" "$json" "$answer" 2>/dev/null' EXIT

# ---- wait for the click -------------------------------------------------
deadline=$(python3 -I -c "import time,sys; print(time.time()+float(sys.argv[1]))" "$timeout_s")
while :; do
  if [ -f "$answer" ]; then
    verdict=$(tr -d '\n\r ' < "$answer" 2>/dev/null)
    break
  fi
  # The app clears the request when the terminal answered first, or when it quits.
  [ -f "$json" ] || exit 0
  python3 -I -c "import time,sys; sys.exit(0 if time.time()<float(sys.argv[1]) else 1)" "$deadline" || exit 0
  sleep "$poll_s"
done

case "$verdict" in
  allow)
    printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'
    ;;
  deny)
    # A fixed message by decision: no free-text box in the UI, so there is
    # nothing to put here that the user actually wrote.
    printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Denied from HeadsUp."}}}'
    ;;
  plan-deny)
    printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"The user sent the plan back from HeadsUp. Ask what should be different before building."}}}'
    ;;
  *) : ;; # unknown or empty: say nothing and let the normal path decide
esac
exit 0
