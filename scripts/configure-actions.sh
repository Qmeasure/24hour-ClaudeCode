#!/usr/bin/env bash
# configure-actions.sh — Interactive one-time deploy of Claude Code Actions.
#
# Run once per new repo. Afterward every Superset workspace runs check-actions.sh
# automatically; you don't re-run this.
#
# What this script does (Steps 0-7):
#   0. Verify prerequisites (gh, claude, git, gh login + workflow scope)
#   1. Resolve current GitHub repo
#   2. Walk through Claude GitHub App install (browser)
#   3. Generate OAuth token via `claude setup-token`, save as GitHub Secret
#   4. Run scripts/render-workflows.sh (or cp static templates with --static-templates)
#   5. git add + commit + push (with confirmation)
#   6. Run scripts/check-actions.sh for a final health check
#   7. Optionally install Superset workspace integration
#
# Usage:
#   bash scripts/configure-actions.sh
#   bash scripts/configure-actions.sh --skip-app-install      # already installed App manually
#   bash scripts/configure-actions.sh --static-templates      # use templates/ instead of render
#   bash scripts/configure-actions.sh --dry-run               # check only, no writes

set -euo pipefail

# ---- Helpers ----
say()  { printf "\033[1;36m▸\033[0m %s\n" "$*"; }
ok()   { printf "\033[1;32m✓\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m⚠\033[0m %s\n" "$*" >&2; }
err()  { printf "\033[1;31m✗\033[0m %s\n" "$*" >&2; exit 1; }
ask()  {
  local prompt="$1" default="${2:-}"
  if [[ -n "$default" ]]; then prompt="$prompt [$default]"; fi
  local reply
  read -r -p "$(printf '\033[1;35m?\033[0m %s: ' "$prompt")" reply
  echo "${reply:-$default}"
}

DRY=0
SKIP_APP=0
STATIC_TEMPLATES=0
PROVIDER=""           # claude | codex | both — empty = ask interactively
INCLUDE_CI=""         # 1|0 — empty = auto-detect existing CI

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    --skip-app-install) SKIP_APP=1; shift ;;
    --static-templates) STATIC_TEMPLATES=1; shift ;;
    --provider) PROVIDER="$2"; shift 2 ;;
    --include-ci) INCLUDE_CI=1; shift ;;
    --no-include-ci) INCLUDE_CI=0; shift ;;
    -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) err "Unknown flag: $1" ;;
  esac
done

# ---- Step 0: Prerequisites ----
say "Step 0: Verify prerequisites"
command -v gh     >/dev/null || err "gh CLI missing. Install: brew install gh (macOS) or https://cli.github.com"
command -v claude >/dev/null || err "claude CLI missing. Install from https://code.claude.com"
command -v git    >/dev/null || err "git missing"

if ! gh auth status >/dev/null 2>&1; then
  err "gh CLI not authenticated. Run: gh auth login"
fi

if ! gh auth status 2>&1 | grep -qE "scopes:.*workflow"; then
  warn "gh token missing 'workflow' scope (needed to push workflow YAMLs)"
  if (( DRY == 0 )); then
    if [[ "$(ask 'Run gh auth refresh -s workflow now?' 'y')" =~ ^[Yy] ]]; then
      gh auth refresh -h github.com -s workflow
    else
      err "workflow scope is required"
    fi
  fi
fi
ok "All prerequisites met"

# ---- Step 1: Resolve repo (with guided setup if new) ----
say "Step 1: Identify current repo"
echo "  Working directory: $(pwd)"

# 1a. Is the current directory a git repo?
if ! git rev-parse --git-dir >/dev/null 2>&1; then
  warn "This directory is NOT a git repository."
  echo ""
  echo "  The plugin needs a git repo to operate."
  echo "  Make sure you are inside the project folder you want to track."
  echo "  Current directory: $(pwd)"
  if (( DRY == 1 )); then
    err "Aborting (dry-run): not in a git repo"
  fi
  if [[ "$(ask "Initialize a new git repo here (in $(pwd))?" 'n')" =~ ^[Yy] ]]; then
    # `-b main` requires git >= 2.28; fall back to init + rename for older git.
    if ! git init -b main 2>/dev/null; then
      git init && git symbolic-ref HEAD refs/heads/main
    fi
    ok "Initialized empty git repo (branch: main)"
  else
    err "Aborting. cd into the right folder (or run 'git init -b main') and re-run /24hour-ClaudeCode:setup."
  fi
fi

# Resolve absolute path of the repo root, so user sees exactly where we're working.
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
echo "  Repo root:         $REPO_ROOT"

