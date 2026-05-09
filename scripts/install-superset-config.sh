#!/usr/bin/env bash
# install-superset-config.sh — Install + verify Superset workspace integration.
#
# What this does:
#   default mode: copy templates/superset-config.json → .superset/config.json,
#                 then print explicit activation steps (commit, register repo, verify).
#   --verify    : check whether activation is complete (file exists, hook references
#                 check-actions.sh, file is committed). Returns non-zero on issues.
#   --uninstall : delete .superset/config.json (with confirmation).
#
# Usage:
#   bash scripts/install-superset-config.sh                # interactive install
#   bash scripts/install-superset-config.sh --force        # overwrite without asking
#   bash scripts/install-superset-config.sh --local        # write to config.local.json (gitignored)
#   bash scripts/install-superset-config.sh --verify       # check current state
#   bash scripts/install-superset-config.sh --uninstall    # remove

set -euo pipefail

FORCE=0
LOCAL=0
VERIFY=0
UNINSTALL=0
NONINTERACTIVE=0

for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    --local) LOCAL=1 ;;
    --verify) VERIFY=1 ;;
    --uninstall) UNINSTALL=1 ;;
    --noninteractive|-y) NONINTERACTIVE=1 ;;
    -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown: $arg" >&2; exit 1 ;;
  esac
done

say()  { printf "\033[1;36m▸\033[0m %s\n" "$*"; }
ok()   { printf "\033[1;32m✓\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m⚠\033[0m %s\n" "$*" >&2; }
err()  { printf "\033[1;31m✗\033[0m %s\n" "$*" >&2; exit 1; }

ask() {
  local prompt="$1" default="${2:-y}"
  if (( NONINTERACTIVE == 1 )); then echo "$default"; return; fi
  local reply
  read -r -p "$(printf '\033[1;35m?\033[0m %s [%s]: ' "$prompt" "$default")" reply
  echo "${reply:-$default}"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$SCRIPT_DIR/../templates/superset-config.json"

if (( LOCAL == 1 )); then
  TARGET=".superset/config.local.json"
else
  TARGET=".superset/config.json"
fi

# ============================================================================
# --uninstall path
# ============================================================================
if (( UNINSTALL == 1 )); then
  if [[ ! -f "$TARGET" ]]; then
    warn "$TARGET not found; nothing to uninstall"
    exit 0
  fi
  reply="$(ask "Delete $TARGET?" "n")"
  [[ "$reply" =~ ^[Yy] ]] || err "Aborted"
  rm -f "$TARGET"
  ok "Removed $TARGET"
  echo ""
  say "Next: commit the deletion if it was tracked:"
  echo "    git add $TARGET && git commit -m 'Remove Superset config'"
  exit 0
fi

# ============================================================================
# --verify path
# ============================================================================
if (( VERIFY == 1 )); then
  echo ""
  say "Verifying Superset integration..."
  echo ""

  ERR_COUNT=0
  WARN_COUNT=0

  # 1. Config file exists
  if [[ -f "$TARGET" ]]; then
    ok "Found $TARGET"
  else
    err "$TARGET missing — run: bash scripts/install-superset-config.sh"
  fi

  # 2. Setup hook exists & references check-actions.sh
  if grep -q 'check-actions.sh' "$TARGET" 2>/dev/null; then
    ok "Setup hook references scripts/check-actions.sh"
  else
    warn "Setup hook does not reference check-actions.sh"
    WARN_COUNT=$((WARN_COUNT+1))
  fi

  # 3. check-actions.sh exists
  if [[ -x "$SCRIPT_DIR/check-actions.sh" ]]; then
    ok "scripts/check-actions.sh exists and is executable"
  else
    warn "scripts/check-actions.sh missing or not executable (skill installation incomplete?)"
    WARN_COUNT=$((WARN_COUNT+1))
  fi

  # 4. Committed?
  if (( LOCAL == 0 )); then
    if git ls-files --error-unmatch "$TARGET" >/dev/null 2>&1; then
      ok "$TARGET is tracked in git"
      if ! git diff --quiet HEAD -- "$TARGET" 2>/dev/null; then
        warn "$TARGET has uncommitted changes"
        WARN_COUNT=$((WARN_COUNT+1))
      fi
    else
      warn "$TARGET is NOT tracked in git (your team won't get the config)"
      WARN_COUNT=$((WARN_COUNT+1))
    fi
  fi

  # 5. Superset CLI presence
  if command -v superset >/dev/null 2>&1; then
    ok "Superset CLI is installed: $(command -v superset)"
  else
    warn "Superset CLI not on PATH — config exists but Superset client isn't installed locally"
    echo "  (this is OK if your team uses Superset elsewhere; see https://docs.superset.sh)"
    WARN_COUNT=$((WARN_COUNT+1))
  fi

  echo ""
  if (( ERR_COUNT > 0 )); then
    err "$ERR_COUNT ERROR / $WARN_COUNT WARN — fix the ERRORs first"
  elif (( WARN_COUNT > 0 )); then
    warn "$WARN_COUNT WARN — works but check the above"
    exit 2
  else
    ok "Superset integration looks healthy."
  fi
  exit 0
fi

# ============================================================================
# Default: install path
# ============================================================================
[[ -f "$TEMPLATE" ]] || err "Template not found: $TEMPLATE (skill installation incomplete)"

mkdir -p .superset

if [[ -f "$TARGET" ]]; then
  if (( FORCE == 1 )); then
    cp "$TEMPLATE" "$TARGET"
    ok "Force-overwrote $TARGET"
  else
    warn "$TARGET already exists"
    echo ""
    echo "  Compare with template:"
    diff -u "$TARGET" "$TEMPLATE" || true
    echo ""
    reply="$(ask "Overwrite? (y) / Skip (n) / Save template alongside (s)" "n")"
    case "$reply" in
      y|Y) cp "$TEMPLATE" "$TARGET"; ok "Overwrote $TARGET" ;;
      s|S) cp "$TEMPLATE" ".superset/config.template.json"; ok "Saved template to .superset/config.template.json" ;;
      *) ok "Kept existing $TARGET" ;;
    esac
  fi
