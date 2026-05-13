---
name: review-loop
description: Use when the 24hour-ClaudeCode Stop prompt says REVIEW_LOOP_CONTINUE or local implementation is complete and the current Claude Code session must drive PR review before stopping
hooks:
  Stop:
    - hooks:
        - type: prompt
          prompt: |
            Continue the active 24hour-ClaudeCode review loop in the current Claude Code session and current WorkTree.

            Complete the PR review loop: preflight; prove reviewable changes exist; inspect; verify; commit; push; bind CURRENT_HEAD_SHA in the current context; create or refresh the PR; wait for current-SHA GitHub review; read top-level and inline review output; fix blocking security and correctness findings; repeat until convergence; merge or enable auto-merge; or report the concrete blocker to the user.
          model: claude-opus-4-7
          timeout: 7200
          continueOnBlock: true
---

# Review Loop Skill

You are running the 24hour-ClaudeCode review loop in the **current Claude Code session** and the **current git WorkTree**.

The parent `Stop` prompt used the Skill tool to invoke this skill with this handoff:

```text
REVIEW_LOOP_CONTINUE

Use the `review-loop` skill (via the Skill tool) to run the complete PR review loop in this same Claude Code session and same WorkTree. Follow `skills/review-loop/SKILL.md` exactly. Do not stop until the PR is merged, auto-merge is enabled, or a concrete blocker is reported to the user.
```

That handoff is mandatory. Continue until the PR is merged, auto-merge is enabled, or a concrete blocker is reported to the user.

<EXTREMELY-IMPORTANT>
Do not start another Claude CLI.
Do not ask the user for confirmation before normal loop actions.
Do not switch WorkTrees.
Do not use another agent to fix code.

GitHub Claude Code Action is the reviewer.
This local Claude Code session is the fixer.
</EXTREMELY-IMPORTANT>

## What This Skill Owns

This skill owns the whole PR loop:

```text
preflight
-> inspect changes
-> run local checks
-> commit
-> push
-> create/update PR
-> wait for current-SHA GitHub review
-> read review output
-> fix blocking/important feedback
-> repeat
-> merge/auto-merge or report blocker
```

Hooks only tell Claude to use this skill via the Skill tool. Scripts only perform deterministic helper actions. Do not move this workflow into hooks or scripts.

## Repo Resolution

Always resolve the repo from the current working directory. Never store or reuse a global repo name.

Use:

```bash
pwd
git rev-parse --show-toplevel
git branch --show-current
git remote -v
gh repo view --json nameWithOwner --jq '.nameWithOwner'
```

Every `git`, `gh pr`, and `gh run` command in this skill acts on the repo/worktree represented by the current directory.

## No Local Loop State

Do not create, read, write, rename, or require a local loop-state markdown file.

The review loop is driven by the current Claude Code session plus GitHub and git facts:

- `CURRENT_HEAD_SHA="$(git rev-parse HEAD)"`
- the current branch and its upstream
- the current PR returned by `gh pr view`
- current-SHA GitHub Actions runs and PR review surfaces

Do not gate the loop on a previous local state file. If the loop cannot continue, report the exact blocker and shortest useful next command directly to the user.

## Hard Gates

Stop and report the blocker if any gate fails:

- Current checkout is not a git worktree.
- Current branch is protected: `main`, `master`, `develop`, `dev`, `staging`, `production`, `prod`, `release`, `release/*`, or `hotfix/*`.
- Current branch does not contain the latest `origin/<default-branch>` after `git fetch origin --prune`.
- `.claude/24hour-ClaudeCode.config.json` exists with `enabled=false`.
- `gh auth status` fails.
- Review evidence cannot be reliably tied to `CURRENT_HEAD_SHA`.
- Review output is stale, missing, ambiguous, or asks for human judgment.
- GitHub API access fails.
- Merge or auto-merge fails.

Never treat silence, missing comments, old PR comments, or old workflow runs as pass.

## Step 1: Preflight

Confirm this is a feature worktree:

```bash
git_dir="$(git rev-parse --git-dir 2>/dev/null || true)"
git_common="$(git rev-parse --git-common-dir 2>/dev/null || true)"
if [ -z "$git_dir" ] || [ "$git_dir" = "$git_common" ]; then
  # Stop: not in a git worktree
fi
```

Confirm branch safety:

```bash
branch="$(git branch --show-current 2>/dev/null || true)"
case "$branch" in
  main|master|develop|dev|staging|production|release|prod|release/*|hotfix/*)
    # Stop: protected branch
    ;;
esac
```

Verify GitHub access:

```bash
gh auth status
```

Confirm this branch is based on the latest remote default branch:

```bash
git fetch origin --prune
default_branch="$(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null || true)"
if [ -z "$default_branch" ]; then
  default_branch="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##' || true)"
fi
default_branch="${default_branch:-main}"
base_ref="origin/$default_branch"
if git rev-parse --verify "$base_ref" >/dev/null 2>&1 && ! git merge-base --is-ancestor "$base_ref" HEAD; then
  # Stop: branch is not based on latest origin/default branch
fi
```

Keep `default_branch`, `base_ref`, and `CURRENT_HEAD_SHA` in the current context. Do not write them to a local state file.

