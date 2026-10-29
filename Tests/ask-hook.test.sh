#!/usr/bin/env bash
# Tests for hooks/headsup-ask.sh, the one hook that can block a session.
#
#   ./tests/ask-hook.test.sh
#
# Everything runs against a throwaway HOME, so a run never touches ~/.headsup
# or the real settings file. The first three cases are the ones that matter:
# a hook that fails to fail open would make every permission prompt wait.
set -uo pipefail
cd "$(dirname "$0")/.."

hook="$(pwd -P)/hooks/headsup-ask.sh"
pass=0
fail=0

note() { printf '%s\n' "$*"; }
ok()   { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf '  FAIL  %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"; }

check() { # name expected actual
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi
}

contains() { # name needle haystack
  case "$3" in
    *"$2"*) ok "$1" ;;
    *) bad "$1" "something containing '$2'" "$3" ;;
  esac
}

# A fresh HOME per case, with HeadsUp either alive or not.
setup() { # alive|dead|stale
  home=$(mktemp -d)
  mkdir -p "$home/.headsup"
  case "$1" in
    alive) printf '%s\n' $$ > "$home/.headsup/alive" ;;
    stale)
      printf '%s\n' $$ > "$home/.headsup/alive"
      # Older than the 30s staleness limit.
      touch -t "$(date -v-5M +%Y%m%d%H%M)" "$home/.headsup/alive"
      ;;
    dead) : ;;
  esac
}

event() { # tool detail-json
  printf '{"hook_event_name":"PermissionRequest","session_id":"abc-123","cwd":"/tmp/website","tool_name":"%s","tool_input":%s}' "$1" "$2"
}

# Run the hook in the background, wait for its request file, then answer it.
# Returns the hook's stdout.
answer_with() { # verdict event-json
  local verdict="$1" out
  out=$(mktemp)
  HOME="$home" HEADSUP_ASK_TIMEOUT=5 HEADSUP_ASK_POLL=0.05 bash "$hook" > "$out" <<<"$3" &
  local pid=$!
  local waited=0 req=""
  while [ -z "$req" ] && [ "$waited" -lt 100 ]; do
    req=$(ls "$home/.headsup/ask/"*.json 2>/dev/null | head -1)
    [ -n "$req" ] && break
    sleep 0.05
    waited=$((waited + 1))
  done
  if [ -n "$req" ]; then
    printf '%s\n' "$verdict" > "${req%.json}.answer"
  fi
  wait "$pid" 2>/dev/null
  cat "$out"
  rm -f "$out"
}

note "fail open"

setup dead
start=$(date +%s)
out=$(HOME="$home" bash "$hook" <<<"$(event Bash '{"command":"rm -rf /"}')")
elapsed=$(( $(date +%s) - start ))
check "no alive file: prints nothing" "" "$out"
if [ "$elapsed" -le 2 ]; then ok "no alive file: returns at once (${elapsed}s)"; else bad "returns at once" "<=2s" "${elapsed}s"; fi

setup stale
out=$(HOME="$home" bash "$hook" <<<"$(event Bash '{"command":"ls"}')")
check "stale heartbeat: prints nothing" "" "$out"

setup alive
printf 'not-a-pid\n' > "$home/.headsup/alive"
out=$(HOME="$home" bash "$hook" <<<"$(event Bash '{"command":"ls"}')")
check "unreadable pid: prints nothing" "" "$out"

setup alive
printf '%s\n' 999999 > "$home/.headsup/alive"
out=$(HOME="$home" bash "$hook" <<<"$(event Bash '{"command":"ls"}')")
check "dead pid: prints nothing" "" "$out"

note "decisions"

setup alive
out=$(answer_with allow "" "$(event Bash '{"command":"npm install"}')")
contains "allow: behavior allow" '"behavior": "allow"' "$(printf '%s' "$out" | python3 -I -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["hookSpecificOutput"]["decision"]))')"

setup alive
out=$(answer_with deny "" "$(event Bash '{"command":"npm install"}')")
decision=$(printf '%s' "$out" | python3 -I -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["hookSpecificOutput"]["decision"]))')
contains "deny: behavior deny" '"behavior": "deny"' "$decision"
contains "deny: carries a message" 'Denied from HeadsUp' "$decision"

