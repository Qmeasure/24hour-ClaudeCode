#!/usr/bin/env bash
# check-claude-app.sh — Detect whether the Claude GitHub App is installed on a repo.
#
# Why this is needed: GitHub's official endpoints for App-installation queries
# (`GET /repos/{owner}/{repo}/installation`, `GET /user/installations`) require
# App-JWT auth and reject user PATs with HTTP 401. So onboarding scripts that
# only have a user PAT cannot use the "official" route.
#
# This script uses a side-channel: the check_suites endpoint, which IS user-PAT
# accessible, returns one suite per "installed App with checks: write on this
# repo". If `claude` (app.slug) appears in the list for any recent commit, the
# App is installed. The Anthropic-owned Claude App is unique in this slug.
#
# Caveat: check_suites are created at COMMIT TIME for currently-installed Apps.
# Suites are not retroactively created for older commits if you install the App
# later. So this script may produce a false NEGATIVE in the brief window between
# "user clicked Install" and "user pushed a new commit". Callers should:
#   1. Run this best-effort right after the user confirms install.
#   2. Re-run AFTER the next push (e.g. after Step 5 in configure-actions.sh)
#      with the new HEAD SHA — that push triggers a new suite that will include
#      Claude if it's truly installed.
#
# Usage:
#   bash scripts/check-claude-app.sh <owner/repo> [<sha-or-branch>]
#     <sha-or-branch> defaults to the repo's default branch
#
# Exit codes:
#   0 → Claude App detected installed
#   1 → Claude App NOT detected (either truly missing, or App was installed
#         after this commit was pushed — see caveat above)
#   2 → Unable to query (repo not found, no commits, gh auth issue)
#
# Stdout: a status word (`installed` / `not-installed` / `unknown`) plus a short
# explanation. Callers may parse or just display.

set -uo pipefail

REPO="${1:-}"
REF="${2:-}"

if [[ -z "$REPO" ]]; then
  echo "unknown: missing repo argument (usage: check-claude-app.sh <owner/repo> [<sha-or-branch>])" >&2
  exit 2
fi

# Resolve ref to default branch if not specified
if [[ -z "$REF" ]]; then
  REF=$(gh api "repos/$REPO" --jq '.default_branch' 2>/dev/null || echo "")
  if [[ -z "$REF" ]]; then
    echo "unknown: cannot query repo $REPO (not found, or gh not authenticated, or no access)"
    exit 2
  fi
fi

# Query check_suites for that commit. The endpoint returns one suite per App
# that was installed at the time the commit was pushed.
suites_json=$(gh api "repos/$REPO/commits/$REF/check-suites" 2>/dev/null) || {
  echo "unknown: failed to query check_suites for $REPO@$REF (commit may not exist)"
  exit 2
}

# Check if "claude" appears in the slug list. Specifically, the slug owned by
# `anthropics` (defensive: someone could theoretically have a slug collision,
# though slugs are globally unique on GitHub.com so this is belt-and-braces).
claude_found=$(echo "$suites_json" | jq -r '
  [.check_suites[] | select(.app.slug == "claude" and .app.owner.login == "anthropics")] | length
' 2>/dev/null || echo "0")

if [[ "$claude_found" -ge 1 ]]; then
  echo "installed: Claude GitHub App detected on $REPO@$REF (check_suites side-channel)"
  exit 0
else
  echo "not-installed: Claude App not found in check_suites for $REPO@$REF. Either (a) it's truly not installed, or (b) it was installed AFTER this commit was pushed — try with a newer commit/SHA."
  exit 1
fi
