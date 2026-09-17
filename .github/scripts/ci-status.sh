#!/bin/bash
# Report CI status for a commit. Usage: ci-status.sh [sha]
#
# Exists because the obvious version of this check is wrong: reading the
# annotations API alone returns an empty list for a run that has not finished,
# which is indistinguishable from a run that passed. Status first, always.
#
# Exit 0 green, 1 failed, 2 still running or no run yet.
set -u

SHA="${1:-$(git rev-parse HEAD)}"
REPO="${GITHUB_REPOSITORY:-simongev/Tally-Oh}"
API="https://api.github.com/repos/$REPO"
AUTH=(-H "Authorization: Bearer ${GH_TOKEN:-}" -H "Accept: application/vnd.github+json")

read -r STATUS CONCLUSION ID <<<"$(curl -sS "${AUTH[@]}" "$API/commits/$SHA/check-runs" | python3 -c '
import json, sys
runs = json.load(sys.stdin).get("check_runs", [])
if not runs:
    print("none none none")
else:
    r = runs[0]
    print(r["status"], r.get("conclusion") or "none", r["id"])
')"

if [ "$STATUS" = "none" ]; then
  echo "NO RUN yet for ${SHA:0:7} — CI may not have been triggered."
  exit 2
fi

if [ "$STATUS" != "completed" ]; then
  echo "STILL RUNNING (${STATUS}) for ${SHA:0:7} — no verdict yet. Do not read this as green."
  exit 2
fi

if [ "$CONCLUSION" = "success" ]; then
  echo "GREEN — ${SHA:0:7}"
  exit 0
fi

echo "FAILED (${CONCLUSION}) — ${SHA:0:7}"
curl -sS "${AUTH[@]}" "$API/check-runs/$ID/annotations" | python3 -c '
import json, sys
for a in json.load(sys.stdin):
    if a["annotation_level"] == "failure":
        print("  -", a["message"][:300])
'
exit 1
