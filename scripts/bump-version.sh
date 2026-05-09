#!/usr/bin/env bash
# bump-version.sh — Bump the plugin version in lockstep across manifests.
#
# Updates the `version` field in:
#   .claude-plugin/plugin.json
#
# Validates that .claude-plugin/marketplace.json is internally consistent
# (the plugin entry references the same plugin). If marketplace.json gains
# a `version` field in a future schema change, also bumps that.
#
# Usage:
#   bash scripts/bump-version.sh patch | minor | major
#   bash scripts/bump-version.sh 1.2.3       # set explicit version
#   bash scripts/bump-version.sh --check     # report drift, do not modify

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_JSON="$REPO_ROOT/.claude-plugin/plugin.json"
MARKETPLACE_JSON="$REPO_ROOT/.claude-plugin/marketplace.json"

ok()   { printf "\033[1;32m✓\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m⚠\033[0m %s\n" "$*" >&2; }
err()  { printf "\033[1;31m✗\033[0m %s\n" "$*" >&2; exit 1; }

[[ -f "$PLUGIN_JSON" ]] || err "missing $PLUGIN_JSON"
[[ -f "$MARKETPLACE_JSON" ]] || err "missing $MARKETPLACE_JSON"

current=$(jq -r '.version // "0.0.0"' "$PLUGIN_JSON")

case "${1:-}" in
  --check)
    plugin_name=$(jq -r '.name' "$PLUGIN_JSON")
    market_plugin=$(jq -r --arg n "$plugin_name" '.plugins[]? | select(.name == $n) | .name' "$MARKETPLACE_JSON")
    if [[ -z "$market_plugin" ]]; then
      err "marketplace.json does not list plugin '$plugin_name'"
    fi
    ok "consistent: name=$plugin_name version=$current in plugin.json + listed in marketplace.json"
    exit 0
    ;;
  patch|minor|major)
    IFS='.' read -r maj min pat <<< "$current"
    case "$1" in
      patch) pat=$((pat + 1)) ;;
      minor) min=$((min + 1)); pat=0 ;;
      major) maj=$((maj + 1)); min=0; pat=0 ;;
    esac
    new="$maj.$min.$pat"
    ;;
  '')
    err "usage: $0 patch|minor|major | <semver> | --check"
    ;;
  *)
    if [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
      new="$1"
    else
      err "invalid argument: $1"
    fi
    ;;
esac

# Update plugin.json
tmp=$(mktemp)
jq --arg v "$new" '.version = $v' "$PLUGIN_JSON" > "$tmp"
mv "$tmp" "$PLUGIN_JSON"
ok "bumped plugin.json: $current → $new"

# If marketplace.json has a top-level version field (it doesn't today, but for forward-compat)
if jq -e '.version' "$MARKETPLACE_JSON" >/dev/null 2>&1; then
  tmp=$(mktemp)
  jq --arg v "$new" '.version = $v' "$MARKETPLACE_JSON" > "$tmp"
  mv "$tmp" "$MARKETPLACE_JSON"
  ok "bumped marketplace.json: $new"
fi

# Sanity: re-validate manifests
jq -e . "$PLUGIN_JSON" >/dev/null
jq -e . "$MARKETPLACE_JSON" >/dev/null
ok "manifests valid JSON"

echo ""
echo "Next: review the diff, commit, tag:"
echo "    git diff .claude-plugin/"
echo "    git add .claude-plugin/ && git commit -m 'chore: bump version to $new'"
echo "    git tag v$new"
