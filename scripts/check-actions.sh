#!/usr/bin/env bash
# check-actions.sh — Non-interactive health check of Claude Code Actions config.
#
# Used by the Superset workspace setup hook and by humans for diagnosis.
#
# Checks:
#   1. gh CLI installed and authenticated
#   2. CLAUDE_CODE_OAUTH_TOKEN (or ANTHROPIC_API_KEY) GitHub Secret exists
#   3. .github/workflows/ contains claude*.yml
#   4. Key workflow fields: permissions, oauth-token reference, id-token: write,
#      contents: write (for @claude commits), timeout-minutes, concurrency
#
# Exit codes:
#   0 = all healthy
#   1 = at least one ERROR (config broken — flow won't work)
#   2 = at least one WARNING (works but suboptimal)
#
# Usage:
#   bash scripts/check-actions.sh                  # auto-detect current repo
#   bash scripts/check-actions.sh -R owner/repo    # explicit repo
#   bash scripts/check-actions.sh -v               # verbose (also print OK lines)

set -euo pipefail

REPO=""
VERBOSE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -R|--repo) REPO="$2"; shift 2 ;;
    -v|--verbose) VERBOSE=1; shift ;;
    -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown: $1" >&2; exit 1 ;;
  esac
done

err()  { printf "\033[1;31m✗ ERROR\033[0m %s\n" "$*" >&2; ERR_COUNT=$((ERR_COUNT+1)); }
warn() { printf "\033[1;33m⚠ WARN\033[0m  %s\n" "$*" >&2; WARN_COUNT=$((WARN_COUNT+1)); }
ok()   { (( VERBOSE == 1 )) && printf "\033[1;32m✓ OK\033[0m    %s\n" "$*" || true; }
info() { (( VERBOSE == 1 )) && printf "\033[1;36mℹ\033[0m     %s\n" "$*" || true; }

ERR_COUNT=0
WARN_COUNT=0

# ---- 1. gh CLI ----
if ! command -v gh >/dev/null; then
  err "gh CLI not installed (brew install gh / https://cli.github.com)"
elif ! gh auth status >/dev/null 2>&1; then
  err "gh CLI not authenticated (run: gh auth login)"
else
  ok "gh CLI installed and authenticated"
fi

# ---- 2. Resolve current repo ----
if [[ -z "$REPO" ]]; then
  if ! REPO="$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null)"; then
    err "Current directory is not a GitHub repo and no -R <owner/repo> was given"
    REPO=""
  fi
fi
[[ -n "$REPO" ]] && info "Target repo: $REPO"

# ---- 3. Secret ----
if [[ -n "$REPO" ]]; then
  HAS_OAUTH=0
  HAS_API_KEY=0
  if gh secret list -R "$REPO" 2>/dev/null | grep -q "^CLAUDE_CODE_OAUTH_TOKEN"; then
    HAS_OAUTH=1
  fi
  if gh secret list -R "$REPO" 2>/dev/null | grep -q "^ANTHROPIC_API_KEY"; then
    HAS_API_KEY=1
  fi
  if (( HAS_OAUTH == 0 && HAS_API_KEY == 0 )); then
    err "$REPO is missing CLAUDE_CODE_OAUTH_TOKEN or ANTHROPIC_API_KEY (run scripts/configure-actions.sh)"
  elif (( HAS_OAUTH == 1 && HAS_API_KEY == 1 )); then
    warn "Both OAuth token and API key are configured — Action prefers OAuth (intentional?)"
  else
    ok "Auth secret configured"
  fi
fi

# ---- 4. Workflow files ----
if [[ -d .github/workflows ]]; then
  if ls .github/workflows/claude*.yml >/dev/null 2>&1 || ls .github/workflows/codex*.yml >/dev/null 2>&1; then
    if ls .github/workflows/claude*.yml >/dev/null 2>&1; then
      ok "Found .github/workflows/claude*.yml"
    fi
    if ls .github/workflows/codex*.yml >/dev/null 2>&1; then
      ok "Found .github/workflows/codex*.yml"
    fi
  else
    err ".github/workflows/ is missing claude*.yml AND codex*.yml (run scripts/configure-actions.sh)"
  fi
else
  err ".github/workflows/ does not exist (not at repo root, or workflows not yet written)"
fi

