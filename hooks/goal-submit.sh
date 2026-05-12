#!/usr/bin/env bash
# goal-submit.sh — Arm a safe shipping gate when users start Claude Code /goal.

set -uo pipefail

INPUT="$(cat || true)"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
RUNTIME_DIR="$PROJECT_DIR/.claude/runtime/24hour-ClaudeCode"
GOAL_GUARD_FILE="$RUNTIME_DIR/goal-guard.json"
GOAL_GUARD_CLEARED_FILE="$RUNTIME_DIR/goal-guard-cleared.json"
MARKER='<24hour-ClaudeCode-goal-complete ready-to-ship="true" />'

mkdir -p "$RUNTIME_DIR"
[[ ! -f "$RUNTIME_DIR/.gitignore" ]] && echo '*' > "$RUNTIME_DIR/.gitignore" 2>/dev/null || true

json_field() {
  local field="$1"
  printf '%s' "$INPUT" | jq -r "$field // \"\"" 2>/dev/null || echo ""
}

command_name=$(json_field '.command_name')
command_args=$(json_field '.command_args')
user_prompt=$(json_field '.user_prompt')
[[ -z "$user_prompt" ]] && user_prompt=$(json_field '.prompt')

emit_context() {
  local ctx="$1"
  jq -n --arg ctx "$ctx" \
    '{hookSpecificOutput:{hookEventName:"UserPromptSubmit",additionalContext:$ctx}}'
}

extract_tag() {
  local tag="$1" text="$2"
  local open="<${tag}>" close="</${tag}>" rest
  rest="${text#*"$open"}"
  [[ "$rest" == "$text" ]] && return 0
  printf '%s' "${rest%%"$close"*}"
}

# Claude Code slash-command transcripts render /goal as XML-like command text,
# while UserPromptSubmit hooks may receive either the raw prompt or fields.
if [[ -z "$command_name" ]]; then
  command_name=$(extract_tag "command-name" "$user_prompt")
fi
if [[ -z "$command_args" ]]; then
  command_args=$(extract_tag "command-args" "$user_prompt")
fi

if [[ "$command_name" != "goal" && "$command_name" != "/goal" ]]; then
  if [[ "$user_prompt" == /goal* ]]; then
    command_name="/goal"
    command_args="${user_prompt#/goal}"
  else
    exit 0
  fi
fi

trimmed_args=$(printf '%s' "$command_args" | awk '{$1=$1; print}')
case "$trimmed_args" in
  "" )
    exit 0
    ;;
  clear|stop|off|reset|none|cancel )
    rm -f "$GOAL_GUARD_FILE" 2>/dev/null || true
    now=$(date -u +%FT%TZ)
    jq -n --arg ts "$now" '{cleared_at:$ts}' > "$GOAL_GUARD_CLEARED_FILE" 2>/dev/null || true
    emit_context "[24hour-ClaudeCode] Goal guard cleared. The auto-PR Stop hook may ship future diffs normally."
    exit 0
    ;;
esac

now=$(date -u +%FT%TZ)
tmp=$(mktemp)
jq -n --arg goal "$command_args" --arg marker "$MARKER" --arg ts "$now" \
  '{active:true, goal:$goal, marker:$marker, armed_at:$ts, source:"UserPromptSubmit"}' > "$tmp"
mv "$tmp" "$GOAL_GUARD_FILE"
rm -f "$GOAL_GUARD_CLEARED_FILE" 2>/dev/null || true

emit_context "$(cat <<EOF
[24hour-ClaudeCode Goal Guard]
The 24hour-ClaudeCode auto-PR hook is armed for this /goal.

Do not let 24hour-ClaudeCode commit, push, open a PR, or merge while the goal is still in progress.

When, and only when, the /goal condition is satisfied and the current WorkTree is ready to ship, include this exact line as a standalone line at the end of your final assistant message:

$MARKER

Do not place the marker in a code block, quote, explanation, progress update, partial summary, or message that still leaves verification or edits outstanding. If the goal is not complete, continue working normally; the Stop hook will hold shipping while this marker is absent.
EOF
)"
