#!/usr/bin/env bash
# stop.sh — Stop hook for 24hour-ClaudeCode plugin (Revision 2).
#
# Fires when Claude finishes a turn. This is the heavy worker — owns the
# auto-commit pipeline AND the post-PR poll/decide loop.
#
# Two output formats per the official Stop hook spec:
#   1. {"hookSpecificOutput":{"hookEventName":"Stop","additionalContext":"<text>"}}
#      Informational; Claude is allowed to stop.
#   2. {"decision":"block","reason":"<text>"}
#      Forces Claude NOT to stop; reason is fed back as context — the rework loop.
#
# Mode-aware. state.json's `mode` field drives the dispatch:
#   - idle: no PR, no in-flight work. If diff non-empty → enter pre-PR commit/push flow.
#   - waiting_for_preflight_merge: a workflow-only "preflight" PR was auto-split
#     and is in flight. Poll its state; on merged, rebase + fall through to idle.
#   - waiting_for_checks: PR exists, just pushed → poll/wait for CI, decide.
#   - ready_for_rework: previous round flagged rework. If diff non-empty → enter pre-PR
#     flow with iteration++ semantics.
#   - merged: cleanup pass.
#
# Required env (Claude Code provides): CLAUDE_PLUGIN_ROOT, CLAUDE_PROJECT_DIR.
# Required tools: jq, gh, git.

set -uo pipefail   # NOT -e: pipeline failures are handled per-step; we always exit 0

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
SCRIPTS="$PLUGIN_ROOT/scripts"
RUNTIME_DIR="$PROJECT_DIR/.claude/runtime/24hour-ClaudeCode"
# Resolve config — local first, main checkout fallback (so worktrees inherit main's onboarded config).
CONFIG_FILE=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$SCRIPTS/resolve-config-path.sh" 2>/dev/null || echo "$PROJECT_DIR/.claude/24hour-ClaudeCode.config.json")

mkdir -p "$RUNTIME_DIR"
cd "$PROJECT_DIR"

# ============================================================================
# Helpers
# ============================================================================

