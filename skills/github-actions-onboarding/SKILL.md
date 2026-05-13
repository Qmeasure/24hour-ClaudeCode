---
name: github-actions-onboarding
description: Use when this repo needs 24hour-ClaudeCode GitHub Actions workflow, config, secret, or Claude GitHub App setup before feature work can begin
---

# GitHub Actions Onboarding

You are running the onboarding workflow in this Claude Code session. The slash command and SessionStart bootstrap only point here; this skill owns the workflow.

Do not run or recreate a monolithic onboarding script. Use scripts only for deterministic file installation or version synchronization. GitHub setup checks are simple enough to run directly in this skill.

## Generic Repository Compatibility

- Do not assume a language, package manager, test command, branch protection policy, or hosting organization.
- Resolve the repository, default branch, and owner through `gh` instead of hardcoding names.
- Install only generic workflow/config files unless the user explicitly requests provider-specific additions such as Codex review.
- Preserve unrelated user files and unstaged changes; onboarding commits only workflow/config/runtime sentinel files.

## Explain The Scope

Tell the user this repo is not fully onboarded and that you will wire the reviewer side before feature work:

1. Verify `gh`, `git`, and Claude CLI prerequisites.
2. Ensure the current checkout is the main checkout, not a feature worktree.
3. Resolve or create the GitHub repo and remote.
4. Verify the Claude GitHub App and Actions secret.
5. Install workflow YAML from templates.
6. Seed `.claude/24hour-ClaudeCode.config.json` and runtime state directory.
7. Add `.Claude/` to the project root `.gitignore`.
8. Commit, push, and verify the resulting files.

## Preconditions

Run these checks first:

```bash
command -v git
command -v gh
command -v claude
gh auth status
```

If `gh` is unauthenticated or lacks workflow scope, stop and give the user the exact command:

```bash
gh auth refresh -h github.com -s workflow
```

Setup should run from the main checkout so workflow files land on the default branch. If this is a git worktree, stop and tell the user to rerun `/24hour-ClaudeCode:setup` from the main checkout.

## Resolve Repo

Resolve the repo:

```bash
REPO="$(gh repo view --json nameWithOwner --jq '.nameWithOwner')"
```

If there is no GitHub repo or `origin`, discuss the shortest safe path with the user. If they want you to create it, use `gh repo create` and then re-run the repo check. Do not guess repository ownership.

## Verify App And Secret

Check the Claude GitHub App best-effort through recent check suites:

```bash
DEFAULT_BRANCH="$(gh repo view "$REPO" --json defaultBranchRef --jq '.defaultBranchRef.name')"
gh api "repos/$REPO/commits/$DEFAULT_BRANCH/check-suites" \
  --jq '[.check_suites[] | select(.app.slug == "claude" and .app.owner.login == "anthropics")] | length'
```

If the result is `0`, send the user to `https://github.com/apps/claude`. This probe can be false-negative until a new commit is pushed after installation, so re-check after the onboarding push if needed.

Check Actions auth secret directly. A repo-level secret is sufficient:

```bash
gh api "repos/$REPO/actions/secrets/CLAUDE_CODE_OAUTH_TOKEN" --jq '.name'
```

If repo secret lookup returns 404, check whether an organization-level Actions secret is visible to this repo before calling the secret missing:

```bash
OWNER="${REPO%%/*}"
IS_PRIVATE="$(gh repo view "$REPO" --json isPrivate --jq '.isPrivate')"
ORG_SECRET_JSON="$(gh api "orgs/$OWNER/actions/secrets/CLAUDE_CODE_OAUTH_TOKEN" 2>/dev/null || true)"
ORG_SECRET_VISIBILITY="$(printf '%s' "$ORG_SECRET_JSON" | jq -r '.visibility // empty')"

case "$ORG_SECRET_VISIBILITY" in
  all)
    echo "CLAUDE_CODE_OAUTH_TOKEN is configured as an org Actions secret visible to all repos."
    ;;
  private)
    if [ "$IS_PRIVATE" = "true" ]; then
      echo "CLAUDE_CODE_OAUTH_TOKEN is configured as an org Actions secret visible to private repos, and this repo is private."
    else
      echo "CLAUDE_CODE_OAUTH_TOKEN org secret is private-only, but this repo is public."
    fi
    ;;
  selected)
    gh api "orgs/$OWNER/actions/secrets/CLAUDE_CODE_OAUTH_TOKEN/repositories" --paginate \
      --jq '.repositories[]?.full_name' | grep -qxF "$REPO" \
      && echo "CLAUDE_CODE_OAUTH_TOKEN is configured as an org Actions secret selected for this repo."
    ;;
  *)
    echo "No repo secret and no visible org Actions secret found."
    ;;
esac
```