# ---- 5. Workflow content checks ----
if [[ -f .github/workflows/claude.yml ]]; then
  CONTENT="$(cat .github/workflows/claude.yml)"

  if echo "$CONTENT" | grep -qE 'claude_code_oauth_token|anthropic_api_key'; then
    ok "claude.yml references an auth secret"
  else
    err "claude.yml does not reference claude_code_oauth_token or anthropic_api_key"
  fi

  if echo "$CONTENT" | grep -qE 'id-token:\s*write'; then
    ok "claude.yml has id-token: write (OIDC OK)"
  else
    warn "claude.yml is missing id-token: write — may cause OIDC errors"
  fi

  if echo "$CONTENT" | grep -qE 'contents:\s*write'; then
    ok "claude.yml has contents: write (@claude can commit fixes)"
  else
    warn "claude.yml has contents: read — @claude can comment but not commit fixes"
  fi

  if echo "$CONTENT" | grep -qE 'timeout-minutes:'; then
    ok "claude.yml has timeout-minutes set"
  else
    warn "claude.yml has no timeout-minutes — defaults to 6 hours (token-burn risk)"
  fi

  if echo "$CONTENT" | grep -qE '^concurrency:'; then
    ok "claude.yml has concurrency control"
  else
    warn "claude.yml has no concurrency — push storms re-run repeatedly"
  fi
fi

# ---- 5b. Tailored review prompt on default branch ----
# render-workflows.sh writes .claude/24hour-ClaudeCode/review-prompt.md, but
# users have hit a bug where configure-actions.sh's Step 5 forgot to `git add`
# it. The workflow YAMLs read this file at runtime; if it's not on the default
# branch, the runner's checkout doesn't have it and the YAML's one-line fallback
# prompt kicks in — Claude review then loses all project-tailored context.
#
# Three checks:
#   a. Local working-tree existence
#   b. Tracked by git (committed at all)
#   c. Present on default branch on GitHub (the one Action's checkout uses)
if [[ -f .claude/24hour-ClaudeCode/review-prompt.md ]]; then
  if git ls-files --error-unmatch .claude/24hour-ClaudeCode/review-prompt.md >/dev/null 2>&1; then
    ok "review-prompt.md exists locally AND is tracked in git"

    # Also verify it's on the default branch on GitHub (not just a feature branch)
    if [[ -n "$REPO" ]]; then
      default_branch=$(gh repo view "$REPO" --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null || echo "main")
      if gh api "repos/$REPO/contents/.claude/24hour-ClaudeCode/review-prompt.md?ref=$default_branch" >/dev/null 2>&1; then
        ok "review-prompt.md is on default branch ($default_branch) on GitHub"
      else
        err "review-prompt.md is tracked locally but NOT on $default_branch on GitHub — push it (the Action's checkout uses the default branch)"
      fi
    fi
  else
    err ".claude/24hour-ClaudeCode/review-prompt.md exists locally but is NOT in git — run: git add .claude/24hour-ClaudeCode/review-prompt.md && git commit && git push"
  fi
else
  warn ".claude/24hour-ClaudeCode/review-prompt.md not found locally — review will use one-line fallback prompt (no project tailoring). Re-run /24hour-ClaudeCode:setup or scripts/render-workflows.sh to generate."
fi

# ---- 6. Superset env (informational) ----
if [[ -n "${SUPERSET_WORKSPACE_PATH:-}" ]]; then
  info "Superset workspace: ${SUPERSET_WORKSPACE_NAME:-<unnamed>} @ $SUPERSET_WORKSPACE_PATH"
fi

# ---- Summary ----
echo ""
if (( ERR_COUNT > 0 )); then
  printf "\033[1;31m✗ %d ERROR\033[0m, \033[1;33m%d WARN\033[0m — fix with \033[1;36mbash scripts/configure-actions.sh\033[0m\n" "$ERR_COUNT" "$WARN_COUNT"
  exit 1
elif (( WARN_COUNT > 0 )); then
  printf "\033[1;33m⚠ %d WARN\033[0m — works but consider tightening (see SETUP / anti-patterns)\n" "$WARN_COUNT"
  exit 2
else
  printf "\033[1;32m✓ All checks passed\033[0m — Claude Code Actions configured OK\n"
  exit 0
fi
