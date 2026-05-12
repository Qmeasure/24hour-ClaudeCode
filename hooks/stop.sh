#!/usr/bin/env bash
# stop.sh — Stop hook for 24hour-ClaudeCode plugin (Revision 2).
#
# Fires when Claude finishes a turn. This is the heavy worker — owns the
# auto-commit pipeline AND the post-PR poll/decide loop.
#
# Two output formats per the official Stop hook spec:
#   1. {"systemMessage":"<text>"}
#      Informational; Claude is allowed to stop.
#   2. {"decision":"block","reason":"<text>"}
#      Forces Claude NOT to stop; reason is fed back as context — the rework loop.
#
# Mode-aware. state.json's `mode` field drives the dispatch:
#   - idle: no PR, no in-flight work. If diff non-empty → enter pre-PR commit/push flow.
#   - waiting_for_preflight_merge: a workflow-only "preflight" PR was auto-split
#     and is in flight. Poll its state; on merged, rebase + fall through to idle.
#   - waiting_for_review: PR exists, just pushed → wait current HEAD SHA CI/review, decide.
#   - ready_for_rework: previous round flagged rework. If diff non-empty → enter pre-PR
#     flow with iteration++ semantics.
#   - stopped: hard stop after missing/stale/inconclusive/repeated feedback.
#   - merged: cleanup pass.
#
# Required env (Claude Code provides): CLAUDE_PLUGIN_ROOT, CLAUDE_PROJECT_DIR.
# Required tools: jq, gh, git.

set -uo pipefail   # NOT -e: pipeline failures are handled per-step; we always exit 0

HOOK_INPUT="$(cat || true)"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
SCRIPTS="$PLUGIN_ROOT/scripts"
REVIEW_LOOP="$SCRIPTS/review-loop"
RUNTIME_DIR="$PROJECT_DIR/.claude/runtime/24hour-ClaudeCode"
GOAL_GUARD_FILE="$RUNTIME_DIR/goal-guard.json"
GOAL_GUARD_CLEARED_FILE="$RUNTIME_DIR/goal-guard-cleared.json"
GOAL_COMPLETE_MARKER='<24hour-ClaudeCode-goal-complete ready-to-ship="true" />'
# Resolve config — local first, main checkout fallback (so worktrees inherit main's onboarded config).
CONFIG_FILE=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$SCRIPTS/resolve-config-path.sh" 2>/dev/null || echo "$PROJECT_DIR/.claude/24hour-ClaudeCode.config.json")

mkdir -p "$RUNTIME_DIR"
cd "$PROJECT_DIR"

# ============================================================================
# Helpers
# ============================================================================

# Emit an informational message to the user and exit 0.
#
# IMPORTANT: Stop hook's JSON output schema does NOT accept
# hookSpecificOutput.additionalContext (that field is for PreToolUse /
# UserPromptSubmit / PostToolUse / PostToolBatch only). Stop's only
# user-facing message channel is the top-level `systemMessage` field.
# Earlier versions of this script copied SessionStart's emit format and
# triggered "Hook JSON output validation failed" on every run.
emit_info() {
  local content="$1"
  jq -n --arg msg "$content" '{systemMessage:$msg}'
  release_lock
  exit 0
}

# Emit decision:block (forces Claude to continue with reason as feedback) and exit 0.
emit_block() {
  local reason="$1"
  jq -n --arg r "$reason" '{decision:"block",reason:$r}'
  release_lock
  exit 0
}

# Acquire lock; return 0 success, 1 if held.
acquire_lock() { bash "$SCRIPTS/runtime-lock.sh" acquire; }
release_lock() { bash "$SCRIPTS/runtime-lock.sh" release 2>/dev/null || true; }

# Append an event to last-run.json, atomic write.
record_event() {
  local status="$1" detail="${2:-}"
  local now=$(date -u +%FT%TZ)
  local prev_streak=0
  if [[ -f "$RUNTIME_DIR/last-run.json" ]]; then
    prev_streak=$(jq -r '.fail_streak // 0' "$RUNTIME_DIR/last-run.json" 2>/dev/null || echo 0)
  fi
  local streak
  # fail_streak counts CONSECUTIVE failures only — rework is the normal happy
  # path of the loop (review found something, Claude fixed it, push again).
  # Counting rework here used to break the loop after 2 legitimate review
  # rounds via check-stop-conditions.sh `fail_streak >= 2 → stop:repeated_failure`.
  if [[ "$status" == failed:* ]]; then
    streak=$((prev_streak + 1))
  else
    streak=0
  fi
  jq -n --arg ts "$now" --arg s "$status" --arg d "$detail" --argjson fs "$streak" \
    '{ts:$ts, status:$s, detail:$d, fail_streak:$fs}' > "$RUNTIME_DIR/last-run.json.tmp"
  mv "$RUNTIME_DIR/last-run.json.tmp" "$RUNTIME_DIR/last-run.json"
}

# Read state field (default empty string).
state_get() { bash "$SCRIPTS/runtime-state.sh" get "$1" 2>/dev/null || echo ""; }
state_set() { bash "$SCRIPTS/runtime-state.sh" set "$1" "$2" 2>/dev/null || true; }

