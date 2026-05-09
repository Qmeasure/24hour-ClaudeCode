#!/usr/bin/env bash
# .superset/setup.sh — runs on every Superset workspace open.
#
# Installed by /24hour-ClaudeCode:setup or scripts/install-superset-config.sh.
# Edit freely; this script is opinionated by default but yours to own.
#
# Responsibilities:
#   - Verify worktree + plugin presence
#   - Verify gh CLI auth + workflow scope
#   - Verify GitHub secrets
#   - Verify Claude Code Actions workflow YML(s) present
#   - Initialize .claude/runtime/24hour-ClaudeCode/
#   - Install project dependencies (project-specific; see "Dependencies" section)
#
# FORBIDDEN here (do these in stop.sh / babysit-pr skill instead):
#   - commit / push / create PR
#   - wait for CI
#   - read review feedback
#   - auto-merge

set -uo pipefail

ROOT="${SUPERSET_ROOT_PATH:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
WS_NAME="${SUPERSET_WORKSPACE_NAME:-$(git branch --show-current 2>/dev/null || echo unnamed)}"
WS_PATH="${SUPERSET_WORKSPACE_PATH:-$(pwd)}"

bold()  { printf "\033[1m%s\033[0m" "$*"; }
ok()    { printf "\033[1;32m✓\033[0m %s\n" "$*"; }
warn()  { printf "\033[1;33m⚠\033[0m %s\n" "$*" >&2; }
info()  { printf "\033[1;36mℹ\033[0m %s\n" "$*"; }

PLUGIN_DIR="$ROOT/.claude/plugins/24hour-ClaudeCode"

echo ""
echo "╭─────────────────────────────────────────────────────────────────────╮"
printf "│ %-67s │\n" "$(bold '24hour-ClaudeCode') — workspace setup"
printf "│ %-67s │\n" "  worktree: $WS_NAME"
printf "│ %-67s │\n" "  path:     $WS_PATH"
echo "╰─────────────────────────────────────────────────────────────────────╯"
echo ""

# ---- 1. Worktree check ----
git_dir=$(git rev-parse --git-dir 2>/dev/null || echo "")
git_common=$(git rev-parse --git-common-dir 2>/dev/null || echo "")
if [[ -z "$git_dir" || "$git_dir" == "$git_common" ]]; then
  warn "Not in a git worktree (this looks like the main checkout)."
  echo "      Open a worktree first: git worktree add ../my-feature -b feat/my-feature"
fi

# ---- 2. Plugin presence ----
if [[ -d "$PLUGIN_DIR" ]]; then
  ok "Plugin installed at $PLUGIN_DIR"
else
  warn "24hour-ClaudeCode plugin NOT installed."
  echo "      Install: /plugin install 24hour-ClaudeCode (see plugin docs)"
fi

# ---- 3. gh CLI ----
if ! command -v gh >/dev/null 2>&1; then
  warn "gh CLI not installed. brew install gh / https://cli.github.com"
elif ! gh auth status >/dev/null 2>&1; then
  warn "gh CLI not authenticated. Run: gh auth login"
elif ! gh auth status 2>&1 | grep -qE "scopes:.*workflow"; then
  warn "gh token missing 'workflow' scope. Run: gh auth refresh -h github.com -s workflow"
else
  ok "gh CLI authenticated with workflow scope"
fi

# ---- 4. Claude Code Actions config ----
if [[ -x "$PLUGIN_DIR/scripts/check-actions.sh" ]]; then
  if bash "$PLUGIN_DIR/scripts/check-actions.sh" >/dev/null 2>&1; then
    ok "Claude Code Actions configured"
  else
    warn "Claude Code Actions config has issues. From main checkout: /24hour-ClaudeCode:setup"
  fi
else
  info "check-actions.sh not found (plugin install may be incomplete)"
fi

# ---- 5. Initialize runtime ----
if [[ -x "$PLUGIN_DIR/scripts/runtime-state.sh" ]]; then
  bash "$PLUGIN_DIR/scripts/runtime-state.sh" init >/dev/null 2>&1 || true
  ok "Runtime state initialized at .claude/runtime/24hour-ClaudeCode/"
fi

# ---- 6. Install project dependencies (PROJECT-SPECIFIC — EDIT THIS BLOCK) ----
echo ""
info "Installing project dependencies..."
# Default: detect common managers and install. Replace with your actual command.
if [[ -f pnpm-lock.yaml ]]; then
  pnpm install --frozen-lockfile 2>/dev/null || pnpm install
elif [[ -f yarn.lock ]]; then
  yarn install --frozen-lockfile 2>/dev/null || yarn install
elif [[ -f bun.lockb ]]; then
  bun install
elif [[ -f package-lock.json ]]; then
  npm ci 2>/dev/null || npm install
elif [[ -f poetry.lock ]]; then
  poetry install
elif [[ -f Pipfile.lock ]]; then
  pipenv install
elif [[ -f requirements.txt ]]; then
  pip install -r requirements.txt
elif [[ -f go.mod ]]; then
  go mod download
elif [[ -f Cargo.toml ]]; then
  cargo fetch
else
  info "No standard package manifest detected — skip dependency install"
fi

# ---- 7. Cheat sheet ----
echo ""
echo "─── Workspace ready. Quick reference ───"
cat <<EOF

$(bold 'Start coding:')
  Open Claude Code in this workspace. The Stop hook auto-engages on the first
  edit. Or trigger the skill explicitly with phrases like "open a PR".

$(bold 'Maintenance commands:')
  bash $PLUGIN_DIR/scripts/check-actions.sh -v
  /24hour-ClaudeCode:status
  /24hour-ClaudeCode:retry        # force re-run the Stop pipeline once

$(bold 'When done — clean up worktree (run from MAIN checkout):')
  cd $ROOT
  git worktree remove $WS_PATH
  git branch -d $WS_NAME

$(bold 'Help:')
  $PLUGIN_DIR/SKILL.md      — runtime contract
  $PLUGIN_DIR/README.md     — overview
EOF
echo ""
