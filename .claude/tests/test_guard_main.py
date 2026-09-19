#!/usr/bin/env python3
"""Adversarial test suite for .claude/hooks/guard-main.py.

Run it:  python3 .claude/tests/test_guard_main.py
Exit 0 every case behaves as specified, 1 otherwise. No dependencies.

**Re-run this after ANY change to the guard's matching logic.** The guard is a
string matcher over shell commands, so every edit to how it resolves a command
is a chance to reopen a hole that used to be closed. The cost of running it is
two seconds.

WHY THIS SUITE EXISTS, AND WHAT SHAPE IT HAS TO HAVE
----------------------------------------------------
The guard shipped with a 19-case suite written by the same author, immediately
after the guard itself. Every case passed and the suite proved nothing: it
enumerated the shapes the author had already thought of, which are exactly the
shapes the code handles. Eleven bypasses survived it.

So the rule for this file: **a case earns its place by trying to get past the
guard, not by confirming it works.** When you add a protected operation here,
add the obfuscated spellings of it in the same commit -- an env prefix, an
absolute path, a global option before the subcommand, a wrapper process.

The allow-cases matter just as much. A guard that denies everything is not
secure, it is uninstalled five minutes later. Pushing a feature branch, reading
logs, fetching, and grepping a protected file by name all have to stay allowed.

STATUS
------
As of the commit that added this file, the cases marked EXPECTED-FAIL below do
fail: they are the specification for a fix that has not been applied, not a
description of current behaviour. Confirmed by execution, not by reading.

WHAT THIS GUARD IS AND IS NOT
-----------------------------
It is a speed bump, not a wall. The session's git credential resolves to Gev's
own account with admin rights, so no arrangement of string matching in a
PreToolUse hook can stop a determined bypass -- `python3 -c` alone ends the
argument. What it stops is accident, drift, and a confused agent doing the
wrong thing confidently. Judge it by that standard and do not write a docstring
that claims more.
"""
import json
import subprocess
import sys
import tempfile
from pathlib import Path

HOOK = Path(__file__).resolve().parents[1] / "hooks" / "guard-main.py"
PROTECTED_HOOK = ".claude/hooks/guard-main.py"
PROTECTED_SETTINGS = ".claude/settings.json"

DENY, ALLOW, ASK = "deny", "allow", "ask"


def _fixture_repos(root: Path):
    """One repo checked out on main, one on a feature branch."""
    made = {}
    for name, branch in (("on_main", "main"), ("on_feature", "feature/x")):
        path = root / name
        path.mkdir(parents=True)
        run = lambda *a: subprocess.run(["git", "-C", str(path), *a],
                                        capture_output=True, text=True, check=True)
        run("init", "-q", "-b", "main")
        run("config", "user.email", "t@example.com")
        run("config", "user.name", "t")
        run("commit", "-q", "--allow-empty", "-m", "init")
        if branch != "main":
            run("checkout", "-q", "-b", branch)
        made[name] = str(path)
    return made


def decision(tool_name: str, tool_input: dict, cwd: str) -> str:
    """Whatever the hook decides for this call: 'allow', 'deny' or 'ask'."""
    payload = {"tool_name": tool_name, "tool_input": tool_input, "cwd": cwd}
    proc = subprocess.run([sys.executable, str(HOOK)], input=json.dumps(payload),
                          capture_output=True, text=True, timeout=20)
    if not proc.stdout.strip():
        return ALLOW                      # silence is fall-through, i.e. allow
    try:
        return json.loads(proc.stdout)["hookSpecificOutput"]["permissionDecision"]
    except Exception:
        return ALLOW


