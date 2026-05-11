#!/usr/bin/env bash
# detect-changes.sh — Inspect the working tree for unstaged + staged changes
# and classify each path. Emits JSON.
#
# Output schema:
#   {
#     "has_changes": true|false,
#     "files": ["<path1>", "<path2>", ...],
#     "buckets": {
#       "code":     [...],
#       "lock":     [...],   # package-lock.json, pnpm-lock.yaml, Cargo.lock, etc.
#       "docs":     [...],   # *.md, *.rst, *.txt
#       "secrets":  [...],   # .env*, credentials/, **/secrets/**
#       "workflow": [...],   # .github/workflows/**
#       "trivial":  [...],   # .gitignore — too small to justify a PR/CI round-trip
#       "danger":   [...]    # paths matching config.danger_paths globs
#     },
#     "danger_hit": ["<path>", ...]   # convenience: same as buckets.danger + buckets.secrets
#   }
#
# Note on `trivial`: callers (e.g. stop.sh) should skip the whole commit/push/PR
# pipeline when every changed file is trivial. Trivial files are STILL staged
# and committed when they ride along with non-trivial changes — the bucket only
# affects the "should we even start this round?" decision, not what gets staged.
#
# Reads config danger_paths from $CLAUDE_PROJECT_DIR/.claude/24hour-ClaudeCode.config.json
# (falls back to skill default if config missing).

set -euo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
# Resolve config — worktree inherits main checkout's onboarded config.
SCRIPT_DIR_FOR_CONFIG="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$SCRIPT_DIR_FOR_CONFIG/resolve-config-path.sh" 2>/dev/null || echo "$PROJECT_DIR/.claude/24hour-ClaudeCode.config.json")

cd "$PROJECT_DIR"

# Pull the current diff. Use --diff-filter=ACMR to skip deletions+copies in surface,
# but still include them in the file list so we can warn about secret deletions.
files=$(git status --porcelain 2>/dev/null | awk '{ sub(/^...?/,""); print }' | sort -u)

if [[ -z "$files" ]]; then
  jq -n '{has_changes:false, files:[], buckets:{code:[],lock:[],docs:[],secrets:[],workflow:[],trivial:[],danger:[]}, danger_hit:[]}'
  exit 0
fi

# Default danger paths (used if config missing)
default_danger='["migrations/**","db/migrations/**","alembic/versions/**","prisma/migrations/**","prisma/schema.prisma","infra/**","terraform/**","k8s/**","helm/**",".env.production","**/secrets/**","**/credentials/**"]'

if [[ -f "$CONFIG_FILE" ]]; then
  danger_globs=$(jq -c '.danger_paths // '"$default_danger" "$CONFIG_FILE")
else
  danger_globs="$default_danger"
fi

# Classify each file
classify() {
  local path="$1"
  case "$path" in
    *.lock|package-lock.json|pnpm-lock.yaml|yarn.lock|bun.lockb|Cargo.lock|Pipfile.lock|poetry.lock|go.sum|composer.lock)
      echo lock ;;
    *.md|*.rst|*.txt|CHANGELOG*|LICENSE|NOTICE)
      echo docs ;;
    .env|.env.*|*.pem|*.key|*.crt|*.p12|*.keystore)
      echo secrets ;;
    .github/workflows/*)
      echo workflow ;;
    .gitignore|*/.gitignore)
      echo trivial ;;
    *)
      echo code ;;
  esac
}

# Glob match — bash extglob + path = glob substring
match_danger() {
  local path="$1"
  echo "$danger_globs" | jq -r '.[]' | while read -r glob; do
    # Convert ** to .* and * to [^/]* for regex match
    pattern=$(printf '%s' "$glob" | sed -e 's/\./\\./g' -e 's/\*\*/§§§§/g' -e 's/\*/[^\/]*/g' -e 's/§§§§/.*/g')
    if [[ "$path" =~ ^${pattern}$ ]]; then
      echo "$path"
      return 0
    fi
  done
}

# Build the buckets
code_arr='[]'
lock_arr='[]'
docs_arr='[]'
secrets_arr='[]'
workflow_arr='[]'
trivial_arr='[]'
danger_arr='[]'

while IFS= read -r path; do
  [[ -z "$path" ]] && continue
  bucket=$(classify "$path")

  case "$bucket" in
    code)     code_arr=$(echo "$code_arr"     | jq --arg p "$path" '. + [$p]') ;;
    lock)     lock_arr=$(echo "$lock_arr"     | jq --arg p "$path" '. + [$p]') ;;
    docs)     docs_arr=$(echo "$docs_arr"     | jq --arg p "$path" '. + [$p]') ;;
    secrets)  secrets_arr=$(echo "$secrets_arr"   | jq --arg p "$path" '. + [$p]') ;;
    workflow) workflow_arr=$(echo "$workflow_arr" | jq --arg p "$path" '. + [$p]') ;;
    trivial)  trivial_arr=$(echo "$trivial_arr"  | jq --arg p "$path" '. + [$p]') ;;
  esac

  # Check danger_paths separately (orthogonal to bucket)
  if [[ -n "$(match_danger "$path" 2>/dev/null)" ]]; then
    danger_arr=$(echo "$danger_arr" | jq --arg p "$path" '. + [$p]')
  fi
done <<< "$files"

# danger_hit = secrets ∪ danger
danger_hit=$(jq -n --argjson s "$secrets_arr" --argjson d "$danger_arr" '$s + $d | unique')

files_arr=$(printf '%s\n' "$files" | jq -R . | jq -s .)

jq -n \
  --argjson files "$files_arr" \
  --argjson code "$code_arr" --argjson lock "$lock_arr" \
  --argjson docs "$docs_arr" --argjson secrets "$secrets_arr" \
  --argjson workflow "$workflow_arr" --argjson trivial "$trivial_arr" \
  --argjson danger "$danger_arr" \
  --argjson hit "$danger_hit" \
  '{
    has_changes: ($files | length > 0),
    files: $files,
    buckets: {code:$code, lock:$lock, docs:$docs, secrets:$secrets, workflow:$workflow, trivial:$trivial, danger:$danger},
    danger_hit: $hit
  }'
