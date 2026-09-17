#!/usr/bin/env python3
"""PreToolUse guard for Tally Oh's non-negotiable rules.

The harness runs this before the tool call, so the model cannot talk its way
past it. It enforces the two rules that are worth enforcing mechanically:

  Rule 1 -- only Gev merges to main. Nothing here pushes to main, commits on
           main, or merges into main.
  Rule 2 -- never force-push, never rewrite published history, never delete a
           branch remotely.

and protects its own configuration from being edited away.

Rule 6 (App Store) is deliberately NOT a deny: Gev wants agents able to upload
on his command. Dispatching the deploy workflow asks for confirmation instead,
so the approval is visible rather than silent.

Decisions are emitted as PreToolUse JSON. Anything not matched falls through
untouched, and any internal error falls through too -- a broken guard must not
brick the session.
"""
import json
import re
import shlex
import subprocess
import sys

PROTECTED_BRANCH = "main"
SELF_PROTECTED = (".claude/settings.json", ".claude/hooks/")


def decide(decision: str, reason: str) -> None:
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": decision,
            "permissionDecisionReason": reason,
        }
    }))
    sys.exit(0)


def allow() -> None:
    sys.exit(0)


def current_branch(cwd: str) -> str:
    try:
        return subprocess.run(
            ["git", "rev-parse", "--abbrev-ref", "HEAD"],
            cwd=cwd or None, capture_output=True, text=True, timeout=5,
        ).stdout.strip()
    except Exception:
        return ""


def split_segments(command: str):
    """Split a compound shell command into individually checkable pieces."""
    return [seg.strip() for seg in re.split(r"&&|\|\||[;|\n]", command) if seg.strip()]


def check_git_push(tokens, branch: str):
    args = tokens[2:]

    for token in args:
        if token in ("--force", "-f") or token.startswith("--force-with-lease"):
            decide("deny", (
                "Rule 2: never force-push. This would rewrite published history. "
                "If the remote has diverged, merge it in instead."
            ))
        if token in ("--delete", "-d"):
            decide("deny", "Rule 2: never delete a branch remotely.")
        if token.startswith("+"):
            decide("deny", "Rule 2: a leading '+' refspec is a force-push. Not allowed.")

    positional = [t for t in args if not t.startswith("-")]
    refspecs = positional[1:] if len(positional) > 1 else []

    for refspec in refspecs:
        if refspec.startswith(":"):
            decide("deny", "Rule 2: never delete a branch remotely.")
        destination = refspec.split(":")[-1]
        destination = destination.rsplit("/", 1)[-1]
        if destination == PROTECTED_BRANCH:
            decide("deny", (
                f"Rule 1: only Gev pushes to {PROTECTED_BRANCH}. Push your feature branch and "
                "hand him the branch plus a verdict; he merges after flying the build."
            ))

    # `git push` with no refspec pushes the current branch to its upstream.
    if not refspecs and branch == PROTECTED_BRANCH:
        decide("deny", (
            f"Rule 1: you are on {PROTECTED_BRANCH} and this would push it. "
            "Only Gev pushes to main."
        ))


def check_bash(command: str, cwd: str):
    branch = current_branch(cwd)

    for segment in split_segments(command):
        try:
            tokens = shlex.split(segment)
        except ValueError:
            continue
        if not tokens:
            continue

        # Guard the guard: no editing the hooks or settings out of the way.
        for protected in SELF_PROTECTED:
            if protected in segment and re.search(
                r"\b(rm|mv|sed\s+-i|truncate|tee)\b|>\s*\S*" + re.escape(protected), segment
            ):
                decide("deny", (
                    f"{protected} enforces Gev's non-negotiable rules and is not editable "
                    "from a session. Ask Gev directly if it genuinely needs to change."
                ))

        if tokens[0] != "git" or len(tokens) < 2:
            continue

        subcommand = tokens[1]

        if subcommand == "push":
            check_git_push(tokens, branch)

        elif subcommand in ("merge", "commit", "cherry-pick", "revert", "am") \
                and branch == PROTECTED_BRANCH:
            decide("deny", (
                f"Rule 1: you are on {PROTECTED_BRANCH}. Nobody but Gev commits to or merges "
                "into main. Branch first: git checkout -b feature/<name>"
            ))

        elif subcommand == "filter-branch":
            decide("deny", "Rule 2: never rewrite published history.")


def check_mcp(tool_name: str, tool_input: dict):
    if tool_name.endswith("merge_pull_request"):
        decide("deny", "Rule 1: only Gev merges. Hand him the branch and a verdict instead.")

    if tool_name.endswith(("create_or_update_file", "push_files", "delete_file")):
        if tool_input.get("branch") == PROTECTED_BRANCH:
            decide("deny", f"Rule 1: only Gev writes to {PROTECTED_BRANCH}.")

    if tool_name.endswith("actions_run_trigger"):
        workflow = str(tool_input.get("workflow_id", ""))
        if "appstore" in workflow.lower() or "deploy" in workflow.lower():
            decide("ask", (
                "Rule 6: App Store uploads need Gev's explicit yes for this specific build. "
                "Confirm he asked for this build, in this conversation."
            ))


def main() -> None:
    try:
        payload = json.load(sys.stdin)
    except Exception:
        allow()

    tool_name = payload.get("tool_name", "")
    tool_input = payload.get("tool_input") or {}
    cwd = payload.get("cwd", "")

    try:
        if tool_name == "Bash":
            check_bash(tool_input.get("command", ""), cwd)
        elif tool_name in ("Edit", "Write", "NotebookEdit"):
            path = tool_input.get("file_path", "")
            if any(protected in path for protected in SELF_PROTECTED):
                decide("deny", (
                    "This file enforces Gev's non-negotiable rules and is not editable from a "
                    "session. Ask Gev directly if it genuinely needs to change."
                ))
        elif tool_name.startswith("mcp__github__"):
            check_mcp(tool_name, tool_input)
    except SystemExit:
        raise
    except Exception:
        allow()

    allow()


if __name__ == "__main__":
    main()