feedback_hash_from_files() {
  local status_file="$1" verdict_file="${2:-}"
  if [[ -n "$verdict_file" && -f "$verdict_file" ]] && \
     [[ "$(jq '.blocking_findings // [] | length' "$verdict_file" 2>/dev/null || echo 0)" != "0" ]]; then
    jq -S '[.blocking_findings[]? | {id,severity,category,path,title,message}]' "$verdict_file" \
      | shasum -a 256 | awk '{print $1}'
    return
  fi
  jq -S '[.failed_checks[]? | {name,detailsUrl,log_tail}]' "$status_file" 2>/dev/null \
    | shasum -a 256 | awk '{print $1}'
}

remember_feedback_or_stop() {
  local status_file="$1" verdict_file="${2:-}"
  local hash last same_count
  hash=$(feedback_hash_from_files "$status_file" "$verdict_file")
  last=$(state_get last_feedback_hash)
  same_count=$(state_get same_feedback_count)
  [[ "$same_count" =~ ^[0-9]+$ ]] || same_count=0

  if [[ -n "$last" && "$last" == "$hash" ]]; then
    same_count=$((same_count + 1))
  else
    same_count=0
  fi

  state_set last_feedback_hash "$hash"
  state_set same_feedback_count "$same_count"

  if (( same_count >= 2 )); then
    return 1
  fi
  return 0
}

refresh_current_pr_file() {
  local pr_num="$1"
  gh pr view "$pr_num" --json number,url,isDraft,headRefName,headRefOid,baseRefName,state \
    > "$RUNTIME_DIR/current-pr.json" 2>/dev/null || true
}