# 1b. Is there at least one commit?
if ! git rev-parse HEAD >/dev/null 2>&1; then
  warn "Git repo exists but has NO commits yet."
  # Need git user.name and user.email to commit
  user_name=$(git config user.name 2>/dev/null || git config --global user.name 2>/dev/null || echo "")
  user_email=$(git config user.email 2>/dev/null || git config --global user.email 2>/dev/null || echo "")
  if [[ -z "$user_name" || -z "$user_email" ]]; then
    warn "Git user.name / user.email not configured — needed to commit."
    echo "  Run these first (one-time global setup):"
    echo "    git config --global user.name 'Your Name'"
    echo "    git config --global user.email 'you@example.com'"
    err "Aborting. Configure git identity then re-run."
  fi
  # Files to commit?
  if [[ -z "$(git status --porcelain 2>/dev/null)" ]]; then
    warn "No files to commit in $(pwd)."
    echo "  Add at least one file (even a README.md), then re-run /24hour-ClaudeCode:setup."
    err "Aborting. Add some code and re-run."
  fi
  if [[ "$(ask 'Stage all files and create an initial commit?' 'y')" =~ ^[Yy] ]]; then
    if (( DRY == 0 )); then
      git add -A && git commit -q -m "initial commit" \
        || err "git commit failed. Check git output above."
      ok "Initial commit created on branch: $(git branch --show-current)"
    fi
  else
    err "Aborting. Create an initial commit then re-run."
  fi
fi

# 1c. Is there a GitHub remote that gh can reach?
REPO=""
remote_url=$(git remote get-url origin 2>/dev/null || echo "")
if [[ -n "$remote_url" ]]; then
  REPO="$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || echo '')"
fi

if [[ -z "$REPO" ]]; then
  if [[ -z "$remote_url" ]]; then
    warn "No GitHub remote configured for this repo yet."
  else
    warn "Remote 'origin' is set ($remote_url) but gh can't view it."
    echo "  Possible: the remote doesn't exist on GitHub yet, or you lack access."
  fi
  echo ""
  echo "  Two ways forward:"
  echo "    (A) Create a NEW GitHub repo from this folder  ← recommended if this is a fresh project"
  echo "    (B) Connect to an EXISTING GitHub repo manually"
  echo ""
  if (( DRY == 1 )); then
    err "Aborting (dry-run): no GitHub remote"
  fi
  choice=$(ask "Choose A or B" "A")
  case "$choice" in
    [Aa]*)
      echo ""
      say "  Running 'gh repo create' — it will ask for repo name, visibility, and offer to push."
      echo "  Tip: when it asks 'Push commits from the current branch?', answer Yes."
      echo ""
      gh repo create --source=. --remote=origin --push \
        || err "gh repo create failed. See output above. You can also run it interactively: gh repo create"
      REPO="$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null)" \
        || err "Repo created but gh can't see it. Try: gh auth refresh"
      ok "Created and connected: $REPO"
      ;;
    *)
      echo ""
      echo "  Manual steps for an existing GitHub repo:"
      echo "    git remote add origin git@github.com:<OWNER>/<REPO>.git"
      echo "    git push -u origin $(git branch --show-current)"
      echo ""
      echo "  Then re-run /24hour-ClaudeCode:setup from this same folder ($(pwd))."
      err "Aborting. Connect the remote, push the branch, then re-run."
      ;;
  esac
fi

ok "Target repo: $REPO"
echo "  Current branch: $(git branch --show-current)"
echo "  Default branch (where setup will commit): $(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null || echo 'main')"

# ---- State summary: what's already done, what's left ----
say "Current onboarding state for $REPO"
state_app="unverifiable (REST API requires App-JWT; you must check manually)"
state_secret="✗ missing"
if gh secret list -R "$REPO" 2>/dev/null | grep -q "^CLAUDE_CODE_OAUTH_TOKEN"; then
  secret_age=$(gh secret list -R "$REPO" 2>/dev/null | awk '$1=="CLAUDE_CODE_OAUTH_TOKEN" {for(i=2;i<=NF;i++) printf "%s ", $i; print ""}')
  state_secret="✓ set (${secret_age% })"
fi
state_workflows="✗ no .github/workflows/claude*.yml or codex*.yml"
if compgen -G ".github/workflows/claude*.yml" >/dev/null 2>&1 \
   || compgen -G ".github/workflows/codex*.yml" >/dev/null 2>&1; then
  found_wf=$(ls .github/workflows/claude*.yml .github/workflows/codex*.yml 2>/dev/null | xargs -n1 basename | tr '\n' ' ')
  state_workflows="✓ ${found_wf}"
