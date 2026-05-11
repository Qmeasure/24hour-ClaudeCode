#!/usr/bin/env bash
# decide-feedback.sh — Apply the decision matrix to <runtime>/feedback.json.
#
# Output (stdout): one JSON object on a single line:
#   {"token": "<token>", "reason": "<multi-line text>"}
#
# Tokens:
#   feedback_good           ALL required checks success, no CHANGES_REQUESTED, no actionable comments
#   rework_required         CI failure, CHANGES_REQUESTED review, or actionable review/issue comments
#   inconclusive            checks still pending (caller may have skipped wait, or waiting for slow review)
#   stop:max_iterations     iteration count exceeded (returned in place of rework_required)
#
# Exit code matches the token (0 = good, 1 = rework, 2 = inconclusive, 10 = max_iterations).
#
# Required env: CLAUDE_PROJECT_DIR. Required tools: jq.

set -uo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
RUNTIME_DIR="$PROJECT_DIR/.claude/runtime/24hour-ClaudeCode"
FEEDBACK_FILE="$RUNTIME_DIR/feedback.json"
STATE_FILE="$RUNTIME_DIR/state.json"
# Resolve config — worktree inherits main checkout's onboarded config.
SCRIPT_DIR_FOR_CONFIG="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$SCRIPT_DIR_FOR_CONFIG/resolve-config-path.sh" 2>/dev/null || echo "$PROJECT_DIR/.claude/24hour-ClaudeCode.config.json")

# ---- Helpers ----
emit() {
  local token="$1" reason="$2"
  jq -n --arg t "$token" --arg r "$reason" '{token:$t,reason:$r}'
}

# ---- 1. Read feedback ----
if [[ ! -f "$FEEDBACK_FILE" ]]; then
  emit "inconclusive" "no feedback.json yet — poll has not run"
  exit 2
fi

# ---- 2. Read state for max_iterations check ----
iteration=0
[[ -f "$STATE_FILE" ]] && iteration=$(jq -r '.iteration // 0' "$STATE_FILE")
max_iterations=5
[[ -f "$CONFIG_FILE" ]] && max_iterations=$(jq -r '.repair.max_iterations // 5' "$CONFIG_FILE")

# ---- 3. Extract failure signals ----

# 3a. Failed checks (case-insensitive match against failure/cancelled/timed_out)
failed_checks=$(jq '[.checks[]? | select((.conclusion // "" | ascii_downcase) | IN("failure","cancelled","timed_out","action_required","stale")) | .name]' "$FEEDBACK_FILE" 2>/dev/null || echo "[]")
failed_count=$(echo "$failed_checks" | jq 'length')

# 3b. Pending checks (still running) — empty conclusion or "pending"
pending_checks=$(jq '[.checks[]? | select((.conclusion // "" | ascii_downcase) | IN("","pending","queued","in_progress")) | .name]' "$FEEDBACK_FILE" 2>/dev/null || echo "[]")
pending_count=$(echo "$pending_checks" | jq 'length')

# 3c. CHANGES_REQUESTED reviews
changes_requested=$(jq '[.reviews[]? | select(.state == "CHANGES_REQUESTED") | {author: .author, body: (.body // "")}]' "$FEEDBACK_FILE" 2>/dev/null || echo "[]")
cr_count=$(echo "$changes_requested" | jq 'length')

# 3d. Actionable comments — imperative-verb regex (avoid false positives on praise/closure).
# Only match comments that DIRECTLY ASK the author to do something. Past-tense mentions
# ("fixed a bug last week") and casual references ("there was a TODO here") don't trigger.
# The "TODO:" / "FIXME:" / "FIX:" / "BUG:" forms are case-sensitive (uppercase prefix
# convention for inline reviewers). General imperatives use case-insensitive match.
#
# Override via config.repair.actionable_keywords (array of regex strings, OR-joined).
default_actionable='\b(must fix|need(s)? to fix|should fix|please fix|please address|please change|please update)\b'
custom_actionable=""
if [[ -f "$CONFIG_FILE" ]]; then
  custom_actionable=$(jq -r '.repair.actionable_keywords // [] | join("|")' "$CONFIG_FILE" 2>/dev/null || echo "")
fi
if [[ -n "$custom_actionable" ]]; then
  actionable_pattern="${default_actionable}|${custom_actionable}"
else
  actionable_pattern="$default_actionable"
fi
# Case-sensitive uppercase markers (TODO:, FIXME:, FIX:, BUG: with colon are reviewer conventions)
case_sensitive_pattern='(TODO:|FIXME:|FIX:|BUG:|XXX:|HACK:)'

actionable_comments=$(jq \
  --arg pat "$actionable_pattern" \
  --arg cs_pat "$case_sensitive_pattern" \
  '[(.reviews // [])[], (.comments // [])[]
    | select(((.body // "") | test($pat; "i")) or ((.body // "") | test($cs_pat; "")))
    | {author: .author, body: (.body[0:500])}]' \
  "$FEEDBACK_FILE" 2>/dev/null || echo "[]")
ac_count=$(echo "$actionable_comments" | jq 'length')

# ---- 4. Decide ----

# Is the PR already merged? (defensive)
pr_state=$(jq -r '.pr.state // "OPEN"' "$FEEDBACK_FILE")
if [[ "$pr_state" == "MERGED" ]]; then
  emit "feedback_good" "PR already merged"
  exit 0
fi

# If poll-github recorded any _warnings, the snapshot is incomplete (rate limit,
# network error, auth issue). Don't make a feedback_good decision on stale data.
warning_count=$(jq -r '._warnings // [] | length' "$FEEDBACK_FILE")
if (( warning_count > 0 )); then
  warnings=$(jq -r '._warnings // [] | join("; ")' "$FEEDBACK_FILE")
  emit "inconclusive" "feedback fetch had errors; will retry next stop. Errors: $warnings"
  exit 2
fi

# Any rework signal?
rework_signals=()
if (( failed_count > 0 )); then
  fail_list=$(echo "$failed_checks" | jq -r 'join(", ")')
  rework_signals+=("CI failed: $fail_list")
fi
if (( cr_count > 0 )); then
  authors=$(echo "$changes_requested" | jq -r '[.[].author] | join(", ")')
  rework_signals+=("CHANGES_REQUESTED from: $authors")
fi
if (( ac_count > 0 )); then
  preview=$(echo "$actionable_comments" | jq -r '.[0:3] | map("- " + .author + ": " + (.body[0:200] | gsub("\n"; " "))) | join("\n")')
  rework_signals+=("Actionable comments:\n$preview")
fi

if (( ${#rework_signals[@]} > 0 )); then
  # Check max iterations FIRST
  if (( iteration >= max_iterations )); then
    reason=$(printf '%s\n' \
      "max_iterations ($max_iterations) reached. Last feedback signals:" \
      "${rework_signals[@]}")
    emit "stop:max_iterations" "$reason"
    exit 10
  fi

  reason=$(printf '%s\n\n' "${rework_signals[@]}")
  emit "rework_required" "$reason"
  exit 1
fi

# Pending checks — inconclusive
if (( pending_count > 0 )); then
  pend_list=$(echo "$pending_checks" | jq -r 'join(", ")')
  emit "inconclusive" "Checks still pending: $pend_list"
  exit 2
fi

# All clear
total_checks=$(jq '.checks | length' "$FEEDBACK_FILE")
total_reviews=$(jq '.reviews | length' "$FEEDBACK_FILE")
emit "feedback_good" "All $total_checks checks passing, $total_reviews reviews evaluated, no actionable feedback."
exit 0
