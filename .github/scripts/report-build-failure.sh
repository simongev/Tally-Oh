#!/bin/bash
# Surface xcodebuild failures as GitHub annotations and a job summary.
#
# Agent sessions cannot download raw Actions logs -- those redirect to blob
# storage, which egress policy blocks -- but the check-run annotations API is
# served from api.github.com and is readable. So CI has to say what broke
# through a channel an agent can actually reach, or every failure looks like
# "exit code 65" to whoever has to fix it.
#
# Written for bash 3.2, which is what macOS runners provide: no mapfile, no
# associative arrays. And it always exits 0 -- a reporter that fails takes the
# real error down with it.
set -u

LOG="${1:-}"
MAX_LINES=20
OUT="${RUNNER_TEMP:-/tmp}/build-errors.txt"

if [ -z "$LOG" ] || [ ! -s "$LOG" ]; then
  echo "::error::Build failed and no xcodebuild log was captured at '${LOG:-<unset>}'"
  exit 0
fi

# Compiler errors, linker errors, test failures, and xcodebuild's own refusals.
PATTERN='(^|[[:space:]])error:|\*\* (BUILD|TEST|TESTING) FAILED \*\*|^Testing failed:|Test Case .* failed|recorded an issue|xcodebuild: error:|The following build commands failed|Unable to find a device|Could not find a scheme|does not contain a scheme|Provisioning profile|code signing'

grep -aE "$PATTERN" "$LOG" 2>/dev/null \
  | sed 's/^[[:space:]]*//' \
  | awk '!seen[$0]++' \
  | head -n "$MAX_LINES" > "$OUT" 2>/dev/null

# Nothing matched: annotate the tail rather than going quiet. A filter that
# only reports what it already expected is how a crash looks like success.
if [ ! -s "$OUT" ]; then
  echo "(no recognized error lines; showing the tail of xcodebuild output)" > "$OUT"
  tail -n 30 "$LOG" >> "$OUT" 2>/dev/null
fi

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "## Build failed"
    echo
    echo '```'
    cat "$OUT"
    echo '```'
  } >> "$GITHUB_STEP_SUMMARY"
fi

while IFS= read -r line; do
  case "$line" in ''|' ') continue;; esac
  printf '::error::%s\n' "$(printf '%s' "$line" | tr -d '\r')"
done < "$OUT"

exit 0
