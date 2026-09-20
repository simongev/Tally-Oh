#!/usr/bin/env python3
"""PreToolUse guard for Tally Oh's non-negotiable rules.

The harness runs this before the tool call, so an agent cannot decide on its own
that a rule does not apply this once. It enforces the rules worth enforcing
mechanically:

  Rule 1 -- only Gev merges to main. Nothing here pushes to main, commits on
           main, or merges into main.
  Rule 2 -- never force-push, never rewrite published history, never delete a
           branch you did not create (every branch, not only main).

and protects its own configuration from being edited away.

Rule 6 (App Store) is deliberately NOT a deny: Gev wants agents able to upload
on his command. Dispatching the deploy workflow asks for confirmation instead,
so the approval is visible rather than silent.

WHAT THIS IS, AND WHAT IT IS NOT
--------------------------------
**A speed bump, not a wall.** The session's git credential resolves to Gev's own
account with admin rights, so nothing that matches strings in a PreToolUse hook
can stop a determined bypass -- `python3 -c` alone ends that argument, and this
file cannot and does not try to win it. What it stops is accident, drift, and a
confused agent doing the wrong thing confidently. Judge it by that standard.
Earlier versions of this docstring claimed the model "cannot talk its way past
it", which was false in a way that mattered: eleven bypasses existed and none of
them needed talking.

HOW COMMANDS ARE MATCHED
------------------------
Two rules, learned from those eleven:

1. **Resolve before matching.** A command is not "git" because its first token
   is the literal `git`. Leading `VAR=value` assignments and `env` are stripped,
   the program is compared by `os.path.basename`, and git's global options
   (`-C`, `-c`, `--git-dir`, `--work-tree`, `--no-pager`, `--exec-path`, ...)
   are skipped to find the real subcommand. Every one of those shifted the
   subcommand away from `tokens[1]` and carried a push to main straight through.

2. **Fail closed on shapes we do not understand.** A segment that mentions git
   and a protected verb but does not resolve into a form this file recognises
   returns `ask` rather than `allow`. That single rule covers `bash -c`, `sh -c`,
   `ssh`, `xargs`, `$( )` and backticks **without parsing shell**, which is not
   something to attempt here: a partial shell parser is a false sense of
   security with extra steps.

Self-protection is decided on the **file path**, the way the Edit/Write branch
always did, not on trigger words appearing near a path. The old version denied
any segment where `rm`/`mv`/`sed -i`/`tee` co-occurred with a protected path
anywhere, which blocked `grep -n 'rm' <path>` and blocked QA from writing a test
fixture that merely named the file in a quoted string -- while still missing an
actual write through `cp /dev/null` or a `python3 -c` one-liner.

TESTS
-----
`.claude/tests/test_guard_main.py` is an adversarial suite: 77 cases, every
reported bypass plus the obfuscated spellings of each, and twenty allow-cases.
**Re-run it after any change to the matching logic** -- this is string matching
over shell commands, so every edit is a chance to reopen a hole:

    python3 .claude/tests/test_guard_main.py

The allow-cases carry as much weight as the denies. A guard that refuses `grep`
or `git log` is one somebody uninstalls, and an uninstalled guard protects
nothing.

Decisions are emitted as PreToolUse JSON. Anything not matched falls through
untouched, and any internal error falls through too -- a broken guard must not
brick the session.
"""
import json
import os
import re
import shlex
import subprocess
import sys

PROTECTED_BRANCH = "main"
SELF_PROTECTED = (".claude/settings.json", ".claude/hooks/")

# git global options that consume a following argument.
GIT_OPTS_WITH_VALUE = {
    "-C", "-c", "--git-dir", "--work-tree", "--exec-path", "--namespace",
    "--super-prefix", "--config-env",
}
# git global options that stand alone.
GIT_FLAGS = {
    "--no-pager", "--paginate", "-p", "--bare", "--no-replace-objects",
    "--literal-pathspecs", "--glob-pathspecs", "--noglob-pathspecs",
    "--icase-pathspecs", "--no-optional-locks", "--html-path", "--man-path",
    "--info-path", "--version", "--help",
}

# Subcommands that are never acceptable, wherever HEAD happens to be.
ALWAYS_DENIED = {
    "filter-branch": "Rule 2: never rewrite published history.",
    "filter-repo": "Rule 2: never rewrite published history. filter-repo rewrites every commit.",
    "update-ref": ("Rule 2: never rewrite published history. Moving a ref directly bypasses "
                   "every check git would otherwise make."),
}
# Subcommands that are fine on a feature branch and forbidden on main.
DENIED_ON_PROTECTED = {
    "merge", "commit", "cherry-pick", "revert", "am", "rebase", "reset",
}
# Verbs that make an unparseable segment worth asking about.
RISKY_VERBS = ("push", "reset", "rebase", "update-ref", "filter-repo", "filter-branch")

# Programs that write to the files they are given.
WRITE_COMMANDS = {
    "rm", "mv", "cp", "dd", "truncate", "tee", "install", "ln", "shred",
    "chmod", "chown", "touch", "patch",
}
# Interpreters that write via a one-liner rather than via an argument.
INTERPRETERS = {"python", "python3", "perl", "ruby", "node", "php"}


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