def cases(repos):
    """(label, tool, tool_input, cwd, expected) tuples."""
    main, feat = repos["on_main"], repos["on_feature"]

    def bash(cmd, cwd=feat):
        return ("Bash", {"command": cmd}, cwd)

    out = []

    # ---- Rule 1: pushing main, spelled every way that still reaches git -----
    # The plain form the original guard catches, kept as the control.
    out.append(("push main, plain", *bash("git push origin main"), DENY))
    # Global options that shift the subcommand away from tokens[1].
    for opt in ("-C .", "-c k=v", "--no-pager", "--git-dir=.git",
                "--work-tree=.", "--exec-path=/usr/bin"):
        out.append((f"push main via global option {opt}",
                    *bash(f"git {opt} push origin main"), DENY))
    # Things that displace the bare literal 'git' from tokens[0].
    out.append(("push main behind env assignment", *bash("FOO=1 git push origin main"), DENY))
    out.append(("push main behind two assignments",
                *bash("A=1 B=2 git push origin main"), DENY))
    out.append(("push main via env(1)", *bash("env git push origin main"), DENY))
    out.append(("push main via absolute path", *bash("/usr/bin/git push origin main"), DENY))
    out.append(("push main via relative path", *bash("./git push origin main"), DENY))
    # Wrappers and substitution: the guard must not try to parse these, it must
    # refuse to guess. 'ask' is an acceptable answer for all of them.
    for label, cmd in (
        ("bash -c wrapper",      "bash -c 'git push origin main'"),
        ("sh -c wrapper",        "sh -c \"git push origin main\""),
        ("xargs",                "echo main | xargs git push origin"),
        ("command substitution", "$(git push origin main)"),
        ("backticks",            "`git push origin main`"),
        ("ssh remote",           "ssh host 'git push origin main'"),
    ):
        out.append((f"push main via {label}", *bash(cmd), (DENY, ASK)))

    # Refspec spellings of the same thing.
    out.append(("push HEAD:main", *bash("git push origin HEAD:main"), DENY))
    out.append(("push refs/heads/main", *bash("git push origin refs/heads/main"), DENY))
    out.append(("push main while on main, no refspec",
                *bash("git push", main), DENY))

    # ---- Rule 1: committing/merging on main -------------------------------
    out.append(("commit on main, plain", *bash("git commit -m x", main), DENY))
    out.append(("commit on main behind -C", *bash("git -C . commit -m x", main), DENY))
    out.append(("merge on main", *bash("git merge feature/x", main), DENY))
    out.append(("cherry-pick on main", *bash("git cherry-pick abc123", main), DENY))

    # ---- Rule 2: force, deletion, history rewriting ------------------------
    out.append(("force push", *bash("git push --force origin feature/x"), DENY))
    out.append(("force-with-lease", *bash("git push --force-with-lease origin feature/x"), DENY))
    out.append(("plus refspec", *bash("git push origin +feature/x"), DENY))
    out.append(("remote delete via colon", *bash("git push origin :feature/x"), DENY))
    out.append(("remote delete via --delete", *bash("git push --delete origin feature/x"), DENY))
    out.append(("force push behind -c", *bash("git -c k=v push --force origin feature/x"), DENY))
    out.append(("filter-branch", *bash("git filter-branch --all"), DENY))
    out.append(("filter-repo", *bash("git filter-repo --path x"), DENY))
    out.append(("rebase on main", *bash("git rebase -i HEAD~3", main), DENY))
    out.append(("reset --hard on main", *bash("git reset --hard HEAD~3", main), DENY))
    out.append(("update-ref on main", *bash("git update-ref refs/heads/main deadbeef"), DENY))
    # CLAUDE.md rule 2 is explicit that this covers every branch, not just main.
    out.append(("local branch delete -D", *bash("git branch -D someone-elses"), DENY))
    out.append(("local branch delete -d", *bash("git branch -d someone-elses"), DENY))

    # ---- Self-protection: must deny actual writes -------------------------
    for label, cmd in (
        ("truncate via cp",    f"cp /dev/null {PROTECTED_HOOK}"),
        ("redirect over hook", f"echo x > {PROTECTED_HOOK}"),
        ("python write",
         'python3 -c "open(\'' + PROTECTED_SETTINGS + '\',\'w\').write(chr(48))"'),
        ("sed in place",       f"sed -i s/a/b/ {PROTECTED_HOOK}"),
        ("tee over settings",  f"echo x | tee {PROTECTED_SETTINGS}"),
        ("remove the hook",    f"rm -f {PROTECTED_HOOK}"),
        ("move the hook",      f"mv {PROTECTED_HOOK} /tmp/x"),
    ):
        out.append((f"self-protect: {label}", *bash(cmd), (DENY, ASK)))

    # ---- Self-protection: must NOT block reads or mere mentions ------------
    # This half is why the guard cannot simply deny on co-occurrence. QA was
    # blocked from writing a test fixture that named the path in a string.
    for label, cmd in (
        ("grep containing the word rm", f"grep -n 'rm' {PROTECTED_HOOK}"),
        ("grep containing the word mv", f"grep -rn 'mv' {PROTECTED_HOOK}"),
        ("cat the hook",                f"cat {PROTECTED_HOOK}"),
        ("git diff the hook",           f"git diff {PROTECTED_HOOK}"),
        ("git log the hook",            f"git log --oneline -- {PROTECTED_HOOK}"),
        ("fixture naming the path",
         f"echo 'fixture mentions {PROTECTED_HOOK} and rm' > /tmp/fixture.txt"),
        ("write elsewhere, path in content",
         f"echo '{PROTECTED_SETTINGS}' > /tmp/notes.txt"),
    ):
        out.append((f"self-protect must allow: {label}", *bash(cmd), ALLOW))

    # ---- Ordinary work must stay allowed -----------------------------------
    for label, cmd in (
        ("push feature branch",     "git push -u origin feature/x"),
        ("push another feature",    "git push origin fix/drift-gate-and-deadband"),
        ("log",                     "git log --oneline -5"),
        ("fetch main",              "git fetch origin main"),
        ("status",                  "git status"),
        ("diff",                    "git diff --stat"),
        ("checkout a branch",       "git checkout -b feature/new"),
        ("commit on a feature",     "git commit -m 'real work'"),
        ("rebase on a feature",     "git rebase origin/chore/base"),
        ("show main without push",  "git show origin/main --stat"),
        ("branch listing",          "git branch -a"),
        ("non-git command",         "ls -la"),
        ("compound, all benign",    "git add -A && git commit -m x && git status"),
    ):
        out.append((f"allow: {label}", *bash(cmd), ALLOW))

    # A compound where one segment is forbidden must still be caught.
    out.append(("compound hiding a main push",
                *bash("git status && git push origin main"), DENY))
    out.append(("compound hiding a disguised main push",
                *bash("git status && git -C . push origin main"), DENY))

    # ---- Edit/Write path protection (already correct; keep it that way) ----
    out.append(("Edit the hook", "Edit",
                {"file_path": "/repo/.claude/hooks/guard-main.py"}, feat, DENY))
    out.append(("Write settings", "Write",
                {"file_path": "/repo/.claude/settings.json"}, feat, DENY))
    out.append(("Edit app source", "Edit",
                {"file_path": "/repo/Tally-Ho/Sources/X.swift"}, feat, ALLOW))
    out.append(("Write this suite", "Write",
                {"file_path": "/repo/.claude/tests/test_guard_main.py"}, feat, ALLOW))

    # ---- MCP surface --------------------------------------------------------
    out.append(("merge PR via MCP", "mcp__github__merge_pull_request", {}, feat, DENY))
    out.append(("write file to main via MCP", "mcp__github__create_or_update_file",
                {"branch": "main"}, feat, DENY))
    out.append(("write file to feature via MCP", "mcp__github__create_or_update_file",
                {"branch": "feature/x"}, feat, ALLOW))
    out.append(("deploy workflow asks", "mcp__github__actions_run_trigger",
                {"workflow_id": "deploy.yml"}, feat, ASK))
    out.append(("appstore workflow asks", "mcp__github__actions_run_trigger",
                {"workflow_id": "appstore-upload.yml"}, feat, ASK))
    out.append(("ordinary workflow runs", "mcp__github__actions_run_trigger",
                {"workflow_id": "ci.yml"}, feat, ALLOW))

    return out


def main() -> int:
    if not HOOK.exists():
        print(f"hook not found at {HOOK}")
        return 1

    with tempfile.TemporaryDirectory() as tmp:
        repos = _fixture_repos(Path(tmp))
        failures = []
        passes = 0
        for label, tool, tool_input, cwd, expected in cases(repos):
            want = expected if isinstance(expected, tuple) else (expected,)
            got = decision(tool, tool_input, cwd)
            if got in want:
                passes += 1
            else:
                failures.append((label, "/".join(want), got,
                                 tool_input.get("command", str(tool_input))))

        print(f"{passes} passed, {len(failures)} failed, {passes + len(failures)} total\n")
        if failures:
            width = max(len(f[0]) for f in failures)
            print("FAILURES (want -> got):")
            for label, want, got, cmd in failures:
                print(f"  {label.ljust(width)}  want={want:9} got={got:5}  {cmd}")
            print("\nEach line above is an operation the guard does not handle as specified.")
            return 1
        print("All cases behave as specified.")
        return 0


if __name__ == "__main__":
    sys.exit(main())
