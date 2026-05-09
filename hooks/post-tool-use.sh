#!/usr/bin/env bash
# post-tool-use.sh — PostToolUse hook (light marker for 24hour-ClaudeCode plugin).
#
# Fires after every Edit | Write | MultiEdit. Records that a code-modifying tool
# was used this turn so the Stop hook has a fast-path hint. Does no heavy work.
#
# The dirty flag is cleared by stop.sh after a successful commit cycle.
# (`git diff --quiet` remains the source of truth; the marker is just an optimization.)

set -euo pipefail
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
RUNTIME_DIR="$PROJECT_DIR/.claude/runtime/24hour-ClaudeCode"
mkdir -p "$RUNTIME_DIR"
[[ -f "$RUNTIME_DIR/dirty" ]] || touch "$RUNTIME_DIR/dirty"
exit 0
