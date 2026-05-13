#!/usr/bin/env bash
# .superset/setup.sh — runs on every Superset workspace open.
#
# Installed by /24hour-ClaudeCode:setup or scripts/install-superset-config.sh.
# Edit freely; this script is opinionated by default but yours to own.
#
# Responsibilities:
#   - Verify worktree + marketplace plugin presence
#   - Verify gh CLI auth + workflow scope
#   - Verify Claude Code Actions workflow YML(s) present
#   - Initialize .claude/runtime/24hour-ClaudeCode/
#   - Install project dependencies (project-specific; see "Dependencies" section)
#
# FORBIDDEN here (do these in review-loop skill instead):
#   - commit / push / create PR
#   - wait for review
#   - read review feedback
#   - auto-merge

set -uo pipefail

PWD_PATH="$(pwd)"
ENV_ROOT="${SUPERSET_ROOT_PATH:-}"
ENV_WS_NAME="${SUPERSET_WORKSPACE_NAME:-}"
ENV_WS_PATH="${SUPERSET_WORKSPACE_PATH:-}"

# Ignore stale Superset env vars when this script is triggered manually from a
# different checkout than the workspace path recorded in the environment.
if [[ -n "$ENV_WS_PATH" && "$ENV_WS_PATH" != "$PWD_PATH" ]]; then
  ENV_ROOT=""
  ENV_WS_NAME=""
  ENV_WS_PATH=""
fi

ROOT="${ENV_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
WS_NAME="${ENV_WS_NAME:-$(git branch --show-current 2>/dev/null || echo unnamed)}"
WS_PATH="${ENV_WS_PATH:-$PWD_PATH}"

bold()  { printf "\033[1m%s\033[0m" "$*"; }
ok()    { printf "\033[1;32m✓\033[0m %s\n" "$*"; }
warn()  { printf "\033[1;33m⚠\033[0m %s\n" "$*" >&2; }
info()  { printf "\033[1;36mℹ\033[0m %s\n" "$*"; }

PLUGIN_REF="24hour-ClaudeCode@24hour-ClaudeCode"

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
if ! command -v claude >/dev/null 2>&1; then
  warn "Claude Code CLI not found. Install Claude Code, then install the plugin."
  echo "      Install: claude plugin install $PLUGIN_REF"
elif claude plugin list 2>/dev/null | awk -v plugin="$PLUGIN_REF" '
  $0 ~ plugin { seen = 1 }
  seen && /Status:[[:space:]]*.*enabled/ { enabled = 1 }
  seen && /^$/ { seen = 0 }
  END { exit enabled ? 0 : 1 }
'; then
  ok "24hour-ClaudeCode plugin installed and enabled ($PLUGIN_REF)"
else
  warn "24hour-ClaudeCode plugin is not enabled in Claude Code."
  echo "      Run: claude plugin install $PLUGIN_REF"
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
if compgen -G "$ROOT/.github/workflows/claude*.yml" >/dev/null 2>&1 || \
   compgen -G "$ROOT/.github/workflows/codex*.yml" >/dev/null 2>&1; then
  ok "Claude/Codex review workflow file present"
else
  warn "Claude/Codex review workflow missing. From main checkout: /24hour-ClaudeCode:setup"
fi

# ---- 5. Initialize runtime ----
mkdir -p "$WS_PATH/.claude/runtime/24hour-ClaudeCode" 2>/dev/null || true
printf '*\n!.gitignore\n' > "$WS_PATH/.claude/runtime/24hour-ClaudeCode/.gitignore" 2>/dev/null || true
ok "Runtime directory initialized at .claude/runtime/24hour-ClaudeCode/"

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
  Open Claude Code in this workspace. The Stop prompt routes completed work to
  review-loop. Or trigger the skill explicitly with phrases like "open a PR".

$(bold 'Maintenance commands:')
  /24hour-ClaudeCode:status
  /24hour-ClaudeCode:retry        # clear stopped review-loop state
  claude plugin list              # verify plugin install status

$(bold 'When done — clean up worktree (run from MAIN checkout):')
  cd $ROOT
  git worktree remove $WS_PATH
  git branch -d $WS_NAME

$(bold 'Help:')
  claude plugin details $PLUGIN_REF
  /24hour-ClaudeCode:setup        # re-run onboarding if repo wiring drifts
EOF
echo ""
