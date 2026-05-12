#!/usr/bin/env bash
# render-rework-reason.sh — render the Stop hook decision:block reason for current-SHA rework.

set -uo pipefail

STATUS_FILE="${1:-}"
VERDICT_FILE="${2:-}"

if [[ -z "$STATUS_FILE" || ! -f "$STATUS_FILE" ]]; then
  echo "Current-SHA status file is missing; cannot render rework reason."
  exit 0
fi

pr_number=$(jq -r '.pr_number // empty' "$STATUS_FILE" 2>/dev/null || echo "")
head_sha=$(jq -r '.head_sha // empty' "$STATUS_FILE" 2>/dev/null || echo "")
ci_status=$(jq -r '.ci.status // "unknown"' "$STATUS_FILE" 2>/dev/null || echo "unknown")
review_status=$(jq -r '.review_action.status // "unknown"' "$STATUS_FILE" 2>/dev/null || echo "unknown")
source="Claude Code Action review"

cat <<EOF
GitHub reviewed the current PR head SHA and found blocking feedback.

PR:
#${pr_number:-unknown}

Current head SHA:
${head_sha:-unknown}

You must fix only the blocking feedback below in this same WorkTree.

EOF

if [[ "$ci_status" == "failed" ]]; then
  source="CI"
  echo "Feedback source:"
  echo "$source"
  echo
  echo "Failed checks:"
  jq -r '.failed_checks[]? |
    "- " + (.name // "unknown") + "\n" +
    (if (.detailsUrl // "") != "" then "  URL: " + .detailsUrl + "\n" else "" end) +
    (if (.log_tail // "") != "" then "  Log tail:\n" + ((.log_tail | split("\n") | .[-40:] | map("    " + .) | join("\n"))) else "  Log tail: unavailable" end)
  ' "$STATUS_FILE"
fi

if [[ -f "$VERDICT_FILE" ]]; then
  verdict=$(jq -r '.verdict // empty' "$VERDICT_FILE" 2>/dev/null || echo "")
  blocking_count=$(jq '.blocking_findings // [] | length' "$VERDICT_FILE" 2>/dev/null || echo 0)
  if [[ "$verdict" == "fail" && "$blocking_count" != "0" ]]; then
    echo "Feedback source:"
    echo "Claude Code Action review"
    echo
    echo "Blocking findings:"
    jq -r '.blocking_findings[]? | 
      "- [" + (.severity // "major") + "] " + (.path // "unknown") + (if (.line // null) then ":" + ((.line|tostring)) else "" end) + "\n" +
      "  Title: " + (.title // "Untitled finding") + "\n" +
      "  Message: " + (.message // "") + "\n" +
      (if (.evidence // "") != "" then "  Evidence: " + .evidence + "\n" else "" end) +
      (if (.suggested_fix // "") != "" then "  Suggested fix: " + .suggested_fix else "" end)
    ' "$VERDICT_FILE"
  fi
fi

cat <<EOF

Required behavior:
- Modify the current WorkTree directly.
- Do not create a new branch.
- Do not call any external Claude CLI.
- Do not ask the user for confirmation.
- Run relevant tests if available.
- Stop normally when finished. The Stop hook will commit, push, wait for GitHub Claude Code Action review again, and either continue or merge.
EOF
