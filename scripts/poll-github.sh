#!/usr/bin/env bash
# poll-github.sh — Snapshot PR state, checks, reviews, comments, and failed-job logs
# into <runtime>/feedback.json.
#
# Used by hooks/stop.sh for diagnostics and by the babysit-pr skill.
#
# Output schema (atomic write to feedback.json):
#   {
#     "polled_at": "<ISO timestamp>",
#     "pr": {"number": N, "url": "...", "state": "OPEN|MERGED|CLOSED",
#            "mergeStateStatus": "CLEAN|DIRTY|BEHIND|...",
#            "isDraft": true|false},
#     "checks": [{"name": "...", "conclusion": "success|failure|...", "detailsUrl": "..."}],
#     "failed_jobs": [{"name": "...", "log_tail": "<last 50 lines>", "url": "..."}],
#     "reviews": [{"author": "...", "state": "APPROVED|CHANGES_REQUESTED|COMMENTED",
#                  "body": "...", "submittedAt": "..."}],
#     "comments": [{"kind": "issue|review|inline",
#                   "author": "...", "body": "...",
#                   "path": "<file path for inline>", "line": <int for inline>,
#                   "createdAt": "..."}]
#   }
#
# Required env: CLAUDE_PROJECT_DIR.
# Required tools: gh, jq.

set -uo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
RUNTIME_DIR="$PROJECT_DIR/.claude/runtime/24hour-ClaudeCode"
FEEDBACK_FILE="$RUNTIME_DIR/feedback.json"

mkdir -p "$RUNTIME_DIR"
cd "$PROJECT_DIR"

# Determine PR number — prefer current-pr.json for speed; fall back to gh.
pr_num=""
if [[ -f "$RUNTIME_DIR/current-pr.json" ]]; then
  pr_num=$(jq -r '.number // empty' "$RUNTIME_DIR/current-pr.json" 2>/dev/null || echo "")
fi
[[ -z "$pr_num" ]] && pr_num=$(gh pr view --json number --jq '.number' 2>/dev/null || echo "")

if [[ -z "$pr_num" ]]; then
  jq -n '{polled_at: now | todate, pr: null, checks: [], failed_jobs: [], reviews: [], comments: []}' > "$FEEDBACK_FILE.tmp"
  mv "$FEEDBACK_FILE.tmp" "$FEEDBACK_FILE"
  cat "$FEEDBACK_FILE"
  exit 0
fi

# Resolve repo (owner/name) for raw API calls
repo_nwo=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || echo "")

# Per-field gh calls (per references/monitor-template.md rule #1)
state=$(gh pr view "$pr_num" --json state --jq '.state' 2>/dev/null || echo "ERR")
merge=$(gh pr view "$pr_num" --json mergeStateStatus --jq '.mergeStateStatus' 2>/dev/null || echo "ERR")
url=$(gh pr view "$pr_num" --json url --jq '.url' 2>/dev/null || echo "")
is_draft=$(gh pr view "$pr_num" --json isDraft --jq '.isDraft' 2>/dev/null || echo "false")

warnings_arr='[]'
add_warning() {
  warnings_arr=$(echo "$warnings_arr" | jq --arg msg "$1" '. + [$msg]')
}

ERR_TMP=$(mktemp)
trap 'rm -f "$ERR_TMP"' EXIT

checks=$(gh pr view "$pr_num" --json statusCheckRollup --jq \
  '[.statusCheckRollup[]? | {name: .name, conclusion: (.conclusion // ""), detailsUrl: (.detailsUrl // ""), workflowName: (.workflowName // "")}]' \
  2>"$ERR_TMP") || {
    err_line=$(head -1 "$ERR_TMP" 2>/dev/null || echo "unknown error")
    add_warning "checks fetch failed: $err_line"
    checks="[]"
  }

reviews=$(gh pr view "$pr_num" --json reviews --jq \
  '[.reviews[]? | {author: .author.login, state: .state, body: (.body // ""), submittedAt: .submittedAt}]' \
  2>"$ERR_TMP") || {
    err_line=$(head -1 "$ERR_TMP" 2>/dev/null || echo "unknown error")
    add_warning "reviews fetch failed: $err_line"
    reviews="[]"
  }