## Step 2: Inspect, Verify, Commit

Inspect the worktree:

```bash
git status --porcelain
git diff
```

If there are local changes:

1. Read `.claude/24hour-ClaudeCode.config.json` if present.
2. Compare changed paths against `danger_paths`.
3. Stop if sensitive paths are touched without explicit user approval.
4. Remove accidental generated files, debug logs, and unrelated cleanup.
5. Scan for obvious secrets:

```bash
git diff | grep -iE 'password|api[_-]?key|secret|token|bearer|x-api-key|aws_access_key' || true
```

6. Run configured checks:

```bash
jq -r '.checks.commands[]?' .claude/24hour-ClaudeCode.config.json 2>/dev/null
```

Execute each configured command before committing. If a check fails, fix it or report the failing command and short error summary.

Commit once:

```bash
git add -A
if [ "${ADDRESSING_REVIEW_FEEDBACK:-0}" = "1" ]; then
  git commit -m "fix: address Claude Code Action review feedback"
else
  git commit -m "chore: apply claude changes"
fi
```

Respect existing git hooks. Do not use `--no-verify`.

If there are no local changes, continue only if this branch already has an open PR. Otherwise report `no local changes and no open PR`.

## Step 3: Push And Bind Current SHA

Push:

```bash
git push -u origin HEAD
CURRENT_HEAD_SHA="$(git rev-parse HEAD)"
```

Keep `CURRENT_HEAD_SHA` in the current context. Every later review and merge decision must match this SHA.

If push fails, report the exact short push error.

## Step 4: Create Or Update PR

Find an open PR for the current branch:

```bash
gh pr view --json number,url,headRefOid,isDraft,state
```

If no PR exists:

```bash
gh pr create --fill
gh pr view --json number,url,headRefOid,isDraft,state
```

If draft:

```bash
gh pr ready
```

Record PR number and URL. Confirm:

```text
headRefOid == CURRENT_HEAD_SHA
```

If not, refresh once. If still not matching, report the mismatch and stop.

## Step 5: Wait For Current-SHA Review

Find review workflow runs for the current SHA:

```bash
gh run list --commit "$CURRENT_HEAD_SHA" --json databaseId,name,status,conclusion,headSha,createdAt,url
```

Accept only a run where:

```text
headSha == CURRENT_HEAD_SHA
status == completed
name is Claude Code Review, Claude Review, or the configured review workflow name
```

Wait with configured bounds:

```bash
jq -r '.repair.review_loop_timeout // 7200' .claude/24hour-ClaudeCode.config.json
jq -r '.repair.review_loop_interval // 20' .claude/24hour-ClaudeCode.config.json
```

If timeout expires or the matching run fails/cancels, report the run URL and conclusion.

## Step 6: Read Review Output

Do not assume a custom verdict artifact exists. Read real GitHub surfaces:

```bash
gh pr view "$PR" --json reviews,comments,statusCheckRollup,headRefOid,isDraft,state
gh api "repos/$(gh repo view --json nameWithOwner --jq .nameWithOwner)/pulls/$PR/comments" --paginate
gh run view "$RUN_ID" --json jobs,url,conclusion,status,headSha
```

Use only feedback reliably tied to `CURRENT_HEAD_SHA`:

- current-commit PR review submissions
- current inline review comments
- current check run details, annotations, and logs
- PR conversation comments only when clearly produced by the accepted current-SHA run

Classify:

```text
blocking / important -> must fix
minor / nit -> do not fix automatically unless low-risk and bundled with required work
unclear -> stop and report blocker
```

If no blocking or important feedback exists and the accepted current-SHA review run succeeded, this is pass-compatible. Still confirm PR `headRefOid` is `CURRENT_HEAD_SHA` before merge.

## Step 7: Rework Or Merge

If review requires changes:

1. Summarize blocking/important findings in the current response context.
2. Edit only cited files in this same WorkTree.
3. Run targeted verification.
4. Continue the loop in this same session until the new current-SHA review passes or a concrete blocker remains.

If review passes:

```bash
gh pr view "$PR" --json headRefOid,isDraft,state
gh pr checks "$PR"
gh pr merge "$PR" --auto --squash
```

If required external checks fail:

- current diff caused test/lint/type/build failure -> fix minimally in this WorkTree, verify, and let next Stop round continue
- infra/network/quota/flaky/missing secret/ambiguous failure -> report blocker
- same required check fails twice for same reason in this session -> report blocker

If `--auto` fails because the repo has no branch-protection gate, direct squash merge is allowed:

```bash
gh pr merge "$PR" --squash
```

Report completion only after merge succeeds or auto-merge is enabled.

## Blocker Reasons

Stop and report the exact reason for:

- not in a worktree
- protected branch
- runtime disabled
- missing GitHub authentication
- danger path without explicit approval
- local check failure that cannot be fixed safely
- push failure
- PR create/update failure
- PR head not equal to current SHA
- missing current-SHA review run
- failed/cancelled review workflow
- stale or ambiguous review evidence
- GitHub API failure
- human judgment required
- merge or auto-merge failure

When blocked, include the shortest useful next command or inspection pointer for the user. Do not write a local state file.
