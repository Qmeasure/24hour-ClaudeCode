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

# Locate this script's own dir — needed to invoke sibling helpers like
# check-claude-app.sh from Step 2 onward.
SCRIPT_DIR_THIS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
# All four artifacts use precise side-channel / direct probes — no false
# negatives like the v1.0.1/1.0.2 `gh api repos/.../installation` mistake.
say "Current onboarding state for $REPO"

# App: check_suites side-channel (anthropics-owned `claude` slug)
app_result=$(bash "$SCRIPT_DIR_THIS/check-claude-app.sh" "$REPO" 2>&1)
case $? in
  0) state_app="✓ ${app_result#installed: }" ;;
  1) state_app="✗ NOT detected via check_suites (install or push needed; see Step 2)" ;;
  *) state_app="? ${app_result#unknown: }" ;;
esac

# Secret: precise GET /repos/.../actions/secrets/<NAME> probe
sec_result=$(bash "$SCRIPT_DIR_THIS/check-secret.sh" "$REPO" CLAUDE_CODE_OAUTH_TOKEN 2>&1)
case $? in
  0) state_secret="✓ ${sec_result#exists: }" ;;
  1) state_secret="✗ missing CLAUDE_CODE_OAUTH_TOKEN" ;;
  *) state_secret="? ${sec_result#unknown: }" ;;
esac

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

# ---- Step 2: Verify Claude GitHub App is installed on $REPO ----
#
# Most users already have the Claude App installed at the account level (often
# with "All repositories" selected). For them, this step is a one-line auto-
# detect — no browser, no clicks. We only walk through Install if detection
# fails.
#
# Detection uses scripts/check-claude-app.sh — it queries check_suites on the
# default-branch HEAD; any installed App with checks:write permission appears
# there. See that script's header for caveats (mainly: the suite is created at
# commit-push time, so if a user installs the App AFTER their last push, the
# current HEAD's suite won't include Claude — we re-verify after Step 5's push).
if (( SKIP_APP == 0 )); then
  say "Step 2: Verify Claude GitHub App on $REPO"

  if (( DRY == 0 )); then
    detect_result=$(bash "$SCRIPT_DIR_THIS/check-claude-app.sh" "$REPO" 2>&1)
    detect_exit=$?
  else
    detect_result="(dry-run skipped)"
    detect_exit=1
  fi

  if (( detect_exit == 0 )); then
    ok "Claude App already installed on $REPO — nothing to do"
    echo "  ($detect_result)"
  elif (( detect_exit == 2 )); then
    warn "Could not check (gh API error). $detect_result"
    if (( DRY == 0 )); then
      [[ "$(ask 'Continue anyway?' 'n')" =~ ^[Yy] ]] || err "Aborted."
    fi
  else
    # exit 1: not detected. Could be truly not installed, or installed-but-no-new-push-since.
    warn "Claude App NOT detected on $REPO via check_suites side-channel."
    echo "  $detect_result"
    echo ""
    echo "  Two likely causes:"
    echo "    (a) The App isn't installed for this account/repo yet."
    echo "        Fix: visit https://github.com/apps/claude → Install."
    echo "    (b) You installed it AFTER your last push. The check_suite is"
    echo "        created per-commit-at-push-time and isn't backfilled. We'll"
    echo "        push workflow YAMLs in Step 5; this script auto-rechecks then."
    echo ""
    echo "  Configure page (manage which repos Claude can access):"
    echo "    https://github.com/settings/installations"
    echo ""
    if (( DRY == 0 )); then
      if [[ "$(ask 'Open the install page in your browser?' 'y')" =~ ^[Yy] ]]; then
        open  "https://github.com/apps/claude" 2>/dev/null || \
        xdg-open "https://github.com/apps/claude" 2>/dev/null || \
          echo "  (could not auto-open; visit manually)"
      fi
      echo ""
      echo "  After you've installed the App on $REPO (or confirmed it covers this repo),"
      echo "  press Enter to re-detect. If still not detected, we continue anyway and"
      echo "  re-verify after Step 5 push."
      read -r -p "$(printf '\033[1;35m?\033[0m Press Enter to re-check... ')"

      # Re-detect once
      detect_result=$(bash "$SCRIPT_DIR_THIS/check-claude-app.sh" "$REPO" 2>&1)
      if (( $? == 0 )); then
        ok "Re-check passed: $detect_result"
      else
        warn "Still not detected. Proceeding; Step 5 will push workflow YAMLs and"
        warn "re-verify on the new commit. If it's still missing then, App is genuinely"
        warn "not installed on this repo — fix that before triggering a PR."
      fi
    fi
  fi
else
  warn "--skip-app-install: skipping App detection (assuming it's installed)"
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

