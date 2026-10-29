#!/usr/bin/env bash
# Add (or remove) the HeadsUp hooks in ~/.claude/settings.json, so the head
# follows a live Claude Code session without anyone hand-editing JSON.
#
#   ./scripts/install-hooks.sh              # add the hooks
#   ./scripts/install-hooks.sh --status     # which events have them
#   ./scripts/install-hooks.sh --uninstall  # take them out again
#
# Two hooks go in. headsup-state.sh is fire-and-forget and reports what the
# session is doing. headsup-ask.sh blocks on PermissionRequest so Allow and
# Deny can be answered from the head; it fails open, so a closed HeadsUp
# leaves permission prompts exactly as they were.
#
# Only this script's own entries are ever added or removed. Every other hook in
# the file, and the statusLine, are left untouched — the file is read, two
# groups are changed, and it is written back. The previous copy is kept with a
# timestamp, so a second run cannot overwrite the good backup.
# Open Claude Code sessions keep their old hooks; new ones pick these up.
set -euo pipefail
cd "$(dirname "$0")/.."

repo=$(pwd -P)
state_hook="$repo/hooks/headsup-state.sh"
ask_hook="$repo/hooks/headsup-ask.sh"
settings="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
mode=install

case "${1:-}" in
  "") ;;
  --status) mode=status ;;
  --uninstall) mode=uninstall ;;
  -h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
esac

for script in "$state_hook" "$ask_hook"; do
  [ -f "$script" ] || { echo "hook script missing: $script" >&2; exit 1; }
done
command -v python3 >/dev/null || { echo "python3 not found; it ships with macOS" >&2; exit 1; }

HEADSUP_STATE_HOOK="$state_hook" HEADSUP_ASK_HOOK="$ask_hook" \
HEADSUP_SETTINGS="$settings" HEADSUP_MODE="$mode" python3 -I - <<'PY'
import json, os, shutil, sys, time

path = os.environ["HEADSUP_SETTINGS"]
mode = os.environ["HEADSUP_MODE"]

state_command = f'bash {os.environ["HEADSUP_STATE_HOOK"]}'
ask_command = f'bash {os.environ["HEADSUP_ASK_HOOK"]}'

# The status hook: cheap, never blocks, wanted on everything that changes what
# the head should show.
STATE_EVENTS = [
    "UserPromptSubmit", "PreToolUse", "PostToolUse", "Notification",
    "PermissionRequest", "Stop", "StopFailure", "SessionEnd",
]
# The blocking hook: one event only. Its timeout must clear the hook's own
# 300s wait, or Claude Code would kill it mid-wait and the click would be lost.
ASK_EVENT = "PermissionRequest"
ASK_TIMEOUT = 310

# (event, the entry to add) for everything this script owns.
WANTED = [(event, {"type": "command", "command": state_command}) for event in STATE_EVENTS]
WANTED.append((ASK_EVENT, {"type": "command", "command": ask_command, "timeout": ASK_TIMEOUT}))
OURS = {state_command, ask_command}

if os.path.exists(path):
    try:
        with open(path, encoding="utf-8") as f:
            settings = json.load(f)
    except (OSError, ValueError) as err:
        # Never overwrite a file we could not read: a bad merge or a typo in
        # settings.json is the user's to fix, not ours to flatten.
        sys.exit(f"cannot read {path}: {err}")
    if not isinstance(settings, dict):
        sys.exit(f"{path} is not a JSON object")
else:
    if mode != "install":
        sys.exit(f"no settings file at {path}")
    settings = {}

hooks = settings.setdefault("hooks", {})
if not isinstance(hooks, dict):
    sys.exit(f'"hooks" in {path} is not an object')


def groups(event):
    """The hook groups for one event, creating the list only when installing."""
    existing = hooks.get(event)
    if isinstance(existing, list):
        return existing
    if existing is not None:
        sys.exit(f'"hooks.{event}" in {path} is not a list')
    return hooks.setdefault(event, []) if mode == "install" else []


def group_has(group, command):
    if not isinstance(group, dict):
        return False
    entries = group.get("hooks")
    return isinstance(entries, list) and any(
        isinstance(e, dict) and e.get("command") == command for e in entries
    )


def is_ours(group):
    return any(group_has(group, command) for command in OURS)


def installed(event, command):
    return any(group_has(g, command) for g in (hooks.get(event) or []))


if mode == "status":
    print(f"settings: {path}")
    print(f"status:   {state_command}")
    print(f"ask:      {ask_command}")
    for event, entry in WANTED:
        which = "ask" if entry["command"] == ask_command else "status"
        mark = "yes" if installed(event, entry["command"]) else "no "
        print(f"  {mark}  {event} ({which})")
    sys.exit(0)


def retime(event, command, timeout):
    """Bring an already-installed entry's timeout up to date.

    Without this an upgrade keeps the timeout it was first installed with:
    the command is unchanged, so the check above says there is nothing to do,
    and a hook that now waits longer than its registered timeout would be
    killed mid-wait with the click lost.
    """
    for group in hooks.get(event) or []:
        if not isinstance(group, dict):
            continue
        for e in group.get("hooks") or []:
            if isinstance(e, dict) and e.get("command") == command and e.get("timeout") != timeout:
                e["timeout"] = timeout
                return True
    return False


changed = []
if mode == "install":
    for event, entry in WANTED:
        if installed(event, entry["command"]):
            if "timeout" in entry and retime(event, entry["command"], entry["timeout"]):
                changed.append(f"{event} (ask timeout -> {entry['timeout']}s)")
            continue
        groups(event).append({"matcher": "*", "hooks": [dict(entry)]})
        which = "ask" if entry["command"] == ask_command else "status"
        changed.append(f"{event} ({which})")
else:
    for event in dict.fromkeys(e for e, _ in WANTED):
        existing = hooks.get(event)
        if not isinstance(existing, list):
            continue
        kept = [g for g in existing if not is_ours(g)]
        if len(kept) != len(existing):
            changed.append(event)
        # Leave an emptied event behind rather than reshaping a file we do not own.
        hooks[event] = kept

if not changed:
    print("nothing to change" if mode == "install" else "hooks were not installed")
    sys.exit(0)

if os.path.exists(path):
    # Timestamped: an install followed by an uninstall must not overwrite the
    # one backup that still holds the original file. The counter matters too —
    # the two runs can land in the same second, which is how this went wrong
    # the first time.
    stamp = time.strftime("%Y%m%d-%H%M%S")
    backup = f"{path}.headsup-{stamp}.bak"
    nth = 2
    while os.path.exists(backup):
        backup = f"{path}.headsup-{stamp}-{nth}.bak"
        nth += 1
    shutil.copy2(path, backup)
    print(f"backed up {path} -> {backup}")
os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
tmp = path + ".headsup.tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")
os.replace(tmp, path)

# "updated", not "added to": an install can now also retime an existing entry.
verb = "updated" if mode == "install" else "removed from"
print(f"{verb} {len(changed)} event(s): {', '.join(changed)}")
print("Open sessions keep their old hooks; new sessions pick this up.")
PY
