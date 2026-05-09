#!/usr/bin/env bash
# wait-for-checks.sh — Poll `gh pr checks <PR>` until all checks reach a terminal
# conclusion or a configurable timeout fires.
#
# Output (stdout): the final `gh pr checks --json` snapshot (one JSON line)
# Exit codes:
#   0 = all checks reached a terminal conclusion (success / failure / cancelled / skipped)
#   1 = timeout — at least one check is still pending or in_progress
#   2 = gh error / PR not found
#
# Usage:
#   bash wait-for-checks.sh --pr 42 --timeout 600
#   bash wait-for-checks.sh --pr 42 --timeout 600 --interval 15

set -uo pipefail

PR=""
TIMEOUT=600
INTERVAL=15

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pr) PR="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$PR" ]]; then
  PR=$(gh pr view --json number --jq '.number' 2>/dev/null || echo "")
fi
if [[ -z "$PR" ]]; then
  echo "wait-for-checks: cannot determine PR number" >&2
  exit 2
fi

start=$(date +%s)
last_snapshot=""

while true; do
  # Fetch checks JSON. Each check has `name`, `state`, `conclusion`, etc.
  snapshot=$(gh pr view "$PR" --json statusCheckRollup --jq \
    '[.statusCheckRollup[]? | {name: .name, status: (.status // ""), conclusion: (.conclusion // ""), detailsUrl: (.detailsUrl // "")}]' 2>/dev/null)
  gh_exit=$?

  if (( gh_exit != 0 )); then
    echo "wait-for-checks: gh pr view failed (exit=$gh_exit)" >&2
    exit 2
  fi

  last_snapshot="$snapshot"

  # Defensive: if snapshot is not a JSON array, treat as "no checks to wait for".
  if ! echo "$snapshot" | jq -e 'type == "array"' >/dev/null 2>&1; then
    echo "$snapshot"
    exit 0
  fi

  # Empty array → no checks defined for this PR; nothing to wait for.
  count=$(echo "$snapshot" | jq 'length' 2>/dev/null || echo 0)
  if [[ "$count" == "0" ]]; then
    echo "$snapshot"
    exit 0
  fi

  # Are all checks terminal?
  pending=$(echo "$snapshot" | jq '[.[] | select(.conclusion == "" or .conclusion == null)] | length' 2>/dev/null || echo 0)

  if [[ "$pending" == "0" ]]; then
    echo "$snapshot"
    exit 0
  fi

  # Timeout check
  now=$(date +%s)
  elapsed=$((now - start))
  if (( elapsed >= TIMEOUT )); then
    echo "$snapshot"
    exit 1
  fi

  sleep "$INTERVAL"
done
