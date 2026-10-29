#!/usr/bin/env python3
"""Tests for scripts/install-hooks.sh — the one script that writes a file the
user did not give us.

    python3 Tests/install-hooks.test.py

It runs against a *copy* of the real ~/.claude/settings.json when there is one,
because that file is where the risk actually lives: it holds dozens of hook
groups and a statusLine that belong to other tools. The invariant under test is
narrow and absolute — every group that is not ours, every other key, and the
statusLine come out byte-for-byte unchanged.

CLAUDE_SETTINGS points the script at the copy, so the real file is never
touched. A missing real file is not a failure; a small fixture is used instead.
"""

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(REPO, "scripts", "install-hooks.sh")
STATE_COMMAND = f"bash {os.path.join(REPO, 'hooks', 'headsup-state.sh')}"
ASK_COMMAND = f"bash {os.path.join(REPO, 'hooks', 'headsup-ask.sh')}"
OURS = {STATE_COMMAND, ASK_COMMAND}

passed = 0
failed = 0


def check(name, expected, actual):
    global passed, failed
    if expected == actual:
        passed += 1
        print(f"  ok    {name}")
    else:
        failed += 1
        print(f"  FAIL  {name}\n     expected: {expected!r}\n     actual:   {actual!r}")


def ok(name):
    global passed
    passed += 1
    print(f"  ok    {name}")


def bad(name, why):
    global failed
    failed += 1
    print(f"  FAIL  {name}\n     {why}")


def run(settings_path, *args):
    return subprocess.run(
        ["bash", SCRIPT, *args],
        env={**os.environ, "CLAUDE_SETTINGS": settings_path},
        capture_output=True,
        text=True,
    )


