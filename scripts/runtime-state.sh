#!/usr/bin/env bash
# runtime-state.sh — Atomic read/write helper for <project>/.claude/runtime/24hour-ClaudeCode/state.json.
#
# Subcommands:
#   init               Create state.json with defaults if missing.
#   get <key>          Print state.<key> (jq path, e.g. `iteration`, `current_pr.number`). Empty if absent.
#   set <key> <val>    Set state.<key> to a JSON value (numbers/booleans not quoted; strings auto-quoted).
#   incr <key>         Increment a numeric key (default 0 if missing).
#   show               Print full state.json (or `{}` if missing).
#   path               Print the absolute state.json path.
#
# All writes are atomic (temp + mv) so a crash mid-write doesn't corrupt state.
# Required env: CLAUDE_PROJECT_DIR (or fallback to current cwd).

set -euo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
RUNTIME_DIR="$PROJECT_DIR/.claude/runtime/24hour-ClaudeCode"
STATE_FILE="$RUNTIME_DIR/state.json"

mkdir -p "$RUNTIME_DIR"

err() { printf '✗ %s\n' "$*" >&2; exit 1; }

cmd="${1:-show}"
shift || true

case "$cmd" in
  init)
    # Write a gitignore inside runtime dir so it never leaks into diffs
    [[ ! -f "$RUNTIME_DIR/.gitignore" ]] && echo '*' > "$RUNTIME_DIR/.gitignore" 2>/dev/null
    if [[ -f "$STATE_FILE" ]]; then
      exit 0
    fi
    branch=$(git -C "$PROJECT_DIR" branch --show-current 2>/dev/null || echo "")
    repo_nwo=$(cd "$PROJECT_DIR" && gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || echo "")
    tmp=$(mktemp)
    jq -n --arg repo "$repo_nwo" --arg wt "$PROJECT_DIR" --arg br "$branch" \
       '{enabled:true, repo:$repo, worktree:$wt, branch:$br, pr_number:null, iteration:0, round:0, max_iterations:5, max_rounds:5, mode:"idle", last_status:"ready", current_head_sha:null, last_reviewed_sha:null, last_feedback_hash:null, same_feedback_count:0, wait_started_at:null}' \
       > "$tmp"
    mv "$tmp" "$STATE_FILE"
    ;;

  get)
    [[ $# -ge 1 ]] || err "get requires a <key> argument"
    if [[ -f "$STATE_FILE" ]]; then
      jq -r --arg k "$1" 'getpath($k | split(".")) // empty' "$STATE_FILE" 2>/dev/null || true
    fi
    ;;

  set)
    [[ $# -ge 2 ]] || err "set requires <key> and <value> arguments"
    [[ -f "$STATE_FILE" ]] || err "state.json missing; run \`runtime-state.sh init\` first"
    key="$1"
    val="$2"
    tmp=$(mktemp)
    # Try parsing val as JSON (number/bool/null/object/array); fall back to string.
    if echo "$val" | jq -e . >/dev/null 2>&1; then
      jq --arg k "$key" --argjson v "$val" 'setpath($k | split("."); $v)' "$STATE_FILE" > "$tmp"
    else
      jq --arg k "$key" --arg v "$val" 'setpath($k | split("."); $v)' "$STATE_FILE" > "$tmp"
    fi
    mv "$tmp" "$STATE_FILE"
    ;;

  incr)
    [[ $# -ge 1 ]] || err "incr requires a <key> argument"
    [[ -f "$STATE_FILE" ]] || err "state.json missing; run \`runtime-state.sh init\` first"
    key="$1"
    tmp=$(mktemp)
    jq --arg k "$key" 'getpath($k | split(".")) as $cur | setpath($k | split("."); ($cur // 0) + 1)' \
      "$STATE_FILE" > "$tmp"
    mv "$tmp" "$STATE_FILE"
    jq -r --arg k "$key" 'getpath($k | split("."))' "$STATE_FILE"
    ;;

  show)
    if [[ -f "$STATE_FILE" ]]; then
      cat "$STATE_FILE"
    else
      echo "{}"
    fi
    ;;

  path)
    echo "$STATE_FILE"
    ;;

  *)
    err "Unknown command: $cmd. Valid: init, get, set, incr, show, path"
    ;;
esac
