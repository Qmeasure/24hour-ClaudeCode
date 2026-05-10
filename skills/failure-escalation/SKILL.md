---
name: failure-escalation
description: Format the user-facing escalation message when a stop condition fires. Use when check-stop-conditions.sh returns a non-`continue` token, or when babysit-pr hits the 60-minute cap, or when ci-/review-feedback-analysis cannot resolve and hands off. Cites blockers.md for full descriptions of each stop reason.
---

# Failure Escalation

You're here because the loop stopped. Your job: produce a terse, actionable user-facing message **and exit**. Do not retry on your own.

## Iron Law

<EXTREMELY-IMPORTANT>
**One message, three sections, then exit.** Do not append "let me know what you think" or "want me to retry?". The user reads, decides, instructs.
</EXTREMELY-IMPORTANT>

## Required structure

```
⚠️ <one-sentence reason for stopping>

<observation block: what happened, with data>

<options block: what the user can do next, in numbered options>
```

## Reading runtime context

Before writing the message, gather facts:

```bash
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
RUNTIME="$PROJECT_DIR/.claude/runtime/24hour-ClaudeCode"

cat "$RUNTIME/state.json" | jq        # iteration, branch, repo
cat "$RUNTIME/current-pr.json" | jq   # PR number, URL
cat "$RUNTIME/last-run.json" | jq     # last status, fail_streak
cat "$RUNTIME/feedback.json" | jq     # last poll snapshot
```

The escalation must cite **specific** facts from these — never vague summaries.

## Per-stop-condition templates

### `stop:max_iterations`

```
⚠️ PR #<N> hit the 5-iteration cap on the auto-PR loop.

  iteration: 5/5
  branch:    <branch>
  PR URL:    <url>
  last 3 events:
    - <ts> committed (sha=<sha>, pr=<N>)
    - <ts> failed:<cmd> — <one-line>
    - <ts> committed (sha=<sha>, pr=<N>)

The loop's adopting the same feedback repeatedly without resolving.

Options:
  1. Take the PR over manually: review the latest review comments at <url>, fix locally, push.
  2. Reset the iteration counter: bash scripts/runtime-state.sh set iteration 0 (use only after you've actually intervened).
  3. Increase max_iterations in .claude/24hour-ClaudeCode.config.json (last resort; usually a sign the loop can't make progress).
```

### `stop:repeated_failure`

```
⚠️ PR #<N> failed the same check twice in a row — repair loop is stuck.

  iteration:    <N>
  failed check: <name>
  fail_streak:  <streak count>
  last error:   <one-line excerpt from feedback.json>

Two iterations of `rework-implementation` haven't fixed this.

Options:
  1. Investigate manually: gh run view --log-failed <run-id> | tail -100
  2. The failure may be environmental (third-party flake). Run `gh run rerun <id> --failed` once, then resume.
  3. Edit the test/check to be skipped if it's known-flaky (only with explicit user approval).
```

### `stop:protected_branch`

```
⚠️ Refusing to push to protected branch `<branch>`.

The 24hour-ClaudeCode runtime never pushes to main / master / develop / staging / etc.

Options:
  1. Switch to a feature branch: git switch -c feat/<name>
  2. The auto-loop will engage on the new branch. Re-edit your file to trigger the on-edit hook.
```

### `stop:gh_auth_lost`

```
⚠️ gh CLI is no longer authenticated mid-loop.

  current state: <state.json iteration> at branch <branch>
  PR (if any):   <url>

Options:
  1. Re-authenticate: gh auth login
  2. After auth, re-edit a file in the worktree to re-trigger the on-edit hook.
```

### `stop:push_rejected`

```
⚠️ git push was rejected.

  branch:       <branch>
  push log:     <last few lines from last-run.json detail>

Likely a non-fast-forward (someone else pushed to this branch) or branch protection.

Options:
  1. Pull and rebase: git fetch origin <branch> && git rebase origin/<branch>
     Then re-push (the next on-edit will retry, OR run /24hour-ClaudeCode:retry).
  2. If branch protection is the issue: ask the user to grant push access, or PR to a different branch.
```