def resolve_git(tokens):
    """(subcommand, args) if these tokens are a git invocation we understand.

    None means either 'not git at all' or 'git, but in a shape this file does not
    recognise'. The caller must treat None as unknown rather than as safe -- see
    the fail-closed rule in the module docstring.
    """
    i = 0
    # Leading environment assignments: FOO=1 BAR=2 git ...
    while i < len(tokens) and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", tokens[i]):
        i += 1
    # env(1), possibly repeated, possibly with its own assignments after it.
    while i < len(tokens) and os.path.basename(tokens[i]) == "env":
        i += 1
        while i < len(tokens) and (
            re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", tokens[i]) or tokens[i] in ("-i", "--ignore-environment")
        ):
            i += 1
    if i >= len(tokens):
        return None
    # Compared by basename, so /usr/bin/git and ./git resolve like git.
    if os.path.basename(tokens[i]) != "git":
        return None

    i += 1
    while i < len(tokens):
        token = tokens[i]
        if not token.startswith("-"):
            return token, tokens[i + 1:]
        if token in GIT_OPTS_WITH_VALUE:
            i += 2
            continue
        if any(token.startswith(opt + "=") for opt in GIT_OPTS_WITH_VALUE):
            i += 1
            continue
        if token in GIT_FLAGS:
            i += 1
            continue
        # An option we do not know. Refuse to guess where the subcommand is.
        return None
    return None


def check_git_push(args, branch: str):
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
        destination = refspec.split(":")[-1].rsplit("/", 1)[-1]
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


def check_branch_delete(args):
    for token in args:
        if token in ("-D", "-d", "--delete") or (
            re.match(r"^-[a-zA-Z]+$", token) and "D" in token
        ):
            decide("deny", (
                "Rule 2: never delete a branch you did not create -- every branch, not just "
                "main. If it is genuinely yours and genuinely finished, say so and ask Gev."
            ))


def check_self_protection(segment: str, tokens):
    """Deny writes to the guard's own files, decided on the path, not on keywords.

    Reads are not writes: `grep`, `cat`, `git diff` and `git log` naming a
    protected file all pass, as does writing a file elsewhere whose *contents*
    mention one. Precision matters here in both directions -- over-blocking made
    it impossible to write a test fixture naming the path.

    This cannot be airtight for Bash. An interpreter can construct a path from
    pieces, and no string matcher will see it. Covered: the direct spellings.
    """
    # Redirection onto a protected path: check the target, not the whole segment.
    for target in re.findall(r">>?\s*['\"]?([^\s;|&'\"]+)", segment):
        if any(protected in target for protected in SELF_PROTECTED):
            decide("deny", (
                "This file enforces Gev's non-negotiable rules and is not editable from a "
                "session. Ask Gev directly if it genuinely needs to change."
            ))

    if not tokens:
        return
    program = os.path.basename(tokens[0])
    args = tokens[1:]

    touches_protected = any(
        protected in arg for arg in args for protected in SELF_PROTECTED
    )
    if not touches_protected:
        return

    if program in WRITE_COMMANDS:
        decide("deny", (
            f"{program} would modify a file that enforces Gev's non-negotiable rules. "
            "Ask Gev directly if it genuinely needs to change."
        ))
    if program == "sed" and any(a == "-i" or a.startswith("-i") for a in args):
        decide("deny", (
            "sed -i would rewrite a file that enforces Gev's non-negotiable rules. "
            "Ask Gev directly if it genuinely needs to change."
        ))
    if program in INTERPRETERS and any(a in ("-c", "-e") for a in args):
        decide("deny", (
            "This would write to a file that enforces Gev's non-negotiable rules from an "
            "interpreter one-liner. Ask Gev directly if it genuinely needs to change."
        ))


def check_bash(command: str, cwd: str):
    branch = current_branch(cwd)

    for segment in split_segments(command):
        try:
            tokens = shlex.split(segment)
        except ValueError:
            # Unbalanced quotes: we cannot see what this does.
            if re.search(r"\bgit\b", segment) and any(v in segment for v in RISKY_VERBS):
                decide("ask", (
                    "This command mentions git and a protected operation but could not be "
                    "parsed, so the guard cannot tell what it does. Confirm it does not push "
                    "to main, force-push, or rewrite history."
                ))
            continue
        if not tokens:
            continue

        check_self_protection(segment, tokens)

        resolved = resolve_git(tokens)
        if resolved is None:
            # Not a git command we recognise. If it looks like it carries one
            # anyway -- a wrapper, a substitution, an unknown global option --
            # ask rather than wave it through.
            if re.search(r"\bgit\b", segment) and any(
                re.search(r"\b" + re.escape(v) + r"\b", segment) for v in RISKY_VERBS
            ):
                decide("ask", (
                    "This looks like it runs git through a wrapper or substitution, which the "
                    "guard cannot read. If it pushes to main, force-pushes, or rewrites "
                    "history, it is not allowed -- rule 1 and rule 2. Run git directly so the "
                    "guard can check it."
                ))
            continue

        subcommand, args = resolved

        if subcommand == "push":
            check_git_push(args, branch)

        elif subcommand in ALWAYS_DENIED:
            decide("deny", ALWAYS_DENIED[subcommand])

        elif subcommand == "branch":
            check_branch_delete(args)

        elif subcommand in DENIED_ON_PROTECTED and branch == PROTECTED_BRANCH:
            decide("deny", (
                f"Rule 1: you are on {PROTECTED_BRANCH}. Nobody but Gev commits to, merges "
                f"into, or rewrites main. Branch first: git checkout -b feature/<name>"
            ))


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