# PR conversation (issue) comments via issue endpoint
issue_comments="[]"
if [[ -n "$repo_nwo" ]]; then
  issue_comments=$(gh api "repos/$repo_nwo/issues/$pr_num/comments" --paginate \
    --jq '[.[] | {kind: "issue", author: .user.login, body: (.body // ""), createdAt: .created_at}]' \
    2>"$ERR_TMP") || {
      err_line=$(head -1 "$ERR_TMP" 2>/dev/null || echo "unknown error")
      add_warning "issue_comments fetch failed: $err_line"
      issue_comments="[]"
    }
fi

# Inline review comments (line-anchored)
inline_comments="[]"
if [[ -n "$repo_nwo" ]]; then
  inline_comments=$(gh api "repos/$repo_nwo/pulls/$pr_num/comments" --paginate \
    --jq '[.[] | {kind: "inline", author: .user.login, body: (.body // ""), path: (.path // ""), line: (.line // .original_line // null), createdAt: .created_at}]' \
    2>"$ERR_TMP") || {
      err_line=$(head -1 "$ERR_TMP" 2>/dev/null || echo "unknown error")
      add_warning "inline_comments fetch failed: $err_line"
      inline_comments="[]"
    }
fi

# Combined comments array (issue + inline)
comments=$(jq -n --argjson a "$issue_comments" --argjson b "$inline_comments" '$a + $b')

# Failed-job logs: for each `failure`/`cancelled` check, fetch last 50 lines
failed_jobs="[]"
failed_check_urls=$(echo "$checks" | jq -r '.[] | select(.conclusion == "failure" or .conclusion == "cancelled") | .detailsUrl' 2>/dev/null || true)

if [[ -n "$failed_check_urls" ]]; then
  collected="[]"
  while IFS= read -r details_url; do
    [[ -z "$details_url" ]] && continue
    # Extract run ID from URL (.../actions/runs/<id>/...)
    run_id=$(echo "$details_url" | grep -oE '/runs/[0-9]+' | grep -oE '[0-9]+' | head -1)
    job_id=$(echo "$details_url" | grep -oE '/job/[0-9]+' | grep -oE '[0-9]+' | head -1)
    [[ -z "$run_id" ]] && continue

    log_tail=""
    if [[ -n "$job_id" ]]; then
      log_tail=$(gh run view "$run_id" --job "$job_id" --log 2>/dev/null | tail -50 || echo "")
    else
      log_tail=$(gh run view "$run_id" --log-failed 2>/dev/null | tail -50 || echo "")
    fi
    # Strip ANSI escape sequences, trim
    log_tail=$(printf '%s' "$log_tail" | sed 's/\x1b\[[0-9;]*m//g')

    name=$(echo "$checks" | jq -r --arg url "$details_url" '.[] | select(.detailsUrl == $url) | .name' | head -1)
    item=$(jq -n --arg n "$name" --arg t "$log_tail" --arg u "$details_url" \
      '{name: $n, log_tail: $t, url: $u}')
    collected=$(echo "$collected" | jq --argjson it "$item" '. + [$it]')
  done <<< "$failed_check_urls"
  failed_jobs="$collected"
fi

now=$(date -u +%FT%TZ)

jq -n \
  --arg ts "$now" \
  --argjson n "$pr_num" \
  --arg url "$url" \
  --arg state "$state" \
  --arg merge "$merge" \
  --argjson draft "$is_draft" \
  --argjson checks "$checks" \
  --argjson failed_jobs "$failed_jobs" \
  --argjson reviews "$reviews" \
  --argjson comments "$comments" \
  --argjson warnings "$warnings_arr" \
  '{
    polled_at: $ts,
    pr: {number: $n, url: $url, state: $state, mergeStateStatus: $merge, isDraft: $draft},
    checks: $checks,
    failed_jobs: $failed_jobs,
    reviews: $reviews,
    comments: $comments,
    _warnings: $warnings
  }' > "$FEEDBACK_FILE.tmp"

mv "$FEEDBACK_FILE.tmp" "$FEEDBACK_FILE"
cat "$FEEDBACK_FILE"