fi
state_config="✗ .claude/24hour-ClaudeCode.config.json missing"
[[ -f .claude/24hour-ClaudeCode.config.json ]] && state_config="✓ present"

echo "  Claude GitHub App on repo:      $state_app"
echo "  CLAUDE_CODE_OAUTH_TOKEN secret: $state_secret"
echo "  Workflow YAML(s):               $state_workflows"
echo "  Plugin config file:             $state_config"
echo ""
echo "  The wizard will skip already-done items. Re-running setup is always safe."
echo ""

# ---- Step 2: GitHub App ----
#
# IMPORTANT: there is NO user-PAT-accessible REST endpoint that confirms a
# GitHub App is installed on a given repo. `gh api repos/OWNER/REPO/installation`
# and `/user/installations` both require App-JWT auth (return 401 with user
# token). So we cannot programmatically verify the install — we open the
# user-facing installations page where the user can SEE the install themselves,
# wait for their confirmation, and trust it.
#
# Indirect verification happens later anyway: if the App isn't installed, the
# first PR's auto-review will fail with a clear "App not installed" error.
if (( SKIP_APP == 0 )); then
  say "Step 2: Install Claude GitHub App on $REPO"
  echo ""
  echo "  Two pages will help you do this:"
  echo "    1. Install/configure page: https://github.com/apps/claude"
  echo "       → Click 'Install' (or 'Configure' if already installed)"
  echo "       → 'Only select repositories' → tick: $REPO"
  echo "       → Click 'Install' / 'Save'"
  echo ""
  echo "    2. Verify page: https://github.com/settings/installations"
  echo "       → Find 'Claude' in the list → click 'Configure'"
  echo "       → Confirm $REPO appears under 'Repository access'"
  echo ""
  if (( DRY == 0 )); then
    if [[ "$(ask 'Open the install page in your browser now?' 'y')" =~ ^[Yy] ]]; then
      open  "https://github.com/apps/claude" 2>/dev/null || \
      xdg-open "https://github.com/apps/claude" 2>/dev/null || \
        echo "  (could not auto-open; please visit the URL manually)"
    fi
    echo ""
    echo "  Note: the GitHub REST API does NOT let user tokens check App installs,"
    echo "  so this script cannot auto-verify. After you finish the install + see"
    echo "  $REPO in https://github.com/settings/installations under 'Claude',"
    echo "  press Enter to continue."
    echo ""
    read -r -p "$(printf '\033[1;35m?\033[0m Confirmed installed on %s? Press Enter (or Ctrl+C to abort)... ' "$REPO")"
    ok "Trusting user confirmation that Claude App is installed on $REPO"
    echo "  (If you got this wrong, the first PR's auto-review will fail and tell you.)"
  fi
else
  warn "--skip-app-install: skipping App install step (assuming it's already done)"
fi

# ---- Step 2.5: Pick review provider (BEFORE secrets so we only set what's needed) ----
say "Step 2.5: Choose review provider"
if [[ -z "$PROVIDER" ]] && (( DRY == 0 )); then
  echo "  Which AI reviews your PRs?"
  echo "    1) claude — Claude Code Action (uses CLAUDE_CODE_OAUTH_TOKEN)"
  echo "    2) codex  — OpenAI Codex Action (uses OPENAI_API_KEY)"
  echo "    3) both   — install both side by side"
  PROVIDER="$(ask 'Provider' 'claude')"
fi
PROVIDER="${PROVIDER:-claude}"
case "$PROVIDER" in
  1|claude) PROVIDER="claude" ;;
  2|codex)  PROVIDER="codex" ;;
  3|both)   PROVIDER="both" ;;
  *) err "Invalid provider: $PROVIDER (must be claude / codex / both)" ;;
esac
ok "Provider: $PROVIDER"

