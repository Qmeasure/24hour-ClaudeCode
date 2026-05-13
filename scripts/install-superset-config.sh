#!/usr/bin/env bash
# install-superset-config.sh — Install + verify Superset workspace integration.
#
# What this does:
#   default mode: copy templates/superset-config.json → .superset/config.json
#                 and templates/superset-{setup,run,teardown}.sh → .superset/,
#                 then print explicit activation steps (commit from the normal
#                 workflow, register repo, verify).
#   --verify    : check whether activation is complete (config + hook scripts
#                 exist, setup uses current plugin detection, setup checks the
#                 latest origin/default branch, and files are committed).
#                 Returns non-zero on issues.
#   --uninstall : delete .superset/config.json only when --force is also passed.
#
# Usage:
#   bash scripts/install-superset-config.sh                # install missing files, keep existing
#   bash scripts/install-superset-config.sh --force        # overwrite without asking
#   bash scripts/install-superset-config.sh --local        # write to config.local.json (gitignored)
#   bash scripts/install-superset-config.sh --verify       # check current state
#   bash scripts/install-superset-config.sh --uninstall --force  # remove

set -euo pipefail

FORCE=0
LOCAL=0
VERIFY=0
UNINSTALL=0

for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    --local) LOCAL=1 ;;
    --verify) VERIFY=1 ;;
    --uninstall) UNINSTALL=1 ;;
    --noninteractive|-y) ;; # retained as a no-op for older docs/commands
    -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown: $arg" >&2; exit 1 ;;
  esac
done

say()  { printf "\033[1;36m▸\033[0m %s\n" "$*"; }
ok()   { printf "\033[1;32m✓\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m⚠\033[0m %s\n" "$*" >&2; }
err()  { printf "\033[1;31m✗\033[0m %s\n" "$*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$SCRIPT_DIR/../templates/superset-config.json"
HOOK_PATHS=(".superset/setup.sh" ".superset/run.sh" ".superset/teardown.sh")

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
  (( FORCE == 1 )) || err "Refusing to delete $TARGET without --force"
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

  # 2. Config references the split hook scripts it expects Superset to run.
  if jq -e '
    (.setup // []) | index("./.superset/setup.sh")
  ' "$TARGET" >/dev/null 2>&1 && \
     jq -e '(.run // []) | index("./.superset/run.sh")' "$TARGET" >/dev/null 2>&1 && \
     jq -e '(.teardown // []) | index("./.superset/teardown.sh")' "$TARGET" >/dev/null 2>&1; then
    ok "Config references .superset/setup.sh, run.sh, and teardown.sh"
  else
    warn "Config does not reference all expected .superset/*.sh hook scripts"
    WARN_COUNT=$((WARN_COUNT+1))
  fi

  # 3. Hook scripts exist and are executable.
  for hook_path in "${HOOK_PATHS[@]}"; do
    if [[ -f "$hook_path" ]]; then
      ok "Found $hook_path"
      if [[ -x "$hook_path" ]]; then
        ok "$hook_path is executable"
      else
        warn "$hook_path is not executable"
        WARN_COUNT=$((WARN_COUNT+1))
      fi
    else
      err "$hook_path missing — run: bash scripts/install-superset-config.sh --force"
    fi
  done

  # 4. setup.sh must use current marketplace plugin detection, must enforce an
  # origin/default freshness check, and must not reference removed runtime state.
  if [[ -f ".superset/setup.sh" ]]; then
    if grep -qE '\.claude/plugins/24hour-ClaudeCode|scripts/check-actions\.sh|PLUGIN_DIR=|loop-state.*\.md|\.claude/runtime/24hour-ClaudeCode' ".superset/setup.sh"; then
      warn ".superset/setup.sh contains stale project-local plugin path, removed check-actions.sh, or removed runtime-state references"
      WARN_COUNT=$((WARN_COUNT+1))
    else
      ok ".superset/setup.sh has no stale project-local plugin, check-actions, or runtime-state references"
    fi

    if grep -qF 'claude plugin list' ".superset/setup.sh"; then
      ok ".superset/setup.sh checks installed plugin state through Claude Code"
    else
      warn ".superset/setup.sh does not verify plugin state through 'claude plugin list'"
      WARN_COUNT=$((WARN_COUNT+1))
    fi

    if grep -qF 'git fetch origin --prune' ".superset/setup.sh" && grep -qF 'git merge-base --is-ancestor "$base_ref" HEAD' ".superset/setup.sh"; then
      ok ".superset/setup.sh verifies worktree base against latest origin/default"
    else
      warn ".superset/setup.sh does not enforce latest origin/default branch freshness"
      WARN_COUNT=$((WARN_COUNT+1))
    fi
  fi

  # 5. Committed?
  if (( LOCAL == 0 )); then
    for tracked_path in "$TARGET" "${HOOK_PATHS[@]}"; do
      if git ls-files --error-unmatch "$tracked_path" >/dev/null 2>&1; then
        ok "$tracked_path is tracked in git"
        if ! git diff --quiet HEAD -- "$tracked_path" 2>/dev/null; then
          warn "$tracked_path has uncommitted changes"
          WARN_COUNT=$((WARN_COUNT+1))
        fi
      else
        warn "$tracked_path is NOT tracked in git (new workspaces will miss it)"
        WARN_COUNT=$((WARN_COUNT+1))
      fi
    done
  fi

  # 6. Superset CLI presence
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
    ok "Kept existing $TARGET (use --force to overwrite)"
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

# Step 1: commit + push guidance (only for shared config). This script does not
# run git add/commit/push; committing belongs to the caller's workflow.
if (( LOCAL == 0 )); then
  echo "  ─── Step 1: commit + push (so teammates get this config) ───"
  all_shared_clean=1
  for tracked_path in "$TARGET" "${HOOK_PATHS[@]}"; do
    if ! git ls-files --error-unmatch "$tracked_path" >/dev/null 2>&1 || \
       ! git diff --quiet HEAD -- "$tracked_path" 2>/dev/null; then
      all_shared_clean=0
    fi
  done
  if (( all_shared_clean == 1 )); then
    ok "Already committed and clean."
  else
    echo "    git add $TARGET ${HOOK_PATHS[*]}"
    echo "    git commit -m 'Add Superset workspace config'"
    echo "    git push"
    echo ""
    warn "Commit and push from the surrounding skill or your normal git workflow."
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
  echo "  For CLI-created workspaces, pass --base-branch <default-branch> and let"
  echo "  .superset/setup.sh verify the branch contains latest origin/<default-branch>."
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
echo "  Right now, manually trigger the setup hook from the repo root:"
echo ""
echo "    ./.superset/setup.sh"
echo ""
echo "  Expected output:"
echo "    24hour-ClaudeCode — workspace setup"
echo "    ✓ ... / ⚠ ... health lines"
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
echo "  → Beginner setup flow:      README.md"
echo "  → Review-loop workflow:     skills/review-loop/SKILL.md"
