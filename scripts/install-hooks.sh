#!/usr/bin/env bash
# Add (or remove) the HeadsUp hook in ~/.claude/settings.json, so the head
# follows a live Claude Code session without anyone hand-editing JSON.
#
#   ./scripts/install-hooks.sh              # add the hook
#   ./scripts/install-hooks.sh --status     # which events have it
#   ./scripts/install-hooks.sh --uninstall  # take it out again
#
# The file is only rewritten when something changed, and the previous copy is
# kept next to it with a timestamp, so a later run cannot overwrite it.
# Open Claude Code sessions keep their old hooks; new ones pick this up.
set -euo pipefail
cd "$(dirname "$0")/.."

repo=$(pwd -P)
hook="$repo/hooks/headsup-state.sh"
settings="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
mode=install

case "${1:-}" in
  "") ;;
  --status) mode=status ;;
  --uninstall) mode=uninstall ;;
  -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
esac

[ -f "$hook" ] || { echo "hook script missing: $hook" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 not found; it ships with macOS" >&2; exit 1; }

HEADSUP_HOOK="$hook" HEADSUP_SETTINGS="$settings" HEADSUP_MODE="$mode" python3 -I - <<'PY'
import json, os, shutil, sys, time

hook = os.environ["HEADSUP_HOOK"]
path = os.environ["HEADSUP_SETTINGS"]
mode = os.environ["HEADSUP_MODE"]
command = f"bash {hook}"
events = [
    "UserPromptSubmit", "PreToolUse", "PostToolUse", "Notification",
    "PermissionRequest", "Stop", "StopFailure", "SessionEnd",
]

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


def has_ours(group):
    if not isinstance(group, dict):
        return False
    entries = group.get("hooks")
    return isinstance(entries, list) and any(
        isinstance(e, dict) and e.get("command") == command for e in entries
    )


present = [e for e in events if any(has_ours(g) for g in (hooks.get(e) or []))]

if mode == "status":
    print(f"settings: {path}")
    print(f"command:  {command}")
    for event in events:
        print(f"  {'yes' if event in present else 'no ':3}  {event}")
    sys.exit(0)

changed = []
if mode == "install":
    for event in events:
        if event in present:
            continue
        groups(event).append(
            {"matcher": "*", "hooks": [{"type": "command", "command": command}]}
        )
        changed.append(event)
else:
    for event in events:
        existing = hooks.get(event)
        if not isinstance(existing, list):
            continue
        kept = [g for g in existing if not has_ours(g)]
        if len(kept) != len(existing):
            changed.append(event)
        # Leave an emptied event behind rather than reshaping a file we do not own.
        hooks[event] = kept

if not changed:
    print("nothing to change" if mode == "install" else "hook was not installed")
    sys.exit(0)

if os.path.exists(path):
    # Timestamped, and with a counter: a single fixed name meant an install
    # followed by an uninstall overwrote the one backup still holding the
    # user's original file, and the two runs can land in the same second.
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

verb = "added to" if mode == "install" else "removed from"
print(f"{verb} {len(changed)} event(s): {', '.join(changed)}")
print("Open sessions keep their old hooks; new sessions pick this up.")
PY