# ---- Step 3: OAuth token & secret (only when Claude is in scope) ----
if [[ "$PROVIDER" == "claude" || "$PROVIDER" == "both" ]]; then
  say "Step 3: Claude OAuth token secret"
  NEED_TOKEN=0
  if gh secret list -R "$REPO" 2>/dev/null | grep -q "^CLAUDE_CODE_OAUTH_TOKEN"; then
    EXISTING_TIME=$(gh secret list -R "$REPO" | awk '$1=="CLAUDE_CODE_OAUTH_TOKEN" {print $2}')
    ok "Secret already set ($EXISTING_TIME)"
    if [[ "$(ask 'Regenerate anyway?' 'n')" =~ ^[Yy] ]]; then
      NEED_TOKEN=1
    fi
  else
    warn "CLAUDE_CODE_OAUTH_TOKEN secret not found — will generate"
    NEED_TOKEN=1
  fi

  if (( NEED_TOKEN == 1 )) && (( DRY == 0 )); then
    echo ""
    echo "  About to run 'claude setup-token'. It opens a browser for OAuth login"
    echo "  with your Claude Pro/Max account. The terminal then prints a long token"
    echo "  starting with 'sk-ant-oat01-'. **Copy it** — the next step asks you to paste."
    echo ""
    echo "  Security: NEVER paste this token into chat, commit messages, .env files,"
    echo "  Slack, or email. The only safe destination is GitHub Secrets (next step)."
    read -r -p "$(printf '\033[1;35m?\033[0m Press Enter to start, or Ctrl+C to abort... ')"
    claude setup-token || err "claude setup-token failed"
    echo ""
    echo "  Now paste the token to gh secret set:"
    gh secret set CLAUDE_CODE_OAUTH_TOKEN -R "$REPO" || err "gh secret set failed"
    ok "Secret saved to $REPO"
  fi
else
  say "Step 3: skipped (Claude not in selected provider)"
fi

# ---- Step 4: Workflow YAMLs ----
say "Step 4: Detect project + render workflow YAMLs"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="$SCRIPT_DIR/../templates"
[[ -d "$TEMPLATE_DIR" ]] || err "templates/ directory missing: $TEMPLATE_DIR"

mkdir -p .github/workflows

if (( STATIC_TEMPLATES == 1 )); then
  warn "--static-templates: writing generic YAMLs (no project tailoring)"
  for f in claude.yml claude-code-review.yml; do
    TARGET=".github/workflows/$f"
    SRC="$TEMPLATE_DIR/$f"
    if [[ -f "$TARGET" ]]; then
      if cmp -s "$SRC" "$TARGET"; then
        ok "$TARGET unchanged"
      else
        warn "$TARGET differs from template"
        if (( DRY == 0 )); then
          case "$(ask 'overwrite (y) / skip (n) / show diff (d)' 'n')" in
            y|Y) cp "$SRC" "$TARGET"; ok "Overwrote $TARGET" ;;
            d|D) diff -u "$TARGET" "$SRC" || true; warn "Decide manually" ;;
            *)   warn "Skipped $TARGET" ;;
          esac
        fi
      fi
    elif (( DRY == 0 )); then
      cp "$SRC" "$TARGET"
      ok "Created $TARGET"
    fi
  done