def load(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def is_ours(group):
    entries = group.get("hooks") if isinstance(group, dict) else None
    if not isinstance(entries, list):
        return False
    return any(isinstance(e, dict) and e.get("command") in OURS for e in entries)


def foreign(settings):
    """Every hook group that is not ours, per event — what must never change."""
    hooks = settings.get("hooks", {})
    return {
        event: [g for g in groups if not is_ours(g)]
        for event, groups in hooks.items()
        if isinstance(groups, list)
    }


def without_hooks(settings):
    return {k: v for k, v in settings.items() if k != "hooks"}


FIXTURE = {
    "statusLine": {"type": "command", "command": "sh ~/.claude/statusline-command.sh"},
    "permissions": {"allow": ["Bash(git status *)"], "defaultMode": "auto"},
    "hooks": {
        "PreToolUse": [
            {"matcher": "*", "hooks": [{"type": "command", "command": "python3 ~/.claude/hooks/guard.py"}]}
        ],
        "PermissionRequest": [
            {"hooks": [{"type": "command", "command": "afplay ~/.claude/sounds/coin.mp3", "timeout": 3}]}
        ],
    },
}


def strip_ours(settings):
    """Remove this repo's own hook groups, so a run always starts from 'not
    installed'. Without this the test depends on whether the developer happens
    to have the hooks installed already, and an install that finds nothing to do
    writes no backup."""
    hooks = settings.get("hooks")
    if not isinstance(hooks, dict):
        return settings
    for event, groups in list(hooks.items()):
        if isinstance(groups, list):
            hooks[event] = [g for g in groups if not is_ours(g)]
    return settings


def source_settings(tmp):
    """A copy of the real settings file, or the fixture if there is none.

    The real file is where the risk lives — dozens of hook groups and a
    statusLine belonging to other tools — so it is the better fixture, with
    our own entries taken back out.
    """
    real = os.path.expanduser("~/.claude/settings.json")
    target = os.path.join(tmp, "settings.json")
    if os.path.exists(real):
        try:
            with open(real, encoding="utf-8") as f:
                settings = json.load(f)
        except (OSError, ValueError):
            pass
        else:
            with open(target, "w", encoding="utf-8") as f:
                json.dump(strip_ours(settings), f, indent=2)
                f.write("\n")
            return target, "a copy of the real ~/.claude/settings.json, with our own hooks stripped"
    with open(target, "w", encoding="utf-8") as f:
        json.dump(FIXTURE, f, indent=2)
    return target, "a fixture (no readable real settings file)"


def main():
    tmp = tempfile.mkdtemp(prefix="headsup-install-test-")
    path, provenance = source_settings(tmp)
    print(f"against {provenance}")
    print(f"  {path}\n")

    original = load(path)
    original_foreign = foreign(original)
    original_other = without_hooks(original)
    original_events = set(original.get("hooks", {}))

    print("install")
    result = run(path, )
    if result.returncode != 0:
        bad("install exits 0", f"exit {result.returncode}: {result.stderr.strip()}")
        return finish()
    ok("install exits 0")

    after = load(path)

    # The whole point of the script.
    check("every foreign hook group survives", original_foreign, foreign(after))
    check("every other top-level key survives", original_other, without_hooks(after))
    check(
        "statusLine is untouched",
        original.get("statusLine"),
        after.get("statusLine"),
    )
    if original_events - set(after.get("hooks", {})):
        bad("no event disappears", f"lost: {sorted(original_events - set(after.get('hooks', {})))}")
    else:
        ok("no event disappears")

    # And the hooks it was asked to add.
    entries = [
        e
        for group in after["hooks"].get("PermissionRequest", [])
        for e in group.get("hooks", [])
        if e.get("command") == ASK_COMMAND
    ]
    check("the ask hook is registered once", 1, len(entries))
    if entries:
        # The invariant, not the number: Claude Code must not kill the hook
        # mid-wait, or the click is lost. The hook's own default is read from
        # the hook, so raising one side without the other cannot pass quietly.
        with open(os.path.join(REPO, "hooks", "headsup-ask.sh"), encoding="utf-8") as f:
            found = re.search(r"HEADSUP_ASK_TIMEOUT:-(\d+)", f.read())
        hook_wait = int(found.group(1)) if found else None
        registered = entries[0].get("timeout")
        if hook_wait is None:
            bad("the ask hook's timeout clears its own wait", "no HEADSUP_ASK_TIMEOUT default found")
        else:
            check(
                f"the ask hook's {registered}s timeout clears its own {hook_wait}s wait",
                True,
                isinstance(registered, int) and registered > hook_wait,
            )

    state_events = {
        event
        for event, groups in after["hooks"].items()
        for group in groups
        for e in group.get("hooks", [])
        if e.get("command") == STATE_COMMAND
    }
    check(
        "the status hook covers all eight events",
        {"UserPromptSubmit", "PreToolUse", "PostToolUse", "Notification",
         "PermissionRequest", "Stop", "StopFailure", "SessionEnd"},
        state_events,
    )

    backups = [n for n in os.listdir(tmp) if ".bak" in n]
    check("a timestamped backup was written", 1, len(backups))

    print("\nrunning it twice changes nothing")
    before_second = load(path)
    result = run(path)
    last = result.stdout.strip().splitlines()[-1] if result.stdout.strip() else ""
    check("second install is a no-op", "nothing to change", last)
    check("file unchanged by the second run", before_second, load(path))
    check("no second backup", 1, len([n for n in os.listdir(tmp) if ".bak" in n]))

    print("\nan install retimes an entry left behind by an older version")
    # Simulate upgrading from a version whose ask hook waited less: the
    # command is identical, so only the timeout marks it as stale.
    stale = load(path)
    for group in stale["hooks"]["PermissionRequest"]:
        for e in group.get("hooks", []):
            if e.get("command") == ASK_COMMAND:
                e["timeout"] = 70
    with open(path, "w", encoding="utf-8") as f:
        json.dump(stale, f, indent=2)
    result = run(path)
    retimed = [
        e
        for group in load(path)["hooks"]["PermissionRequest"]
        for e in group.get("hooks", [])
        if e.get("command") == ASK_COMMAND
    ]
    check("the stale timeout was brought up to date", registered, retimed[0].get("timeout") if retimed else None)
    check("the ask hook is still registered once", 1, len(retimed))
    check("retiming reported a change", True, "nothing to change" not in result.stdout)
    check("foreign groups survive the retime", original_foreign, foreign(load(path)))

    print("\nuninstall")
    result = run(path, "--uninstall")
    if result.returncode != 0:
        bad("uninstall exits 0", f"exit {result.returncode}: {result.stderr.strip()}")
        return finish()
    ok("uninstall exits 0")

    cleaned = load(path)
    check("foreign groups still survive", original_foreign, foreign(cleaned))
    check("other keys still survive", original_other, without_hooks(cleaned))
    check("statusLine still untouched", original.get("statusLine"), cleaned.get("statusLine"))

    leftovers = [
        e.get("command")
        for groups in cleaned.get("hooks", {}).values()
        if isinstance(groups, list)
        for group in groups
        for e in group.get("hooks", [])
        if e.get("command") in OURS
    ]
    check("nothing of ours is left", [], leftovers)
    # One per run that actually wrote: the install, the retime, the uninstall.
    # The no-op second install wrote nothing and so backed nothing up.
    check("three backups now exist", 3, len([n for n in os.listdir(tmp) if ".bak" in n]))

    print("\nrefusing to write what it cannot read")
    broken = os.path.join(tmp, "broken.json")
    with open(broken, "w", encoding="utf-8") as f:
        f.write("{ this is not json\n")
    result = run(broken, )
    if result.returncode == 0:
        bad("a malformed settings file is refused", "it exited 0")
    else:
        ok("a malformed settings file is refused")
    with open(broken, encoding="utf-8") as f:
        check("the malformed file is left alone", "{ this is not json\n", f.read())

    return finish(tmp)


def finish(tmp=None):
    print(f"\n{passed} passed, {failed} failed")
    if tmp:
        print(f"scratch files left at {tmp}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
