#!/usr/bin/env bash
# bootstrap.sh — SessionStart hook for 24hour-ClaudeCode plugin.
#
# Fires on session startup, /clear, and auto-compact.
#
# Detects environment health and emits one of three context payloads:
#   1. Onboarding needed (Actions missing / config missing / gh not authed)
#      → quote skills/github-actions-onboarding/SKILL.md as a directive
#   2. Not in a worktree, OR on a protected branch
#      → emit a one-line dormant note
#   3. Healthy
#      → quote skills/using-24hour-ClaudeCode/SKILL.md as the runtime contract
#
# Reads no stdin in practice (Claude Code passes hook input JSON, but we don't need it).
# Writes JSON to stdout: {"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"..."}}
# Exits 0 always (a non-zero exit would block the session, which we don't want).

set -uo pipefail   # NOT -e: detection failures are normal; we always exit 0

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
# Resolve config path — local first, falling back to main checkout when inside
# a worktree, so worktrees inherit main's onboarded config without re-onboarding.
CONFIG_FILE=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$PLUGIN_ROOT/scripts/resolve-config-path.sh" 2>/dev/null || echo "$PROJECT_DIR/.claude/24hour-ClaudeCode.config.json")

# ---- Helper: emit additionalContext JSON and exit ----
emit() {
  local content="$1"
  # Use jq -n to safely escape arbitrary text into a JSON string.
  if command -v jq >/dev/null 2>&1; then
    jq -n --arg ctx "$content" \
      '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$ctx}}'
  else
    # Fallback: very basic escaping. jq should be present, but be safe.
    local escaped
    escaped=$(printf '%s' "$content" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' 2>/dev/null)
    if [[ -n "$escaped" ]]; then
      printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":%s}}\n' "$escaped"
    else
      # Last-resort fallback: emit empty additionalContext
      printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":""}}\n'
    fi
  fi
  exit 0
}

# ---- 0. If config explicitly disabled, dormant ----
if [[ -f "$CONFIG_FILE" ]]; then
  enabled=$(jq -r '.enabled // true' "$CONFIG_FILE" 2>/dev/null || echo "true")
  if [[ "$enabled" == "false" ]]; then
    emit "[24hour-ClaudeCode] Runtime is disabled for this project ($CONFIG_FILE has enabled=false). The Stop hook will not auto-commit or open PRs. Re-enable with /24hour-ClaudeCode:enable."
  fi
fi

# ---- 1. Detect environment ----
# In a worktree, --git-dir points to <main>/.git/worktrees/<name>, while
# --git-common-dir points to <main>/.git. They're equal in the main checkout.
in_worktree=0
if cd "$PROJECT_DIR" 2>/dev/null; then
  git_dir=$(git rev-parse --git-dir 2>/dev/null || echo "")
  git_common=$(git rev-parse --git-common-dir 2>/dev/null || echo "")
  if [[ -n "$git_dir" && -n "$git_common" && "$git_dir" != "$git_common" ]]; then
    in_worktree=1
  fi
fi

# Protected branch check (uses real GitHub branch protection when available;
# falls back to hardcoded list when offline)
protected=0
if (( in_worktree == 1 )); then
  branch=$(git -C "$PROJECT_DIR" branch --show-current 2>/dev/null || echo "")
  if [[ -n "$branch" ]]; then
    helper="$PLUGIN_ROOT/scripts/is-protected-branch.sh"
    if [[ -x "$helper" ]]; then
      [[ "$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$helper" "$branch" 2>/dev/null)" == "true" ]] && protected=1
    else
      # Defense: if helper missing, use hardcoded list
      case "$branch" in
        main|master|develop|dev|staging|production|release|prod) protected=1 ;;
        release/*|hotfix/*) protected=1 ;;
      esac
    fi
  fi
fi

gh_ok=0
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  gh_ok=1
fi

actions_deployed=0
if compgen -G "$PROJECT_DIR/.github/workflows/claude*.yml" >/dev/null 2>&1 \
   || compgen -G "$PROJECT_DIR/.github/workflows/codex*.yml" >/dev/null 2>&1; then
  actions_deployed=1
fi

config_present=0
if [[ -f "$CONFIG_FILE" ]]; then
  config_present=1
fi

# ---- 2. Decide which payload to emit ----
#
# Decision order matters. Onboarding check runs FIRST (before worktree/protected
# dormant exits), because setup happens on the main checkout — workflow YAMLs
# need to live on the default branch before GitHub Actions can authorize tokens.
# If we exited dormant on a non-worktree main checkout, a new user with no
# onboarding done would never be told to run `/24hour-ClaudeCode:setup`.

# Branch A: onboarding incomplete → quote onboarding skill (context-aware)
if (( gh_ok == 0 )) || (( actions_deployed == 0 )) || (( config_present == 0 )); then
  missing=()
  (( gh_ok == 0 )) && missing+=("gh CLI not authenticated (run: gh auth login)")
  (( actions_deployed == 0 )) && missing+=("no .github/workflows/claude*.yml in this repo")
  (( config_present == 0 )) && missing+=(".claude/24hour-ClaudeCode.config.json missing")

  onboarding_md="$PLUGIN_ROOT/skills/github-actions-onboarding/SKILL.md"
  if [[ -f "$onboarding_md" ]]; then
    onboarding_body=$(cat "$onboarding_md")
  else
    onboarding_body="(Onboarding skill not yet installed; see plugin scripts/configure-actions.sh.)"
  fi

  # Context-aware location hint: setup must run on main checkout so workflow
  # YAMLs land on the default branch first. Tell the user where they are and
  # what to do next.
  if (( in_worktree == 1 )); then
    location_hint="You are currently inside a git worktree. Setup should be run from the **main checkout** so the workflow YAMLs are committed directly to the default branch (GitHub Actions can't authorize tokens until \`.github/workflows/claude*.yml\` exists on the default branch). Switch to your main checkout and run \`/24hour-ClaudeCode:setup\` there. If you must onboard from this worktree, your first PR will carry the workflow YAML changes and the runtime will auto-split them into a preflight PR — extra round-trip but it works."
  else
    location_hint="You are on the main checkout — this is the correct place to run setup. Run \`/24hour-ClaudeCode:setup\` now to complete onboarding before creating any worktree."
  fi

  payload=$(cat <<EOF
<EXTREMELY-IMPORTANT>
The 24hour-ClaudeCode plugin is installed but onboarding is incomplete.

Missing:
$(printf '  - %s\n' "${missing[@]}")

$location_hint

Do NOT proceed with any code edit until onboarding is complete.
</EXTREMELY-IMPORTANT>

$onboarding_body
EOF
)
  emit "$payload"
fi

# Branch B: onboarded but not in a worktree → dormant
if (( in_worktree == 0 )); then
  emit "[24hour-ClaudeCode] Dormant: not running inside a git worktree. The runtime engages only when you enter a worktree (\`git worktree add ../my-feature -b feat/my-feature\`)."
fi

# Branch C: protected branch → dormant
if (( protected == 1 )); then
  emit "[24hour-ClaudeCode] Dormant: current branch is protected (\`$branch\`). The runtime refuses to push to protected branches. Switch to a feature branch (\`git switch -c feat/...\`) before editing."
fi

# Branch D: healthy → quote the runtime contract
runtime_md="$PLUGIN_ROOT/skills/using-24hour-ClaudeCode/SKILL.md"
if [[ ! -f "$runtime_md" ]]; then
  emit "[24hour-ClaudeCode] WARNING: runtime contract skill missing at $runtime_md. Plugin install is incomplete."
fi

runtime_body=$(cat "$runtime_md")

# Initialize runtime state directory if absent
runtime_dir="$PROJECT_DIR/.claude/runtime/24hour-ClaudeCode"
mkdir -p "$runtime_dir" 2>/dev/null || true

# Write a gitignore inside the runtime dir so it never leaks into diffs
[[ ! -f "$runtime_dir/.gitignore" ]] && echo '*' > "$runtime_dir/.gitignore" 2>/dev/null

state_file="$runtime_dir/state.json"
if [[ ! -f "$state_file" ]]; then
  branch=$(git -C "$PROJECT_DIR" branch --show-current 2>/dev/null || echo "")
  worktree_path="$PROJECT_DIR"
  repo_nwo=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || echo "")
  jq -n --arg repo "$repo_nwo" --arg wt "$worktree_path" --arg br "$branch" \
     '{enabled:true, repo:$repo, worktree:$wt, branch:$br, pr_number:null, iteration:0, max_iterations:5, mode:"idle", last_status:"ready"}' \
     > "$state_file" 2>/dev/null || true
fi

payload=$(cat <<EOF
<EXTREMELY-IMPORTANT>
The 24hour-ClaudeCode auto-PR-loop runtime is ACTIVE in this worktree.

Read the runtime contract below. Prefer Claude Code /goal mode for feature work. The Stop hook owns commit, push, PR creation, current-SHA review waiting, rework feedback, and auto-merge. Do not manually commit, push, or open PRs unless the hook explicitly stops and asks for human action.

Repo: ${repo_nwo:-<unknown>}
Branch: ${branch:-<unknown>}
Worktree: $PROJECT_DIR
</EXTREMELY-IMPORTANT>

$runtime_body
EOF
)
emit "$payload"
