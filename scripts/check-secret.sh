#!/usr/bin/env bash
# check-secret.sh — Detect whether a specific GitHub Actions secret exists on a repo.
#
# Uses the precise probe: `GET /repos/{owner}/{repo}/actions/secrets/{name}`.
# This endpoint is user-PAT accessible (requires repo scope and admin access on
# the repo), returns 200 + metadata when the secret exists, and 404 when not.
# It NEVER returns the secret's value — GitHub never exposes secret values via
# the API; only `name`, `created_at`, `updated_at`.
#
# Why precise probe instead of `gh secret list | grep`:
#   - The list endpoint can paginate; precise probe is one HTTP call regardless.
#   - The 200/404 binary answer maps directly to exit codes without text parsing.
#   - Same approach scales to verifying many secrets cheaply.
#
# Usage:
#   bash scripts/check-secret.sh <owner/repo> <SECRET_NAME>
#
# Exit codes:
#   0 → secret exists (prints "exists: NAME created=... updated=..." to stdout)
#   1 → secret does not exist (prints "missing: NAME")
#   2 → cannot determine (auth error, repo not found, missing permission)

set -uo pipefail

REPO="${1:-}"
SECRET="${2:-}"

if [[ -z "$REPO" || -z "$SECRET" ]]; then
  echo "unknown: missing args (usage: check-secret.sh <owner/repo> <SECRET_NAME>)" >&2
  exit 2
fi

# Probe. `gh api` exits non-zero on 404, so check both stdout and exit.
response=$(gh api "repos/$REPO/actions/secrets/$SECRET" 2>&1)
api_exit=$?

if (( api_exit == 0 )); then
  # 200 OK — parse metadata
  created=$(echo "$response" | jq -r '.created_at // "?"' 2>/dev/null)
  updated=$(echo "$response" | jq -r '.updated_at // "?"' 2>/dev/null)
  echo "exists: $SECRET created=$created updated=$updated"
  exit 0
fi

# Non-200. Discriminate 404 (missing) from 401/403 (auth/permission).
if echo "$response" | grep -qi "HTTP 404\|Not Found"; then
  echo "missing: $SECRET (no such secret on $REPO)"
  exit 1
fi
if echo "$response" | grep -qi "HTTP 401\|HTTP 403\|Bad credentials\|Resource not accessible"; then
  echo "unknown: auth/permission issue probing $SECRET on $REPO. Need repo admin access + gh auth with repo scope."
  exit 2
fi

# Anything else
echo "unknown: unexpected gh api response probing $SECRET on $REPO. Raw: $(echo "$response" | head -1)"
exit 2
