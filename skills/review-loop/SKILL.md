---
name: review-loop
description: Use when the 24hour-ClaudeCode Stop prompt says REVIEW_LOOP_CONTINUE or local implementation is complete and the current Claude Code session must drive PR review before stopping
hooks:
  Stop:
    - hooks:
        - type: prompt
          prompt: |
            Continue the active 24hour-ClaudeCode review loop in the current Claude Code session and current WorkTree.

            Complete the PR review loop: preflight; prove reviewable changes exist; inspect; verify; commit; push; bind CURRENT_HEAD_SHA; create or refresh the PR; wait for current-SHA GitHub review; read top-level and inline review output; fix blocking security and correctness findings; repeat until convergence; merge or enable auto-merge; write REVIEW_LOOP_DONE or REVIEW_LOOP_STOPPED.
          model: claude-opus-4-7
          timeout: 7200
          continueOnBlock: true
---

# Review Loop Skill

You are running the 24hour-ClaudeCode review loop in the **current Claude Code session** and the **current git WorkTree**.

The parent `Stop` prompt used the Skill tool to invoke this skill with this handoff:

```text
REVIEW_LOOP_CONTINUE

Use the `review-loop` skill (via the Skill tool) to run the complete PR review loop in this same Claude Code session and same WorkTree. Follow `skills/review-loop/SKILL.md` exactly. Do not stop until the `review-loop` skill writes REVIEW_LOOP_DONE or REVIEW_LOOP_STOPPED.
```

That handoff is mandatory. Continue until this skill writes a terminal state.

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
-> merge or enable auto-merge
-> write terminal state
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

## State File

Maintain:

```text
.claude/runtime/24hour-ClaudeCode/review-loop-state.md
```

Allowed states:

```text
REVIEW_LOOP_ACTIVE
REVIEW_LOOP_DONE
REVIEW_LOOP_STOPPED
```

Every update must include:

```text
state: <REVIEW_LOOP_ACTIVE|REVIEW_LOOP_DONE|REVIEW_LOOP_STOPPED>
round: <number>
pr: <number or unknown>
current_head_sha: <sha or unknown>
last_review_source: <run/review/comment/check/unknown>
last_feedback_summary: <short summary>
last_failure_fingerprint: <empty or stable short fingerprint>
stop_reason: <empty unless stopped>
updated_at: <UTC ISO timestamp>
```

Ensure the runtime directory exists and keep its `.gitignore` as:

```text
*
!.gitignore
```

Do not commit `review-loop-state.md`.

## Hard Gates

Stop with `REVIEW_LOOP_STOPPED` if any gate fails:

- Current checkout is not a git worktree.
- Current branch is protected: `main`, `master`, `develop`, `dev`, `staging`, `production`, `prod`, `release`, `release/*`, or `hotfix/*`.
- `.claude/24hour-ClaudeCode.config.json` exists with `enabled=false`.
- `gh auth status` fails.
- The next round exceeds `.repair.max_iterations // 5`.
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
  # REVIEW_LOOP_STOPPED: not in a git worktree
fi
```

Confirm branch safety:

```bash
branch="$(git branch --show-current 2>/dev/null || true)"
case "$branch" in
  main|master|develop|dev|staging|production|release|prod|release/*|hotfix/*)
    # REVIEW_LOOP_STOPPED: protected branch
    ;;
esac
```

Verify GitHub access:

```bash
gh auth status
```

Read max rounds:

```bash
jq -r '.repair.max_iterations // 5' .claude/24hour-ClaudeCode.config.json 2>/dev/null
```

Write or refresh `review-loop-state.md` with `REVIEW_LOOP_ACTIVE`. If prior state is `REVIEW_LOOP_DONE` or `REVIEW_LOOP_STOPPED`, continue only when the user intentionally retried or cleared the state.

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

Execute each configured command before committing. If a check fails, fix it or write `REVIEW_LOOP_STOPPED` with the failing command and short error summary.

Commit once:

```bash
git add -A
if grep -qi '^last_feedback_summary: .' .claude/runtime/24hour-ClaudeCode/review-loop-state.md 2>/dev/null; then
  git commit -m "fix: address Claude Code Action review feedback"
else
  git commit -m "chore: apply claude changes"
fi
```

Respect existing git hooks. Do not use `--no-verify`.

If there are no local changes, continue only if this branch already has an open PR. Otherwise write `REVIEW_LOOP_STOPPED` with `no local changes and no open PR`.

## Step 3: Push And Bind Current SHA

Push:

```bash
git push -u origin HEAD
CURRENT_HEAD_SHA="$(git rev-parse HEAD)"
```

Record `CURRENT_HEAD_SHA` in the state file. Every later review and merge decision must match this SHA.

If push fails, write `REVIEW_LOOP_STOPPED` with the exact short push error.

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

If not, refresh once. If still not matching, write `REVIEW_LOOP_STOPPED`.

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

If timeout expires or the matching run fails/cancels, write `REVIEW_LOOP_STOPPED` with the run URL and conclusion.

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
unclear -> REVIEW_LOOP_STOPPED
```

If no blocking or important feedback exists and the accepted current-SHA review run succeeded, this is pass-compatible. Still confirm PR `headRefOid` is `CURRENT_HEAD_SHA` before merge.

## Step 7: Rework Or Merge

If review requires changes:

1. Summarize blocking/important findings in the state file.
2. Compute `last_failure_fingerprint` from normalized finding identity such as `path:title` plus failing check name.
3. If `.repair.stop_on_repeated_failure // true` and the fingerprint repeats, write `REVIEW_LOOP_STOPPED`.
4. Edit only cited files in this same WorkTree.
5. Run targeted verification.
6. End the turn after the fix. The Stop prompt will invoke/load this skill again for the next round.

If review passes:

```bash
gh pr view "$PR" --json headRefOid,isDraft,state
gh pr checks "$PR"
gh pr merge "$PR" --auto --squash
```

If required external checks fail:

- current diff caused test/lint/type/build failure -> fix minimally in this WorkTree, verify, and let next Stop round continue
- infra/network/quota/flaky/missing secret/ambiguous failure -> `REVIEW_LOOP_STOPPED`
- same required check fails twice for same reason -> `REVIEW_LOOP_STOPPED`

If `--auto` fails because the repo has no branch-protection gate, direct squash merge is allowed:

```bash
gh pr merge "$PR" --squash
```

Write `REVIEW_LOOP_DONE` only after merge succeeds or auto-merge is enabled.

## Stop Reasons

Write `REVIEW_LOOP_STOPPED` for:

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
- repeated required feedback
- GitHub API failure
- human judgment required
- max rounds reached
- merge or auto-merge failure

When stopped, include the shortest useful next command or inspection pointer for the user.