# Emit additionalContext (informational) and exit 0.
emit_info() {
  local content="$1"
  jq -n --arg ctx "$content" \
    '{hookSpecificOutput:{hookEventName:"Stop",additionalContext:$ctx}}'
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
  if [[ "$status" == failed:* ]] || [[ "$status" == rework* ]]; then
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
  rm -f "$RUNTIME_DIR/current-pr.json" "$RUNTIME_DIR/feedback.json" "$RUNTIME_DIR/dirty" 2>/dev/null
  state_set mode "idle"
  state_set iteration 0
  state_set pr_number null
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

# ---- waiting_for_checks: poll/decide ----
if [[ "$mode" == "waiting_for_checks" ]]; then
  pr_num=$(state_get pr_number)
  if [[ -z "$pr_num" || "$pr_num" == "null" ]]; then
    # State drift: mode says waiting but no PR. Recover to idle.
    state_set mode "idle"
    record_event "recovered" "waiting mode without PR; reset to idle"
    exit 0
  fi

  # Poll-and-decide
  wait_seconds=600
  if [[ -f "$CONFIG_FILE" ]]; then
    wait_seconds=$(jq -r '.repair.wait_seconds // 600' "$CONFIG_FILE")
  fi

  bash "$SCRIPTS/wait-for-checks.sh" --pr "$pr_num" --timeout "$wait_seconds" >/dev/null 2>&1
  wait_exit=$?

  if (( wait_exit == 1 )); then
    # Timeout — checks still running.
    # Track consecutive timeouts; escalate after 3 in a row.
    timeouts=$(state_get wait_timeouts)
    [[ -z "$timeouts" || ! "$timeouts" =~ ^[0-9]+$ ]] && timeouts=0
    timeouts=$((timeouts + 1))
    state_set wait_timeouts "$timeouts"
    record_event "wait_timeout" "pr=$pr_num timeout=${wait_seconds}s consecutive=$timeouts"

    if (( timeouts >= 3 )); then
      msg=$(printf '%s\n' \
        "<24hour-ClaudeCode>" \
        "⛔ CI on PR #$pr_num has timed out $timeouts times in a row." \
        "" \
        "The wait window is ${wait_seconds}s but CI is taking longer." \
        "" \
        "Options:" \
        "  1. Wait for CI to finish manually, then run /24hour-ClaudeCode:retry to resume." \
        "  2. Increase repair.wait_seconds in .claude/24hour-ClaudeCode.config.json (default 600)." \
        "  3. Check the PR for a hung job: gh pr checks $pr_num" \
        "" \
        "Invoke failure-escalation skill for the user-facing message.")
      emit_info "$msg"
    fi
    emit_info "<24hour-ClaudeCode> CI for PR #$pr_num is still running ($timeouts consecutive timeouts). Will check feedback on next stop."
  fi

  if (( wait_exit != 0 )); then
    # gh error or other.
    record_event "wait_error" "pr=$pr_num exit=$wait_exit"
    emit_info "<24hour-ClaudeCode> Could not poll PR #$pr_num (gh error). Will retry on next stop."
  fi

  # Reset wait_timeouts on successful poll progression
  state_set wait_timeouts 0

  # Checks complete — full poll
  bash "$SCRIPTS/poll-github.sh" >/dev/null 2>&1 || true

  # Decide
  decision_output=$(bash "$SCRIPTS/decide-feedback.sh" 2>/dev/null)
  token=$(echo "$decision_output" | jq -r '.token // "inconclusive"')
  reason=$(echo "$decision_output" | jq -r '.reason // ""')

  case "$token" in
    feedback_good)
      pr_url=$(jq -r '.url // ""' "$RUNTIME_DIR/current-pr.json" 2>/dev/null || echo "")
      merge_method="merge"
      [[ -f "$CONFIG_FILE" ]] && merge_method=$(jq -r '.github.merge_method // "merge"' "$CONFIG_FILE")
      gh pr merge "$pr_num" --auto "--$merge_method" >/dev/null 2>&1 || {
        record_event "failed:merge" "pr=$pr_num"
        emit_info "<24hour-ClaudeCode> ⚠️ gh pr merge --auto failed for PR #$pr_num. Investigate manually."
      }
      state_set mode "merged"
      record_event "merged" "pr=$pr_num"
      msg=$(printf '%s\n' \
        "<24hour-ClaudeCode>" \
        "✅ PR #$pr_num merged: $pr_url" \
        "" \
        "Cleanup happens on next stop.")
      emit_info "$msg"
      ;;

    rework_required)
      iteration=$(state_get iteration)
      [[ -z "$iteration" ]] && iteration=0
      max_iter=5
      [[ -f "$CONFIG_FILE" ]] && max_iter=$(jq -r '.repair.max_iterations // 5' "$CONFIG_FILE")

      if (( iteration >= max_iter )); then
        record_event "stop:max_iterations" "pr=$pr_num iter=$iteration max=$max_iter"
        msg=$(printf '%s\n' \
          "<24hour-ClaudeCode>" \
          "⛔ STOP: max_iterations ($max_iter) reached on PR #$pr_num." \
          "" \
          "Recent feedback:" \
          "$reason" \
          "" \
          "Invoke failure-escalation skill to format an escalation message for the user.")
        emit_info "$msg"
      fi

      state_set mode "ready_for_rework"
      record_event "rework" "pr=$pr_num iter=$iteration reason=${reason:0:200}"
      block_reason=$(printf '%s\n' \
        "PR #$pr_num feedback requires rework. Iteration $((iteration + 1))/$max_iter." \
        "" \
        "$reason" \
        "" \
        "Apply minimal fixes per the rework-implementation skill. Edit relevant files; the next stop will commit/push/wait/decide automatically.")
      emit_block "$block_reason"
      ;;

    inconclusive)
      record_event "inconclusive" "pr=$pr_num"
      emit_info "<24hour-ClaudeCode> Polled PR #$pr_num but feedback is inconclusive. Will retry on next stop."
      ;;

    stop:*)
      # decide-feedback enforced a hard stop.
      record_event "$token" "pr=$pr_num reason=${reason:0:200}"
      msg=$(printf '%s\n' \
        "<24hour-ClaudeCode>" \
        "⛔ STOP condition: $token" \
        "" \
        "$reason" \
        "" \
        "Invoke failure-escalation skill.")
      emit_info "$msg"
      ;;

    *)
      record_event "decide_unknown" "pr=$pr_num token=$token"
      emit_info "<24hour-ClaudeCode> Unknown decision token '$token' from decide-feedback.sh. Will retry on next stop."
      ;;
  esac
fi

# ---- idle / ready_for_rework: maybe new push ----
if [[ "$mode" == "idle" || "$mode" == "ready_for_rework" ]]; then
  if (( diff_nonempty == 0 && dirty == 0 )); then
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
  stop_token=$(bash "$SCRIPTS/check-stop-conditions.sh" 2>/dev/null || echo "continue")
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

  # Iteration: increment if this is a rework push (mode was ready_for_rework).
  if [[ "$mode" == "ready_for_rework" ]]; then
    new_iter=$(bash "$SCRIPTS/runtime-state.sh" incr iteration 2>/dev/null || echo "?")
  else
    state_set iteration 1
    new_iter=1
  fi

  # Initial poll (best-effort).
  bash "$SCRIPTS/poll-github.sh" >/dev/null 2>&1 || true

  # State transitions.
  state_set mode "waiting_for_checks"
  state_set pr_number "$pr_num"
  state_set last_status "committed"
  rm -f "$RUNTIME_DIR/dirty" 2>/dev/null

  record_event "committed" "iter=$new_iter sha=$commit_sha pr=$pr_num"

  pr_url=""
  [[ -f "$RUNTIME_DIR/current-pr.json" ]] && pr_url=$(jq -r '.url // ""' "$RUNTIME_DIR/current-pr.json")

  msg=$(printf '%s\n' \
    "<24hour-ClaudeCode>" \
    "Iteration #$new_iter" \
    "PR #$pr_num (draft) at $pr_url" \
    "Auto-commit pushed: $commit_sha" \
    "" \
    "CI starting. The next stop will poll checks/reviews and decide auto-merge / rework / wait." \
    "" \
    "If you have additional fixes to make right now, the next stop will batch them. Otherwise, you can stop here.")
  emit_info "$msg"
fi

# Fallthrough — should not reach here.
record_event "unhandled" "mode=$mode dirty=$dirty diff=$diff_nonempty"
exit 0