else
  cp "$TEMPLATE" "$TARGET"
  ok "Created $TARGET"
fi

# ---- Also install the 3 split hook scripts ----
for hook_name in setup run teardown; do
  hook_template="$SCRIPT_DIR/../templates/superset-${hook_name}.sh"
  hook_target=".superset/${hook_name}.sh"
  if [[ ! -f "$hook_template" ]]; then
    warn "Hook template missing: $hook_template (skip)"
    continue
  fi
  if [[ -f "$hook_target" ]]; then
    if (( FORCE == 1 )); then
      cp "$hook_template" "$hook_target"
      chmod +x "$hook_target"
      ok "Force-overwrote $hook_target"
    else
      warn "$hook_target exists; keeping. (Use --force to overwrite, or edit it manually.)"
    fi
  else
    cp "$hook_template" "$hook_target"
    chmod +x "$hook_target"
    ok "Created $hook_target"
  fi
done

if (( LOCAL == 1 )); then
  if [[ -f .gitignore ]] && ! grep -qE '^\.superset/config\.local\.json' .gitignore; then
    echo ".superset/config.local.json" >> .gitignore
    ok "Added .superset/config.local.json to .gitignore"
  fi
fi

# ----------------------------------------------------------------------------
# Activation guidance — the core "how do I actually turn this on" part
# ----------------------------------------------------------------------------
echo ""
say "✅ Config file in place. Now activate it (3 steps):"
echo ""

# Step 1: commit + push (only for shared config)
if (( LOCAL == 0 )); then
  echo "  ─── Step 1: commit + push (so teammates get this config) ───"
  if git ls-files --error-unmatch "$TARGET" >/dev/null 2>&1 && git diff --quiet HEAD -- "$TARGET" 2>/dev/null; then
    ok "Already committed and clean."
  else
    echo "    git add $TARGET"
    echo "    git commit -m 'Add Superset workspace config'"
    echo "    git push"
    echo ""
    reply="$(ask "Run the three commands above now?" "y")"
    if [[ "$reply" =~ ^[Yy] ]]; then
      git add "$TARGET"
      if git diff --cached --quiet; then
        warn "Nothing staged (already committed?)"
      else
        git commit -m "Add Superset workspace config"
        git push 2>/dev/null && ok "Pushed" || warn "Push failed (no upstream?). Run 'git push -u origin <branch>' manually"
      fi
    else
      warn "Don't forget to commit + push before teammates can use this."
    fi
  fi
else
  echo "  ─── Step 1: skipped (this is a local config, not for the team) ───"
fi

echo ""
echo "  ─── Step 2: register this repo with Superset (one-time) ───"
if command -v superset >/dev/null 2>&1; then
  ok "Superset CLI detected: $(command -v superset)"
  echo ""
  echo "  If you haven't added this repo as a Superset project yet, do it via the"
  echo "  Superset client UI (or CLI — see 'superset --help')."
  echo ""
  echo "  Reference: https://docs.superset.sh"
else
  warn "Superset CLI is not installed locally."
  echo ""
  echo "  If you actually use Superset:"
  echo "    1. Install it (see https://docs.superset.sh)"
  echo "    2. Open Superset → Add Project → point at this repo's path"
  echo ""
  echo "  If your TEAM uses Superset but you don't, you don't need to do anything"
  echo "  locally. The .superset/config.json you just committed is what they'll pick up."
fi

echo ""
echo "  ─── Step 3: verify activation ───"
echo ""
echo "  Right now, manually trigger what the setup hook would do:"
echo ""
echo "    bash scripts/check-actions.sh -v"
echo ""
echo "  Expected output:"
echo "    ✓ All checks passed   (or '⚠ N WARN' / '✗ N ERROR')"
echo ""
echo "  When you next open / create a workspace in Superset, you should see this"
echo "  same line in the workspace's terminal pane (preceded by '▸ Verifying...')."
echo ""
echo "  Anytime later, re-verify the integration with:"
echo "    bash scripts/install-superset-config.sh --verify"
echo ""

# Final next-step pointer
say "Done. Skill is now Superset-integrated."
echo ""
echo "  → Full integration details: references/superset-integration.md"
echo "  → 9-step PR flow:           SKILL.md"