else
  echo "  Auto-detection (default) discovers project type, test/lint/typecheck, style guides,"
  echo "  sensitive paths, and existing CI. These are baked into the workflow YAMLs."
  echo ""

  # Provider already decided in Step 2.5; reuse $PROVIDER here.

  # ---- Decide whether to include CI YML ----
  if [[ -z "$INCLUDE_CI" ]]; then
    # Auto-detect: if any non-claude/codex YAML exists in .github/workflows, assume CI is present
    existing_ci=0
    if [[ -d .github/workflows ]]; then
      for yml in .github/workflows/*.yml .github/workflows/*.yaml; do
        [[ -f "$yml" ]] || continue
        case "$(basename "$yml")" in
          claude*|codex*) ;;
          *) existing_ci=1 ;;
        esac
      done
    fi
    if (( existing_ci == 1 )); then
      INCLUDE_CI=0
      ok "Existing CI workflow detected — review YML(s) only"
    else
      if (( DRY == 0 )); then
        if [[ "$(ask 'No CI workflow detected. Generate a basic CI workflow (lint/typecheck/test) too?' 'y')" =~ ^[Yy] ]]; then
          INCLUDE_CI=1
        else
          INCLUDE_CI=0
        fi
      else
        INCLUDE_CI=0
      fi
    fi
  fi

  # ---- Show detection results ----
  if (( DRY == 0 )); then
    bash "$SCRIPT_DIR/render-workflows.sh" --show-vars
    echo ""
    echo "  Will generate (provider=$PROVIDER, include-ci=$INCLUDE_CI):"
    (( INCLUDE_CI == 1 )) && echo "    - .github/workflows/ci.yml"
    [[ "$PROVIDER" == "claude" || "$PROVIDER" == "both" ]] && echo "    - .github/workflows/claude-code-review.yml"
    [[ "$PROVIDER" == "claude" || "$PROVIDER" == "both" ]] && echo "    - .github/workflows/claude.yml"
    [[ "$PROVIDER" == "codex"  || "$PROVIDER" == "both" ]] && echo "    - .github/workflows/codex-review.yml"
    echo "    - .claude/24hour-ClaudeCode/review-prompt.md (externalized prompt; edit anytime)"
    echo ""
    if [[ "$(ask 'Render?' 'y')" =~ ^[Yy] ]]; then
      RENDER_FLAGS=( --provider "$PROVIDER" )
      (( INCLUDE_CI == 1 )) && RENDER_FLAGS+=( --include-ci )
      bash "$SCRIPT_DIR/render-workflows.sh" "${RENDER_FLAGS[@]}"
    else
      warn "Skipped render. Re-run with --static-templates to use generic templates instead."
      exit 0
    fi
  else
    echo "  [dry-run] would call: bash render-workflows.sh --provider $PROVIDER $((( INCLUDE_CI == 1 )) && echo --include-ci) --dry-run"
    RENDER_FLAGS=( --provider "$PROVIDER" --dry-run )
    (( INCLUDE_CI == 1 )) && RENDER_FLAGS+=( --include-ci )
    bash "$SCRIPT_DIR/render-workflows.sh" "${RENDER_FLAGS[@]}"
  fi
fi

# ---- Step 4.5: Provider-specific secrets ----
if [[ "$PROVIDER" == "codex" || "$PROVIDER" == "both" ]]; then
  say "Step 4.5: OPENAI_API_KEY for Codex provider"
  if gh secret list -R "$REPO" 2>/dev/null | grep -q "^OPENAI_API_KEY"; then
    ok "OPENAI_API_KEY secret already set"
  else
    warn "OPENAI_API_KEY not set in $REPO"
    if (( DRY == 0 )); then
      echo "  Get an OpenAI API key from https://platform.openai.com/api-keys"
      echo "  Then run (paste key when prompted):"
      echo "    gh secret set OPENAI_API_KEY -R $REPO"
      if [[ "$(ask 'Run gh secret set now?' 'y')" =~ ^[Yy] ]]; then
        gh secret set OPENAI_API_KEY -R "$REPO" || warn "gh secret set failed"
      fi
    fi
  fi
fi

# ---- Step 5: Commit + push ----
say "Step 5: Commit + push workflow files"
if git status --porcelain .github/workflows | grep -q '.'; then
  if (( DRY == 0 )); then
    echo "  Pending changes in .github/workflows. Suggested:"
    echo ""
    echo "    git add .github/workflows/claude.yml .github/workflows/claude-code-review.yml"
    echo "    git commit -m 'Add Claude Code Actions workflows'"
    echo "    git push"
    echo ""
    if [[ "$(ask 'Run these now?' 'y')" =~ ^[Yy] ]]; then
      git add .github/workflows/claude.yml .github/workflows/claude-code-review.yml
      git commit -m "Add Claude Code Actions workflows"
      git push 2>/dev/null || warn "Push failed (no upstream?). Run 'git push -u origin <branch>' manually"
      ok "Pushed"
    else
      warn "Don't forget to push manually before opening a PR"
    fi
  fi
else
  ok "Workflow files already committed + pushed"
fi

# ---- Step 6: Health check ----
say "Step 6: Final health check"
bash "$SCRIPT_DIR/check-actions.sh" -R "$REPO" || warn "check-actions.sh reported issues (see above)"

# ---- Step 7: Optional Superset ----
echo ""
say "Step 7: Superset workspace integration (optional)"
echo "  If your team uses Superset to manage worktrees, this adds a setup hook"
echo "  that runs check-actions.sh + prints a workspace cheat sheet on every open."
echo ""
if (( DRY == 0 )); then
  if [[ "$(ask 'Configure Superset integration now?' 'y')" =~ ^[Yy] ]]; then
    bash "$SCRIPT_DIR/install-superset-config.sh"
  else
    echo "  Skipped. To install later: bash scripts/install-superset-config.sh"
  fi
fi

echo ""
ok "🎉 Configuration complete. Open a PR to see auto-review in action."
echo ""
echo "  Test PR (optional):"
echo "    git checkout -b test-claude-actions"
echo "    echo '<!-- test -->' >> README.md && git add README.md && git commit -m 'test: trigger review'"
echo "    git push -u origin test-claude-actions && gh pr create --fill"
echo ""
echo "  Maintenance:"
echo "    bash scripts/check-actions.sh -v                    # health check"
echo "    bash scripts/render-workflows.sh                    # re-render after structure change"
echo "    bash scripts/install-superset-config.sh --verify    # verify Superset integration"
