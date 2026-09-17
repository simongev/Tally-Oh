#!/usr/bin/env bash
# Surface xcodebuild failures as GitHub annotations and a job summary.
#
# Agent sessions cannot download raw Actions logs -- those redirect to blob
# storage, which egress policy blocks -- but the check-run annotations API is
# served from api.github.com and is readable. So CI has to say what broke
# through a channel an agent can actually reach, or every failure looks like
# "exit code 65" to whoever has to fix it.
set -uo pipefail

LOG="${1:?usage: report-build-failure.sh <xcodebuild log>}"
MAX_ANNOTATIONS=20

if [[ ! -s "$LOG" ]]; then
  echo "::error::Build failed and no xcodebuild log was captured at $LOG"
  exit 0
fi

# Compiler errors, linker errors, test failures, and xcodebuild's own refusals.
PATTERN='(^|[[:space:]])error:|\*\* (BUILD|TEST|TESTING) FAILED \*\*|^Testing failed:|Test Case .* failed|✘ Test .* recorded an issue|xcodebuild: error:|The following build commands failed|Unable to find a device|Could not find a scheme|does not contain a scheme'

mapfile -t FOUND < <(grep -aE "$PATTERN" "$LOG" | sed 's/^[[:space:]]*//' | awk '!seen[$0]++' | head -n "$MAX_ANNOTATIONS")

{
  echo "## Build failed"
  echo
  if [[ ${#FOUND[@]} -eq 0 ]]; then
    echo 'No recognizable error lines. Last 40 lines of xcodebuild output:'
    echo '```'
    tail -n 40 "$LOG"
    echo '```'
  else
    echo '```'
    printf '%s\n' "${FOUND[@]}"
    echo '```'
  fi
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"

if [[ ${#FOUND[@]} -eq 0 ]]; then
  # No pattern matched: annotate the tail so the failure is never silent.
  tail -n 25 "$LOG" | while IFS= read -r line; do
    [[ -z "${line// }" ]] && continue
    printf '::error::%s\n' "${line//$'\r'/}"
  done
  exit 0
fi

for line in "${FOUND[@]}"; do
  printf '::error::%s\n' "${line//$'\r'/}"
done