### `stop:diff_too_large`

```
⚠️ PR diff exceeds <max_diff_lines> lines (currently <actual>).

The repair loop appears to be expanding scope rather than narrowing.

Options:
  1. Take over manually and split: revert the latest unrelated changes; keep only the originally-intended scope.
  2. Increase max_diff_lines in .claude/24hour-ClaudeCode.config.json (only if the original feature genuinely needs that scope).
  3. Open a fresh PR with just the focused changes; abandon this one.
```

### `stop:preflight_closed`

```
⚠️ Preflight workflow PR #<N> was closed without merging.

  preflight PR:  <url>
  parent branch: <branch>
  reason (if known): <one-line from last-run.json detail>

The preflight PR carried only `.github/workflows/*.yml` changes. It needs to land on the default branch BEFORE the auto-review on the main branch's PR can authenticate (GitHub HTTP 401 workflow-validation policy).

Options:
  1. Reopen and merge PR #<N> manually: gh pr reopen <N> && gh pr merge <N> --squash
  2. Bundle workflow + code in one PR (skip the split): set `repair.allow_workflow_in_pr=true` in .claude/24hour-ClaudeCode.config.json. Auto-review will fail on the combined PR; manual review required.
  3. Revert the workflow changes locally so the loop resumes without them: git checkout origin/<base> -- .github/workflows/<file>
  4. Likely cause: `claude-code-review` is configured as a *required* branch-protection check. The preflight PR's own auto-review hits the same 401 and never goes green. Make claude-code-review advisory (not required) and reopen.
```

### `stop:committed_workflow_changes`

```
⚠️ Workflow file changes are in committed (un-pushed) history; the auto-split can only handle working-tree changes.

  branch:        <branch>
  files in commits:
    - .github/workflows/<file>

Resolve manually:
  git reset HEAD~ -- .github/workflows/    # un-stage workflow files from the last commit
  git commit --amend --no-edit              # rewrite the commit without them

Then re-trigger the stop hook (e.g., make a trivial edit elsewhere) and the plugin will auto-split the workflow files into a preflight PR.

Override (NOT recommended): set `repair.allow_workflow_in_pr=true` in .claude/24hour-ClaudeCode.config.json to skip the split. The combined PR will get HTTP 401 on auto-review and require manual review.
```

### `stop:danger_path`

```
⚠️ Edit touched a sensitive (danger_path) file: <path-list>

The runtime never auto-commits changes to migrations / infra / secrets / .env.production / etc.

Options:
  1. Revert: git checkout -- <path>; let the runtime resume.
  2. Make the edit manually with explicit user approval, then continue.
  3. Update .claude/24hour-ClaudeCode.config.json danger_paths if this path shouldn't be on the list.
```

### Babysit timeout (60 min cap)

```
⚠️ PR #<N> hit the 60-minute babysit cap.

  current state:   <state>
  merge status:    <mergeStateStatus>
  reviewers:       <list>
  recent events (last 5):
    - <ts> <event>
    - ...
  PR URL:          <url>

Options:
  1. Inspect at <url>; common reasons: required reviewer hasn't approved, or CI is slow.
  2. Take over: I exit; you continue manually.
  3. Restart babysit: invoke the babysit-pr skill again (resets the wall-clock).
```

## After emitting the message

- Mark `last_status` = the stop token: `bash scripts/runtime-state.sh set last_status "<stop:token>"`
- Stop **all** further work this turn. No `gh pr ...`, no `git ...`, no extra polling.
- The user reads and decides. They will instruct you to retry, take over, or change config.

## Forbidden behaviors

- ❌ Retrying after a stop without explicit user permission
- ❌ Adding "want me to retry?" / "let me know what you think" — the user knows their options
- ❌ Hiding facts to make the message shorter (cite SHAs, PR numbers, file paths exactly)
- ❌ Editing config files autonomously to "make the loop work" (e.g., bumping max_iterations) — that's user judgment