Treat the secret as present when either the repo secret exists, or the org secret is visible through one of the `all`, matching `private`, or matching `selected` cases above. If missing, tell the user to generate and store the token. Prefer org-level secrets when appropriate:

```bash
claude setup-token
gh secret set CLAUDE_CODE_OAUTH_TOKEN --org <org> --visibility all
gh secret set CLAUDE_CODE_OAUTH_TOKEN --org <org> --repos <repo>
gh secret set CLAUDE_CODE_OAUTH_TOKEN -R <owner>/<repo>
```

Never write tokens into files, logs, comments, or commits.

## Install Workflows

Default to Claude review unless the user explicitly asks for Codex or both:

```bash
mkdir -p .github/workflows
cp "${CLAUDE_PLUGIN_ROOT}/templates/claude.yml" .github/workflows/claude.yml
cp "${CLAUDE_PLUGIN_ROOT}/templates/claude-code-review.yml" .github/workflows/claude-code-review.yml
```

For Codex review, also or instead install:

```bash
cp "${CLAUDE_PLUGIN_ROOT}/templates/codex-review.yml" .github/workflows/codex-review.yml
```

## Seed Config And Runtime

Create the config only if it is missing:

```bash
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
mkdir -p "$PROJECT_DIR/.claude"

if [ ! -f "$PROJECT_DIR/.claude/24hour-ClaudeCode.config.json" ]; then
  cp "${CLAUDE_PLUGIN_ROOT}/templates/24hour-ClaudeCode.config.json" "$PROJECT_DIR/.claude/24hour-ClaudeCode.config.json"
fi

mkdir -p "$PROJECT_DIR/.claude/runtime/24hour-ClaudeCode"
printf '*\n!.gitignore\n' > "$PROJECT_DIR/.claude/runtime/24hour-ClaudeCode/.gitignore"

touch "$PROJECT_DIR/.gitignore"
grep -qxF '.Claude/' "$PROJECT_DIR/.gitignore" || printf '\n.Claude/\n' >> "$PROJECT_DIR/.gitignore"
```

Do not add `.claude/` to the project root `.gitignore`; onboarding intentionally commits `.claude/24hour-ClaudeCode.config.json` and `.claude/runtime/24hour-ClaudeCode/.gitignore`.

## Commit And Push

Review the diff before committing:

```bash
git status --short
git diff -- .github/workflows .claude/24hour-ClaudeCode.config.json .gitignore
```

Commit only onboarding files:

```bash
git add .github/workflows .claude/24hour-ClaudeCode.config.json .claude/runtime/24hour-ClaudeCode/.gitignore .gitignore
git commit -m "chore: configure 24hour-ClaudeCode actions"
git push -u origin HEAD
```

If there are unrelated user changes, leave them unstaged.

## Verify

Verify the files directly:

```bash
test -f .github/workflows/claude.yml
test -f .github/workflows/claude-code-review.yml
test -f .claude/24hour-ClaudeCode.config.json
grep -qxF '.Claude/' .gitignore
grep -R "CLAUDE_CODE_OAUTH_TOKEN" .github/workflows/claude*.yml
grep -R "id-token: write" .github/workflows/claude*.yml
gh workflow list
```

If verification fails, fix the reported setup issue in this skill-controlled workflow, then rerun the same checks.

After success, tell the user:

> Setup complete. Open a worktree, start a fresh Claude Code session inside it, and use `/goal <your objective>` for feature work. After native `/goal` allows stopping, the Stop prompt can route to the `review-loop` skill.

## Boundaries

- Hook and slash command: only point to this skill.
- Skill: owns setup decisions and sequencing.
- Script: only deterministic file installation or version synchronization.
- Do not restore any script that probes GitHub setup, commits, pushes, waits, asks questions, or acts as the onboarding workflow engine.
