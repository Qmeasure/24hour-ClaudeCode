#!/usr/bin/env bash
# check-stop-conditions.sh — Read runtime state + config, decide stop/continue.
#
# Output: a single token on stdout, exit code matching:
#   continue                          exit 0
#   stop:max_iterations               exit 10
#   stop:repeated_failure             exit 11
#   stop:protected_branch             exit 12
#   stop:gh_auth_lost                 exit 13
#   stop:push_rejected                exit 14
#   stop:user_judgement               exit 15
#   stop:danger_path                  exit 17
#   stop:preflight_closed             exit 18  (raised by stop.sh, not here — reserved)
#   stop:committed_workflow_changes   exit 19  (raised by stop.sh, not here — reserved)
#
# The babysit/failure-escalation skill reads stdout to decide messaging.
#
# Required env: CLAUDE_PROJECT_DIR.

set -euo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
RUNTIME_DIR="$PROJECT_DIR/.claude/runtime/24hour-ClaudeCode"
STATE_FILE="$RUNTIME_DIR/state.json"
# Resolve config — worktree inherits main checkout's onboarded config.
SCRIPT_DIR_FOR_CONFIG="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$SCRIPT_DIR_FOR_CONFIG/resolve-config-path.sh" 2>/dev/null || echo "$PROJECT_DIR/.claude/24hour-ClaudeCode.config.json")

cd "$PROJECT_DIR"

# Default config values
max_iterations=5
stop_on_repeated_failure="true"

if [[ -f "$CONFIG_FILE" ]]; then
  max_iterations=$(jq -r '.repair.max_iterations // 5' "$CONFIG_FILE")
  stop_on_repeated_failure=$(jq -r '.repair.stop_on_repeated_failure // true' "$CONFIG_FILE")
fi

iteration=0
last_status=""
if [[ -f "$STATE_FILE" ]]; then
  iteration=$(jq -r '.iteration // 0' "$STATE_FILE")
  last_status=$(jq -r '.last_status // ""' "$STATE_FILE")
fi

# 1. Max iterations
if (( iteration >= max_iterations )); then
  echo "stop:max_iterations"
  exit 10
fi

# 2. Repeated failure (heuristic: last_status starts with "failed:" twice in last_run history)
if [[ "$stop_on_repeated_failure" == "true" ]] && [[ -f "$RUNTIME_DIR/last-run.json" ]]; then
  fail_streak=$(jq -r '.fail_streak // 0' "$RUNTIME_DIR/last-run.json" 2>/dev/null || echo 0)
  if (( fail_streak >= 2 )); then
    echo "stop:repeated_failure"
    exit 11
  fi
fi

# 3. Protected branch (real GitHub protection + hardcoded fallback)
branch=$(git branch --show-current 2>/dev/null || echo "")
if [[ -n "$branch" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  helper="$SCRIPT_DIR/is-protected-branch.sh"
  is_protected="false"
  if [[ -x "$helper" ]]; then
    is_protected=$(bash "$helper" "$branch" 2>/dev/null || echo "false")
  else
    case "$branch" in
      main|master|develop|dev|staging|production|release|prod|release/*|hotfix/*) is_protected="true" ;;
    esac
  fi
  if [[ "$is_protected" == "true" ]]; then
    echo "stop:protected_branch"
    exit 12
  fi
fi

# 4. gh auth
if ! gh auth status >/dev/null 2>&1; then
  echo "stop:gh_auth_lost"
  exit 13
fi

echo "continue"
exit 0