goal_guard_blocks_shipping() {
  local enabled last_msg stop_hook_active transcript latest_goal latest_goal_met goal_text goal_uuid marker_present guard_present tmp
  enabled="true"
  if [[ -f "$CONFIG_FILE" ]]; then
    enabled=$(jq -r '.repair.goal_mode_gate // true' "$CONFIG_FILE" 2>/dev/null || echo "true")
  fi
  [[ "$enabled" == "true" ]] || return 1

  guard_present=0
  [[ -f "$GOAL_GUARD_FILE" ]] && guard_present=1

  last_msg=$(printf '%s' "$HOOK_INPUT" | jq -r '.last_assistant_message // ""' 2>/dev/null || echo "")
  stop_hook_active=$(printf '%s' "$HOOK_INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null || echo "false")
  transcript=$(printf '%s' "$HOOK_INPUT" | jq -r '.transcript_path // ""' 2>/dev/null || echo "")
  marker_present=false
  if printf '%s\n' "$last_msg" | awk -v marker="$GOAL_COMPLETE_MARKER" '
    /^[[:space:]]*```/ { in_code = !in_code }
    NF { last = $0; last_in_code = in_code }
    END { exit (last == marker && !last_in_code) ? 0 : 1 }
  '; then
    marker_present=true
  fi

  latest_goal=""
  if [[ -n "$transcript" && -f "$transcript" ]]; then
    latest_goal=$(jq -c '
      select(.attachment.type? == "goal_status")
      | {
          met:(.attachment.met // false),
          condition:(.attachment.condition // ""),
          reason:(.attachment.reason // ""),
          uuid:(.uuid // ""),
          timestamp:(.timestamp // "")
        }
    ' "$transcript" 2>/dev/null | tail -n 1 || true)
  fi

  if [[ -n "$latest_goal" ]]; then
    latest_goal_met=$(jq -r '.met // false' <<< "$latest_goal" 2>/dev/null || echo "false")
    goal_text=$(jq -r '.condition // "(unknown goal)"' <<< "$latest_goal" 2>/dev/null || echo "(unknown goal)")
    goal_uuid=$(jq -r '.uuid // ""' <<< "$latest_goal" 2>/dev/null || echo "")

    if [[ "$latest_goal_met" == "true" ]]; then
      rm -f "$GOAL_GUARD_FILE" "$GOAL_GUARD_CLEARED_FILE" 2>/dev/null || true
      record_event "goal_guard_released" "native goal_status met=true uuid=$goal_uuid"
      return 1
    fi

    # On this machine, the native /goal evaluator runs after project Stop hooks.
    # Same-turn shipping therefore needs the marker in last_assistant_message;
    # transcript goal_status is still useful as a fallback and diagnostic guard.
    if [[ "$marker_present" == "true" ]]; then
      rm -f "$GOAL_GUARD_FILE" "$GOAL_GUARD_CLEARED_FILE" 2>/dev/null || true
      record_event "goal_guard_released" "ready-to-ship marker found while native goal_status is not yet met uuid=$goal_uuid"
      return 1
    fi

    if (( guard_present == 1 )) || [[ ! -f "$GOAL_GUARD_CLEARED_FILE" ]]; then
      tmp=$(mktemp)
      jq -n --arg goal "$goal_text" --arg marker "$GOAL_COMPLETE_MARKER" --arg uuid "$goal_uuid" \
        '{active:true, goal:$goal, marker:$marker, source:"transcript-goal-status", goal_status_uuid:$uuid}' > "$tmp"
      mv "$tmp" "$GOAL_GUARD_FILE"
      guard_present=1
    fi
  fi

  [[ "$guard_present" == "1" ]] || return 1

  if [[ "$marker_present" == "true" ]]; then
    rm -f "$GOAL_GUARD_FILE" "$GOAL_GUARD_CLEARED_FILE" 2>/dev/null || true
    record_event "goal_guard_released" "ready-to-ship marker found"
    return 1
  fi

  goal_text=$(jq -r '.goal // "(unknown goal)"' "$GOAL_GUARD_FILE" 2>/dev/null || echo "(unknown goal)")
  record_event "goal_guard_hold" "stop_hook_active=$stop_hook_active goal=${goal_text:0:160}"
  emit_info "$(printf '%s\n' \
    "<24hour-ClaudeCode>" \
    "Goal mode guard is active, so the plugin will not commit, push, or open a PR yet." \
    "" \
    "Reason: a /goal was started and the final ready-to-ship marker is absent from Claude's latest message." \
    "The native Claude Code goal_status signal is used as a fallback, but on this machine the /goal evaluator runs after project Stop hooks, so same-turn shipping requires the marker." \
    "" \
    "Goal:" \
    "$goal_text" \
    "" \
    "Required marker before shipping:" \
    "$GOAL_COMPLETE_MARKER" \
    "" \
    "Continue the Goal session until the goal condition is satisfied. When it is truly complete, Claude must make the exact marker above the final non-empty line of its final message; the next Stop hook will then submit the PR."
  )"
}

handle_waiting_for_review() {
  local pr_num head_sha wait_seconds interval status_file verdict_file
  pr_num=$(state_get pr_number)
  if [[ -z "$pr_num" || "$pr_num" == "null" ]]; then
    state_set mode "idle"
    record_event "recovered" "waiting_for_review without PR; reset to idle"
    exit 0
  fi

  head_sha=$(git rev-parse HEAD 2>/dev/null || echo "")
  if [[ -z "$head_sha" ]]; then
    record_event "stop:no_head_sha" "pr=$pr_num"
    emit_info "<24hour-ClaudeCode> Automatic review loop stopped: could not resolve current HEAD SHA."
  fi

  wait_seconds="${REVIEW_LOOP_TIMEOUT:-7200}"
  interval=20
  if [[ -f "$CONFIG_FILE" ]]; then
    wait_seconds=$(jq -r '.repair.review_loop_timeout // .repair.wait_seconds // 7200' "$CONFIG_FILE" 2>/dev/null || echo 7200)
    interval=$(jq -r '.repair.review_loop_interval // 20' "$CONFIG_FILE" 2>/dev/null || echo 20)
  fi

  state_set mode "waiting_for_review"
  state_set current_head_sha "$head_sha"
  state_set wait_started_at "$(date -u +%FT%TZ)"

  gh pr ready "$pr_num" >/dev/null 2>&1 || true
  refresh_current_pr_file "$pr_num"

  status_file="$RUNTIME_DIR/status-$head_sha.json"
  verdict_file="$RUNTIME_DIR/verdict-$head_sha.json"

  bash "$REVIEW_LOOP/wait-for-current-sha-status.sh" \
    --pr "$pr_num" \
    --sha "$head_sha" \
    --timeout "$wait_seconds" \
    --interval "$interval" \
    > "$status_file" 2>"$RUNTIME_DIR/wait-$head_sha.err"

  ci_status=$(jq -r '.ci.status // "missing"' "$status_file" 2>/dev/null || echo "missing")
  review_status=$(jq -r '.review_action.status // "missing"' "$status_file" 2>/dev/null || echo "missing")
  review_run_id=$(jq -r '.review_action.run_id // empty' "$status_file" 2>/dev/null || echo "")

  if [[ "$ci_status" == "failed" ]]; then
    round_now=$(state_get round)
    max_rounds_now=$(state_get max_rounds)
    [[ "$round_now" =~ ^[0-9]+$ ]] || round_now=0
    [[ "$max_rounds_now" =~ ^[0-9]+$ ]] || max_rounds_now=5
    if (( round_now >= max_rounds_now )); then
      state_set mode "stopped"
      record_event "stop:max_rounds" "pr=$pr_num sha=$head_sha round=$round_now/$max_rounds_now source=ci"
      emit_info "<24hour-ClaudeCode> Automatic review loop stopped: max rounds reached ($round_now/$max_rounds_now) after CI failed for current HEAD $head_sha."
    fi
    verdict_placeholder=$(mktemp)
    jq -n --arg sha "$head_sha" '{schema_version:1,head_sha:$sha,verdict:"inconclusive",blocking_findings:[],confidence:"low",status:"missing"}' > "$verdict_placeholder"
    reason=$(bash "$REVIEW_LOOP/render-rework-reason.sh" "$status_file" "$verdict_placeholder")
    rm -f "$verdict_placeholder"
    if ! remember_feedback_or_stop "$status_file"; then
      state_set mode "stopped"
      record_event "stop:repeated_feedback" "pr=$pr_num sha=$head_sha source=ci"
      emit_info "<24hour-ClaudeCode> Automatic review loop stopped: repeated CI feedback for current HEAD $head_sha."
    fi
    state_set mode "ready_for_rework"
    record_event "rework:ci" "pr=$pr_num sha=$head_sha"
    emit_block "$reason"
  fi

  if [[ "$ci_status" != "success" ]]; then
    state_set mode "stopped"
    record_event "stop:ci_not_success" "pr=$pr_num sha=$head_sha ci=$ci_status"
    emit_info "<24hour-ClaudeCode> Automatic review loop stopped: CI did not reach a reliable success state for current HEAD $head_sha (ci.status=$ci_status)."
  fi

  if [[ "$review_status" != "success" ]]; then
    state_set mode "stopped"
    record_event "stop:review_not_success" "pr=$pr_num sha=$head_sha review=$review_status"
    emit_info "<24hour-ClaudeCode> Automatic review loop stopped: Claude Code Action review did not complete successfully for current HEAD $head_sha (review.status=$review_status)."
  fi

  bash "$REVIEW_LOOP/fetch-review-verdict.sh" \
    --pr "$pr_num" \
    --sha "$head_sha" \
    --run-id "$review_run_id" \
    > "$verdict_file" 2>"$RUNTIME_DIR/verdict-$head_sha.err"

  decision=$(bash "$REVIEW_LOOP/decide-current-sha-feedback.sh" \
    --status "$status_file" \
    --verdict "$verdict_file" \
    --state "$RUNTIME_DIR/state.json" 2>/dev/null)
  token=$(echo "$decision" | jq -r '.token // "stop"')
  decision_reason=$(echo "$decision" | jq -r '.reason // ""')

  case "$token" in
    rework_required)
      reason=$(bash "$REVIEW_LOOP/render-rework-reason.sh" "$status_file" "$verdict_file")
      if ! remember_feedback_or_stop "$status_file" "$verdict_file"; then
        state_set mode "stopped"
        record_event "stop:repeated_feedback" "pr=$pr_num sha=$head_sha source=review"
        emit_info "<24hour-ClaudeCode> Automatic review loop stopped: repeated blocking feedback for current HEAD $head_sha."
      fi
      state_set mode "ready_for_rework"
      record_event "rework:review" "pr=$pr_num sha=$head_sha"
      emit_block "$reason"
      ;;

    pass)
      pr_head=$(gh pr view "$pr_num" --json headRefOid --jq '.headRefOid' 2>/dev/null || echo "")
      pr_state=$(gh pr view "$pr_num" --json state --jq '.state' 2>/dev/null || echo "")
      is_draft=$(gh pr view "$pr_num" --json isDraft --jq '.isDraft' 2>/dev/null || echo "true")
      confidence=$(jq -r '.confidence // "low"' "$verdict_file" 2>/dev/null || echo "low")
      blocking_count=$(jq '.blocking_findings // [] | length' "$verdict_file" 2>/dev/null || echo 1)

      if [[ "$pr_head" != "$head_sha" || "$pr_state" != "OPEN" || "$is_draft" == "true" || "$confidence" == "low" || "$blocking_count" != "0" ]]; then
        state_set mode "stopped"
        record_event "stop:merge_gate" "pr=$pr_num sha=$head_sha pr_head=$pr_head state=$pr_state draft=$is_draft confidence=$confidence blocking=$blocking_count"
        emit_info "<24hour-ClaudeCode> Automatic review loop stopped: merge gate failed for PR #$pr_num at HEAD $head_sha."
      fi

      gh pr ready "$pr_num" >/dev/null 2>&1 || true
      merge_out=$(gh pr merge "$pr_num" --auto --squash 2>&1)
      merge_exit=$?
      merged=$(gh pr view "$pr_num" --json state,mergedAt --jq '.state == "MERGED" or .mergedAt != null' 2>/dev/null || echo false)
      state_set last_reviewed_sha "$head_sha"
      if [[ "$merged" == "true" ]]; then
        state_set mode "merged"
        record_event "merged" "pr=$pr_num sha=$head_sha merge_exit=$merge_exit"
        emit_info "<24hour-ClaudeCode> PR #$pr_num merged after CI and Claude Code Action review passed for HEAD $head_sha."
      fi
      if (( merge_exit == 0 )); then
        state_set mode "merged"
        record_event "auto_merge_enabled" "pr=$pr_num sha=$head_sha"
        emit_info "<24hour-ClaudeCode> Auto-merge enabled for PR #$pr_num after CI and Claude Code Action review passed for HEAD $head_sha. GitHub will merge it when branch protection is satisfied."
      fi
      state_set mode "stopped"
      record_event "failed:merge" "pr=$pr_num sha=$head_sha detail=${merge_out:0:200}"
      emit_info "<24hour-ClaudeCode> CI and review passed for PR #$pr_num, but enabling auto-merge failed: $merge_out"
      ;;

    stop|*)
      state_set mode "stopped"
      record_event "stop:current_sha_decision" "pr=$pr_num sha=$head_sha token=$token reason=${decision_reason:0:200}"
      emit_info "<24hour-ClaudeCode> Automatic review loop stopped: $decision_reason"
      ;;
  esac
}

# Defensive runtime init.
bash "$SCRIPTS/runtime-state.sh" init 2>/dev/null || true

# ============================================================================
# 1. Disabled? Bail silently.
# ============================================================================
if [[ -f "$CONFIG_FILE" ]]; then
  enabled=$(jq -r '.enabled // true' "$CONFIG_FILE" 2>/dev/null || echo "true")
  [[ "$enabled" == "false" ]] && exit 0
fi

# ============================================================================
# 2. Not a worktree? Bail silently.
# ============================================================================
git_dir=$(git rev-parse --git-dir 2>/dev/null || echo "")
git_common=$(git rev-parse --git-common-dir 2>/dev/null || echo "")
if [[ -z "$git_dir" || "$git_dir" == "$git_common" ]]; then
  exit 0
fi

# ============================================================================
# 3. Acquire lock or queue.
# ============================================================================
if ! acquire_lock; then
  exit 0   # another stop is in flight; this one queues silently
fi

# Ensure lock is released on any unexpected exit.
trap 'release_lock' EXIT

# ============================================================================
# 4. Read mode + dirty + diff.
# ============================================================================
mode=$(state_get mode)
# Defensive: missing/blank mode happens with pre-R2 state.json files. Infer
# from the runtime: a current-pr.json present means we were mid-loop, so
# resume as ready_for_rework rather than treating as fresh idle (which
# would reset the iteration counter).
if [[ -z "$mode" ]]; then
  if [[ -f "$RUNTIME_DIR/current-pr.json" ]]; then
    mode="ready_for_rework"
  else
    mode="idle"
  fi
fi

dirty=0
[[ -f "$RUNTIME_DIR/dirty" ]] && dirty=1

diff_nonempty=0
git diff --quiet 2>/dev/null || diff_nonempty=1
git diff --staged --quiet 2>/dev/null || diff_nonempty=1
# Untracked files also count as changes
[[ -n "$(git status --porcelain 2>/dev/null)" ]] && diff_nonempty=1

# ============================================================================
# 5. Branch on (mode, diff)
# ============================================================================

# ---- merged: cleanup pass ----
if [[ "$mode" == "merged" ]]; then
  rm -f "$RUNTIME_DIR/current-pr.json" "$RUNTIME_DIR/feedback.json" "$RUNTIME_DIR/dirty" \
    "$RUNTIME_DIR"/status-*.json "$RUNTIME_DIR"/verdict-*.json \
    "$RUNTIME_DIR"/wait-*.err "$RUNTIME_DIR"/verdict-*.err 2>/dev/null
  state_set mode "idle"
  state_set iteration 0
  state_set round 0
  state_set pr_number null
  state_set current_head_sha null
  state_set last_feedback_hash null
  state_set same_feedback_count 0
  record_event "cleanup" "post-merge"
  exit 0
fi

# ---- waiting_for_preflight_merge: workflow-only PR is in flight ----
if [[ "$mode" == "waiting_for_preflight_merge" ]]; then
  preflight_pr=$(state_get preflight_pr)
  if [[ -z "$preflight_pr" || "$preflight_pr" == "null" ]]; then
    # State drift: recover to idle.
    state_set mode "idle"
    record_event "recovered" "waiting_for_preflight_merge without preflight_pr; reset to idle"
    exit 0
  fi

  # Query the preflight PR's state.
  pr_state=$(gh pr view "$preflight_pr" --json state --jq '.state' 2>/dev/null || echo "")

  case "$pr_state" in
    MERGED)
      # Rebase the original branch onto the new base (which now contains the
      # workflow file changes) so the next push has a clean diff.
      # --autostash so the user's pending non-workflow edits in the working
      # tree don't block the rebase.
      base_branch=$(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null || echo "main")
      git fetch origin "$base_branch" >/dev/null 2>&1 || true

      if git rebase --autostash "origin/$base_branch" >/dev/null 2>&1; then
        state_set mode "idle"
        state_set preflight_pr null
        record_event "preflight_merged" "pr=$preflight_pr rebased onto origin/$base_branch"
        # Fall through to Case A so any remaining (non-workflow) edits flow through
        # the normal commit → push → ensure-pr → wait pipeline immediately.
        mode="idle"
      else
        # Rebase conflict — abort and ask user to resolve.
        git rebase --abort >/dev/null 2>&1 || true
        record_event "preflight_rebase_conflict" "pr=$preflight_pr"
        msg=$(printf '%s\n' \
          "<24hour-ClaudeCode>" \
          "Preflight PR #$preflight_pr merged, but rebase onto origin/$base_branch conflicted." \
          "" \
          "Resolve manually:" \
          "  git fetch origin $base_branch" \
          "  git rebase origin/$base_branch" \
          "  # resolve conflicts, git rebase --continue" \
          "" \
          "Then end your turn — the next stop will continue the auto-PR loop.")
        # Reset state so the user's resolution is welcomed back into idle.
        state_set mode "idle"
        state_set preflight_pr null
        emit_info "$msg"
      fi
      ;;

    OPEN)
      record_event "preflight_open" "pr=$preflight_pr (waiting for auto-merge)"
      emit_info "<24hour-ClaudeCode> Preflight workflow PR #$preflight_pr is still open (auto-merge enabled — waiting for required checks). The auto-PR loop will resume once it merges."
      ;;

    CLOSED|"")
      # CLOSED-not-merged or gh query failed.
      record_event "stop:preflight_closed" "pr=$preflight_pr state=${pr_state:-unknown}"
      state_set mode "idle"
      state_set preflight_pr null
      msg=$(printf '%s\n' \
        "<24hour-ClaudeCode>" \
        "⛔ STOP condition: stop:preflight_closed" \
        "" \
        "Preflight PR #$preflight_pr was closed without merging." \
        "Workflow file changes need to land on the default branch before the main branch's auto-review can run." \
        "" \
        "Options:" \
        "  1. Reopen and merge PR #$preflight_pr." \
        "  2. Set repair.allow_workflow_in_pr=true in .claude/24hour-ClaudeCode.config.json to bundle workflow + code (auto-review will fail; manual review required)." \
        "  3. Revert the workflow changes locally so the loop continues without them." \
        "" \
        "Invoke failure-escalation skill for the user-facing message.")
      emit_info "$msg"
      ;;

    *)
      record_event "preflight_unknown_state" "pr=$preflight_pr state=$pr_state"
      emit_info "<24hour-ClaudeCode> Preflight PR #$preflight_pr is in an unexpected state ($pr_state). Will retry on next stop."
      ;;
  esac
fi

# ---- waiting_for_review: synchronously wait/decide for the current HEAD SHA ----
# `waiting_for_checks` is accepted for compatibility with older state.json files.
if [[ "$mode" == "waiting_for_review" || "$mode" == "waiting_for_checks" ]]; then
  handle_waiting_for_review
fi

# ---- idle / ready_for_rework: maybe new push ----
if [[ "$mode" == "idle" || "$mode" == "ready_for_rework" ]]; then
  if (( diff_nonempty == 0 && dirty == 0 )); then
    if [[ "$mode" == "ready_for_rework" ]]; then
      state_set mode "stopped"
      record_event "stop:no_rework_diff" "ready_for_rework ended without changes"
      emit_info "<24hour-ClaudeCode> Automatic review loop stopped: Claude was asked to rework feedback, but the WorkTree has no new diff."
    fi
    # Nothing to do — chat-only turn or post-cleanup.
    record_event "skipped" "no changes (mode=$mode)"
    exit 0
  fi

  # Detect changes (incl. danger paths).
  changes_json=$(bash "$SCRIPTS/detect-changes.sh" 2>/dev/null || echo '{"has_changes":false,"danger_hit":[]}')
  has_changes=$(echo "$changes_json" | jq -r '.has_changes')

  if [[ "$has_changes" != "true" ]]; then
    record_event "skipped" "detect-changes saw no real diff"
    rm -f "$RUNTIME_DIR/dirty" 2>/dev/null
    exit 0
  fi

  goal_guard_blocks_shipping

  # ---- Trivial-only diff: skip the round-trip ----
  # When the only thing that changed is .gitignore (or other future trivial
  # entries), there is no review value in opening a PR + waiting for CI +
  # auto-merge. The user can either roll it into the next real edit or commit
  # it manually. Clear the `dirty` marker so we don't keep re-checking.
  total_files=$(echo "$changes_json" | jq -r '.files | length')
  trivial_files=$(echo "$changes_json" | jq -r '.buckets.trivial | length')
  if (( total_files > 0 )) && (( total_files == trivial_files )); then
    trivial_list=$(echo "$changes_json" | jq -r '.buckets.trivial | join(", ")')
    record_event "skipped" "trivial-only diff ($trivial_list) — not opening PR"
    rm -f "$RUNTIME_DIR/dirty" 2>/dev/null
    emit_info "[24hour-ClaudeCode] Skipped: only trivial file(s) changed ($trivial_list). The runtime will engage on the next substantive edit; commit this manually if you want it on the record."
    # emit_info calls exit 0 internally; the line below is defense-in-depth.
    exit 0
  fi

  # ---- Workflow-file detection: auto-split if needed ----
  # GitHub refuses (HTTP 401) to authenticate the auto-review when a PR's
  # .github/workflows/*.yml differs from the default branch. To keep the loop
  # working, peel workflow changes off into a separate "preflight" PR that
  # auto-merges first; the main branch's PR then has a clean diff.
  workflow_count=$(echo "$changes_json" | jq -r '.buckets.workflow | length')
  allow_in_pr="false"
  if [[ -f "$CONFIG_FILE" ]]; then
    allow_in_pr=$(jq -r '.repair.allow_workflow_in_pr // false' "$CONFIG_FILE")
  fi

  if (( workflow_count > 0 )) && [[ "$allow_in_pr" != "true" ]]; then
    # Refuse if any workflow file already in committed (un-pushed) history.
    base_branch=$(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null || echo "main")
    git fetch origin "$base_branch" >/dev/null 2>&1 || true
    committed_workflows=$(git log "origin/$base_branch..HEAD" --name-only --pretty=format: 2>/dev/null \
                         | grep -E '^\.github/workflows/.+\.ya?ml$' | sort -u || true)
    if [[ -n "$committed_workflows" ]]; then
      record_event "stop:committed_workflow_changes" "files=$(echo "$committed_workflows" | tr '\n' ' ')"
      hit=$(echo "$workflow_count" | head)
      msg=$(printf '%s\n' \
        "Your branch has workflow file changes in committed (un-pushed) history:" \
        "$(echo "$committed_workflows" | sed 's/^/  - /')" \
        "" \
        "GitHub's workflow-validation security policy will refuse the auto-review (HTTP 401) on a PR that mixes workflow + code commits." \
        "" \
        "Resolve manually:" \
        "  git reset HEAD~ -- .github/workflows/    # un-stage workflow files from the last commit" \
        "  git commit --amend --no-edit              # rewrite the commit without them" \
        "" \
        "The workflow files will then be in the working tree only — re-trigger the stop hook and the plugin will auto-split them into a preflight PR." \
        "" \
        "Override (NOT recommended): set repair.allow_workflow_in_pr=true in .claude/24hour-ClaudeCode.config.json to skip the split.")
      emit_block "$msg"
    fi

    # Pass the workflow file list explicitly to the splitter for determinism.
    workflow_list=$(echo "$changes_json" | jq -r '.buckets.workflow[]')
    preflight_num=$(echo "$workflow_list" | bash "$SCRIPTS/split-workflow-pr.sh" 2>/tmp/split-workflow-err.$$)
    split_exit=$?
    err_log=$(cat /tmp/split-workflow-err.$$ 2>/dev/null || echo "")
    rm -f /tmp/split-workflow-err.$$ 2>/dev/null

    if (( split_exit != 0 )) || [[ -z "$preflight_num" ]]; then
      record_event "failed:split_workflow" "exit=$split_exit detail=${err_log:0:200}"
      msg=$(printf '%s\n' \
        "Auto-split of workflow file changes into a preflight PR failed." \
        "" \
        "Detail:" \
        "$err_log" \
        "" \
        "Either fix the underlying issue (gh auth, branch state, network) or set repair.allow_workflow_in_pr=true in .claude/24hour-ClaudeCode.config.json to bundle workflow + code in a single PR (auto-review will fail; manual review required).")
      emit_block "$msg"
    fi

    state_set mode "waiting_for_preflight_merge"
    state_set preflight_pr "$preflight_num"
    rm -f "$RUNTIME_DIR/dirty" 2>/dev/null
    record_event "preflight_opened" "pr=$preflight_num"
    msg=$(printf '%s\n' \
      "<24hour-ClaudeCode>" \
      "📦 Workflow file changes were auto-split into preflight PR #$preflight_num." \
      "" \
      "Why: GitHub refuses to auth the auto-review (HTTP 401) when a PR modifies .github/workflows/*.yml. Splitting them off lets the main branch's PR have a clean diff." \
      "" \
      "Auto-merge is enabled on the preflight PR; the main loop will resume once it merges." \
      "" \
      "Your remaining (non-workflow) edits stay in the working tree and will be committed on the next stop after the preflight merges.")
    emit_info "$msg"
  fi

  danger_count=$(echo "$changes_json" | jq -r '.danger_hit | length')
  if (( danger_count > 0 )); then
    hit_list=$(echo "$changes_json" | jq -r '.danger_hit | join(", ")')
    record_event "stop:danger_path" "$hit_list"
    msg=$(printf '%s\n' \
      "Edit touches sensitive (danger_paths) file(s):" \
      "  $hit_list" \
      "" \
      "I won't auto-commit changes to these paths. Either:" \
      "  1. Revert the change and skip these paths, OR" \
      "  2. Get explicit user approval, then run /24hour-ClaudeCode:disable, make the edit manually, then re-enable.")
    emit_block "$msg"
  fi

  # Stop conditions (max_iter, branch protection, gh auth, diff size).
  stop_token=$(bash "$SCRIPTS/check-stop-conditions.sh" 2>/dev/null || true)
  [[ -n "$stop_token" ]] || stop_token="continue"
  if [[ "$stop_token" != "continue" ]]; then
    record_event "$stop_token" "from check-stop-conditions"
    msg=$(printf '%s\n' \
      "STOP condition: $stop_token" \
      "" \
      "Invoke the failure-escalation skill to format an escalation message.")
    emit_info "<24hour-ClaudeCode> $msg"
  fi

  # Run config.checks.commands.
  if [[ -f "$CONFIG_FILE" ]]; then
    run_local=$(jq -r '.checks.run_local_tests // false' "$CONFIG_FILE")
    if [[ "$run_local" == "true" ]]; then
      cmds=$(jq -r '.checks.commands[]?' "$CONFIG_FILE")
      while IFS= read -r cmd; do
        [[ -z "$cmd" ]] && continue
        log=$(bash -c "$cmd" 2>&1) || {
          tail50=$(printf '%s\n' "$log" | tail -50)
          record_event "failed:$cmd" "$tail50"
          fail_msg=$(printf '%s\n' \
            "Local check failed: $cmd" \
            "" \
            "Last 50 lines:" \
            "$tail50" \
            "" \
            "Fix the issue and the next stop will retry automatically.")
          emit_block "$fail_msg"
        }
      done <<< "$cmds"
    fi
  fi

  # Auto-commit.
  commit_sha=$(bash "$SCRIPTS/auto-commit.sh" 2>&1)
  commit_exit=$?
  if (( commit_exit != 0 )); then
    record_event "failed:auto-commit" "exit=$commit_exit"
    emit_block "auto-commit failed (exit=$commit_exit): $commit_sha. Investigate (likely protected branch, hook reject, or git config issue)."
  fi

  # Push.
  branch=$(git branch --show-current 2>/dev/null || echo "")
  push_log=$(git push -u origin "$branch" 2>&1) || {
    record_event "failed:push" "$push_log"
    emit_block "git push failed: $push_log. Likely non-fast-forward — investigate."
  }

  # Ensure PR.
  pr_num=$(bash "$SCRIPTS/ensure-pr.sh" 2>&1)
  pr_exit=$?
  if (( pr_exit != 0 )); then
    record_event "failed:ensure-pr" "exit=$pr_exit detail=$pr_num"
    emit_block "ensure-pr failed (exit=$pr_exit): $pr_num. Check gh pr create permissions and base branch."
  fi

  # The review loop operates on a ready PR. Existing draft PRs are promoted
  # before waiting so GitHub review and merge gates behave consistently.
  gh pr ready "$pr_num" >/dev/null 2>&1 || true
  refresh_current_pr_file "$pr_num"

  # Iteration: increment if this is a rework push (mode was ready_for_rework).
  if [[ "$mode" == "ready_for_rework" ]]; then
    new_iter=$(bash "$SCRIPTS/runtime-state.sh" incr iteration 2>/dev/null || echo "?")
  else
    state_set iteration 1
    new_iter=1
  fi
  state_set round "$new_iter"
  max_rounds=5
  [[ -f "$CONFIG_FILE" ]] && max_rounds=$(jq -r '.repair.max_iterations // 5' "$CONFIG_FILE" 2>/dev/null || echo 5)
  state_set max_rounds "$max_rounds"

  state_set pr_number "$pr_num"
  state_set branch "$branch"
  state_set current_head_sha "$(git rev-parse HEAD 2>/dev/null || echo "$commit_sha")"
  rm -f "$RUNTIME_DIR/dirty" 2>/dev/null

  pr_url=""
  [[ -f "$RUNTIME_DIR/current-pr.json" ]] && pr_url=$(jq -r '.url // ""' "$RUNTIME_DIR/current-pr.json")

  # Review-skippable PR detection.
  #
  # The rendered review workflows have `paths-ignore: ["**.md", "**/CHANGELOG*",
  # "**/*.lock", ...]`, so PRs whose every changed file is in docs / lock /
  # trivial buckets get NO review run — the action is filtered before launch.
  # Without this short-circuit, the loop transitions to mode=waiting_for_review
  # and then safely stops because no review workflow will ever fire. For
  # doc-only PRs the right move is to enable
  # auto-merge directly and skip the waiting state.
  code_n=$(echo "$changes_json" | jq -r '.buckets.code | length')
  workflow_n=$(echo "$changes_json" | jq -r '.buckets.workflow | length')
  danger_n=$(echo "$changes_json" | jq -r '.buckets.danger | length')
  secrets_n=$(echo "$changes_json" | jq -r '.buckets.secrets | length')

  if (( code_n == 0 )) && (( workflow_n == 0 )) && (( danger_n == 0 )) && (( secrets_n == 0 )); then
    # docs / lock / trivial only — review will be skipped by paths-ignore.
    # Mark ready (if it was a draft) and enable auto-merge.
    merge_method="merge"
    [[ -f "$CONFIG_FILE" ]] && merge_method=$(jq -r '.github.merge_method // "merge"' "$CONFIG_FILE")

    gh pr ready "$pr_num" >/dev/null 2>&1 || true   # noop if already ready
    merge_out=$(gh pr merge "$pr_num" --auto "--$merge_method" 2>&1) || {
      # --auto requires that some condition gate the merge (branch protection rules).
      # If there are no required checks, try a direct merge.
      merge_out=$(gh pr merge "$pr_num" "--$merge_method" 2>&1) || {
        record_event "failed:merge-skip-review" "pr=$pr_num detail=$merge_out"
        state_set mode "waiting_for_review"
        state_set last_status "committed"
        record_event "committed" "iter=$new_iter sha=$commit_sha pr=$pr_num (merge-skip attempt failed; falling back)"
        emit_info "$(printf '%s\n' \
          "<24hour-ClaudeCode>" \
          "PR #$pr_num is docs/lock/trivial only — tried to skip review and merge directly, but gh pr merge failed:" \
          "$merge_out" \
          "Falling back to the regular waiting_for_review loop. Investigate the merge error.")"
      }
    }

    state_set mode "merged"
    state_set last_status "merged_no_review"
    record_event "merged" "pr=$pr_num path=docs_only"
    emit_info "$(printf '%s\n' \
      "<24hour-ClaudeCode>" \
      "✅ PR #$pr_num is docs/lock/trivial only — review skipped via paths-ignore." \
      "$pr_url" \
      "Auto-merge enabled (or merged directly). Cleanup happens on next stop.")"
  fi

  # Regular path: real code changes — synchronously wait for current-SHA CI and review.
  bash "$SCRIPTS/poll-github.sh" >/dev/null 2>&1 || true
  state_set mode "waiting_for_review"
  state_set last_status "committed"
  record_event "committed" "iter=$new_iter sha=$commit_sha pr=$pr_num"
  handle_waiting_for_review
fi

# Fallthrough — should not reach here.
record_event "unhandled" "mode=$mode dirty=$dirty diff=$diff_nonempty"
exit 0