# ---- Step 3: CLAUDE_CODE_OAUTH_TOKEN secret ----
#
# Both sub-steps (`claude setup-token` and `gh secret set`) are interactive in
# ways this script cannot drive automatically:
#   - `claude setup-token` opens a browser, OAuth-logs you in with your Claude
#     account, and prints the resulting `sk-ant-oat01-...` token to YOUR terminal.
#     The script can't capture stdout of an interactive browser flow.
#   - `gh secret set <NAME> -R <REPO>` (without --body) prompts you to paste the
#     token. We want this interactive variant — `--body` would put the token in
#     shell history / the process arglist, which is unsafe.
#
# So: detect first (precise probe), then if missing, print exact CLI commands
# for the user to run in their terminal, wait for them to come back, re-verify.
# Don't try to call them from inside this script.
if [[ "$PROVIDER" == "claude" || "$PROVIDER" == "both" ]]; then
  say "Step 3: CLAUDE_CODE_OAUTH_TOKEN secret"

  NEED_TOKEN=0
  sec_check=$(bash "$SCRIPT_DIR_THIS/check-secret.sh" "$REPO" CLAUDE_CODE_OAUTH_TOKEN 2>&1)
  case $? in
    0)
      ok "${sec_check#exists: }"
      if [[ "$(ask 'Regenerate the token anyway?' 'n')" =~ ^[Yy] ]]; then
        NEED_TOKEN=1
      fi
      ;;
    1) NEED_TOKEN=1 ;;
    *) warn "Cannot probe secret: $sec_check"
       [[ "$(ask 'Continue anyway?' 'n')" =~ ^[Yy] ]] || err "Aborted." ;;
  esac

  if (( NEED_TOKEN == 1 )) && (( DRY == 0 )); then
    echo ""
    echo "  ╔═══════════════════════════════════════════════════════════════════╗"
    echo "  ║  Run these THREE commands in YOUR terminal (this script cannot   ║"
    echo "  ║  do them because both are interactive — browser OAuth + paste).  ║"
    echo "  ╚═══════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "  ┌─ 1. Generate the OAuth token ─────────────────────────────────────┐"
    echo "  │                                                                   │"
    echo "  │   claude setup-token                                              │"
    echo "  │                                                                   │"
    echo "  │   → Browser opens. Sign in with Claude Pro/Max account.           │"
    echo "  │   → Terminal then prints a long string starting:                  │"
    echo "  │       sk-ant-oat01-XXXXXXXX...                                    │"
    echo "  │   → Copy that string (whole line, nothing else).                  │"
    echo "  │                                                                   │"
    echo "  └───────────────────────────────────────────────────────────────────┘"
    echo ""
    echo "  ┌─ 2. Save to this repo's GitHub Actions Secrets ───────────────────┐"
    echo "  │                                                                   │"
    echo "  │   gh secret set CLAUDE_CODE_OAUTH_TOKEN -R $REPO    "
    echo "  │                                                                   │"
    echo "  │   → gh prompts 'Paste your secret:' (no echo, not in shell hist)  │"
    echo "  │   → Paste the sk-ant-oat01-... string, hit Enter.                 │"
    echo "  │   → '✓ Set Actions secret CLAUDE_CODE_OAUTH_TOKEN' confirms.      │"
    echo "  │                                                                   │"
    echo "  └───────────────────────────────────────────────────────────────────┘"
    echo ""
    echo "  ┌─ 3. (Optional) Verify yourself ───────────────────────────────────┐"
    echo "  │                                                                   │"
    echo "  │   gh api repos/$REPO/actions/secrets/CLAUDE_CODE_OAUTH_TOKEN  "
    echo "  │                                                                   │"
    echo "  │   → 200 + JSON (name/created_at/updated_at) = set.                │"
    echo "  │   → 404 = not set (try Step 2 again).                             │"
    echo "  │   → No value is ever returned; GitHub never exposes secret values.│"
    echo "  │                                                                   │"
    echo "  └───────────────────────────────────────────────────────────────────┘"
    echo ""
    echo "  Security reminder:"
    echo "    NEVER paste the sk-ant-oat01-... token into chat, commit messages,"
    echo "    .env files, Slack, or email. The only safe destination is the gh"
    echo "    secret set prompt above (it goes encrypted into GitHub Secrets)."
    echo ""
    read -r -p "$(printf '\033[1;35m?\033[0m After running 1 + 2, press Enter and I will verify. (Ctrl+C to abort.) ')"

    # Re-probe with the precise check
    sec_recheck=$(bash "$SCRIPT_DIR_THIS/check-secret.sh" "$REPO" CLAUDE_CODE_OAUTH_TOKEN 2>&1)
    if [[ $? -eq 0 ]]; then
      ok "Verified: ${sec_recheck#exists: }"
    else
      warn "Secret still not detected: $sec_recheck"
      echo "    Most common causes:"
      echo "      - 'gh secret set' was interrupted / errored (run it again)"
      echo "      - Typo in the repo arg (should be: -R $REPO)"
      echo "      - You lack repo admin permission (need it to set secrets)"
      [[ "$(ask 'Continue anyway (workflows won''t actually work without this)?' 'n')" =~ ^[Yy] ]] \
        || err "Aborted. Set the secret then re-run /24hour-ClaudeCode:setup."
    fi
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