setup alive
out=$(answer_with plan-deny "" "$(event ExitPlanMode '{"plan":"# Build the thing\n- step"}')")
contains "plan-deny: asks what to change" 'Ask what should be different' "$out"

setup alive
out=$(answer_with nonsense "" "$(event Bash '{"command":"ls"}')")
check "unknown verdict: prints nothing" "" "$out"

note "falling back to the terminal"

setup alive
out=$(HOME="$home" HEADSUP_ASK_TIMEOUT=1 HEADSUP_ASK_POLL=0.05 bash "$hook" <<<"$(event Bash '{"command":"ls"}')")
check "timeout: prints nothing" "" "$out"

setup alive
# Delete the request instead of answering it: what the app does when the
# terminal got there first.
out=$(mktemp)
HOME="$home" HEADSUP_ASK_TIMEOUT=5 HEADSUP_ASK_POLL=0.05 bash "$hook" > "$out" <<<"$(event Bash '{"command":"ls"}')" &
hookpid=$!
req=""; waited=0
while [ -z "$req" ] && [ "$waited" -lt 100 ]; do
  req=$(ls "$home/.headsup/ask/"*.json 2>/dev/null | head -1); [ -n "$req" ] && break
  sleep 0.05; waited=$((waited + 1))
done
rm -f "$req"
wait "$hookpid" 2>/dev/null
check "request withdrawn: prints nothing" "" "$(cat "$out")"
rm -f "$out"

note "the request file"

setup alive
HOME="$home" HEADSUP_ASK_TIMEOUT=1 HEADSUP_ASK_POLL=0.05 bash "$hook" > /dev/null <<<"$(event Bash '{"command":"npm install --save-dev vitest","description":"Install vitest"}')" &
hookpid=$!
req=""; waited=0
while [ -z "$req" ] && [ "$waited" -lt 100 ]; do
  req=$(ls "$home/.headsup/ask/"*.json 2>/dev/null | head -1); [ -n "$req" ] && break
  sleep 0.05; waited=$((waited + 1))
done
if [ -n "$req" ]; then
  body=$(cat "$req")
  check "detail is the command"  "npm install --save-dev vitest" "$(printf '%s' "$body" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["detail"])')"
  check "project is the folder"  "website" "$(printf '%s' "$body" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["project"])')"
  check "plan flag is false"     "False" "$(printf '%s' "$body" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["plan"])')"
else
  bad "request file is written" "a .json in ask/" "nothing"
fi
wait "$hookpid" 2>/dev/null
check "request is cleaned up on exit" "" "$(ls "$home/.headsup/ask/" 2>/dev/null)"

setup alive
HOME="$home" HEADSUP_ASK_TIMEOUT=1 HEADSUP_ASK_POLL=0.05 bash "$hook" > /dev/null <<<"$(event ExitPlanMode '{"plan":"# Ship v0.6\n\nsteps"}')" &
hookpid=$!
req=""; waited=0
while [ -z "$req" ] && [ "$waited" -lt 100 ]; do
  req=$(ls "$home/.headsup/ask/"*.json 2>/dev/null | head -1); [ -n "$req" ] && break
  sleep 0.05; waited=$((waited + 1))
done
if [ -n "$req" ]; then
  body=$(cat "$req")
  check "plan flag is true"  "True" "$(printf '%s' "$body" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["plan"])')"
  check "plan detail is its heading" "Ship v0.6" "$(printf '%s' "$body" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["detail"])')"
fi
wait "$hookpid" 2>/dev/null

note "a session id cannot escape the directory"

setup alive
HOME="$home" HEADSUP_ASK_TIMEOUT=1 HEADSUP_ASK_POLL=0.05 bash "$hook" > /dev/null \
  <<<'{"hook_event_name":"PermissionRequest","session_id":"../../../../tmp/escaped","cwd":"/tmp/x","tool_name":"Bash","tool_input":{"command":"ls"}}' &
hookpid=$!
sleep 0.4
inside=$(ls "$home/.headsup/ask/" 2>/dev/null | head -1)
wait "$hookpid" 2>/dev/null
case "$inside" in
  *..*|"") bad "hostile id stays inside ask/" "a sanitised name" "${inside:-nothing written}" ;;
  *) ok "hostile id stays inside ask/ ($inside)" ;;
esac
[ -e /tmp/escaped.json ] && bad "nothing written outside" "no /tmp/escaped.json" "it exists" || ok "nothing written outside ask/"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
