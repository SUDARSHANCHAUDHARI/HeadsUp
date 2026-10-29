#!/usr/bin/env bash
# Tests for hooks/headsup-state.sh, covering the third line of detail added in
# v0.6 and the two-line format the app must keep reading.
#
#   ./tests/state-hook.test.sh
#
# Runs against a throwaway HOME, so it never touches ~/.headsup.
set -uo pipefail
cd "$(dirname "$0")/.."

hook="$(pwd -P)/hooks/headsup-state.sh"
home=$(mktemp -d)
pass=0
fail=0

check() { # name expected actual
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1)); printf '  ok    %s\n' "$1"
  else
    fail=$((fail + 1)); printf '  FAIL  %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"
  fi
}

run() { # event tool tool_input_json
  printf '{"hook_event_name":"%s","session_id":"s1","cwd":"/tmp/website","tool_name":"%s","tool_input":%s}' "$1" "$2" "$3" \
    | HOME="$home" bash "$hook"
}

line() { # 1-based line number
  sed -n "${1}p" "$home/.headsup/sessions/s1.state"
}

printf 'detail line\n'

run PreToolUse Bash '{"command":"npm install --save-dev vitest"}'
check "bash: state"   "working"                      "$(line 1)"
check "bash: project" "website"                      "$(line 2)"
check "bash: detail"  "npm install --save-dev vitest" "$(line 3)"

run PreToolUse Edit '{"file_path":"/Users/x/site/app/page.tsx"}'
check "edit: state"  "working"   "$(line 1)"
check "edit: detail is the basename" "page.tsx" "$(line 3)"

run PreToolUse Read '{"file_path":"/Users/x/site/README.md"}'
check "read: state is searching" "searching" "$(line 1)"
check "read: detail"             "README.md" "$(line 3)"

run PreToolUse Grep '{"pattern":"TODO"}'
check "grep: detail is the pattern" "TODO" "$(line 3)"

run PermissionRequest ExitPlanMode '{"plan":"# Ship v0.6"}'
check "plan: state is listening" "listening"  "$(line 1)"
check "plan: detail"             "plan ready" "$(line 3)"

printf 'detail is cleared when nothing is running\n'

run Stop Bash '{"command":"ls"}'
check "stop: state"         "happy" "$(line 1)"
check "stop: detail blank"  ""      "$(line 3)"

run PreToolUse Bash '{"command":"ls"}'
run SessionEnd Bash '{}'
check "session end: state"        "sleeping" "$(line 1)"
check "session end: detail blank" ""         "$(line 3)"

printf 'a long command is truncated to fit a label\n'

run PreToolUse Bash '{"command":"swift build -c release --disable-sandbox --scratch-path /tmp/build --verbose --jobs 8"}'
detail=$(line 3)
if [ "${#detail}" -le 61 ]; then
  pass=$((pass + 1)); printf '  ok    long detail is %s characters\n' "${#detail}"
else
  fail=$((fail + 1)); printf '  FAIL  long detail is %s characters, expected <= 61\n' "${#detail}"
fi
case "$detail" in
  *…) pass=$((pass + 1)); printf '  ok    long detail ends in an ellipsis\n' ;;
  *) fail=$((fail + 1)); printf '  FAIL  long detail should end in an ellipsis: %s\n' "$detail" ;;
esac

printf 'the file keeps its shape\n'

run PreToolUse Bash '{"command":"ls"}'
check "four lines" "4" "$(wc -l < "$home/.headsup/sessions/s1.state" | tr -d ' ')"

run PreToolUse UnknownTool '{"whatever":1}'
check "unknown tool: no detail, still four lines" "" "$(line 3)"

# Line four is the owning claude pid, so the app can retire a head the moment
# its session is gone. The test runs under bash, not claude, so the walk up the
# ancestry finds nothing and the line is correctly empty — what an older hook
# wrote too, which is the case the app must still cope with.
printf 'line four is the owning pid\n'
# Either empty or a live pid, never junk. It cannot be asserted as empty here:
# this suite is often run from inside a Claude Code session, and then the walk
# correctly finds that session's own process a few levels up.
run PreToolUse Bash '{"command":"ls"}'
owner=$(line 4)
if [ -z "$owner" ] || { [ "$owner" -gt 0 ] 2>/dev/null && kill -0 "$owner" 2>/dev/null; }; then
  pass=$((pass + 1)); printf '  ok    owner is empty or a live pid (%s)\n' "${owner:-empty}"
else
  fail=$((fail + 1)); printf '  FAIL  owner is neither empty nor a live pid: %s\n' "$owner"
fi

# A copy of bash named `claude` gives the walk a real ancestor to find: ps
# reports the executable's path, so the copy's name is what the hook matches
# on. Its own pid is what must land on line four.
shim="$home/claude"
cp /bin/bash "$shim"
owner=$(HOME="$home" "$shim" -c '
  printf "%s" "$1" | bash "$2" >/dev/null 2>&1
  sed -n "4p" "$HOME/.headsup/sessions/s1.state"
  printf " %s" "$$"
' claude '{"hook_event_name":"PreToolUse","tool_name":"Bash","session_id":"s1","cwd":"/tmp/proj","tool_input":{"command":"ls"}}' "$hook")
check "the claude ancestor's pid is the owner" "${owner#* }" "${owner%% *}"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
printf 'scratch HOME left at %s\n' "$home"
[ "$fail" -eq 0 ]
