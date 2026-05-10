---
name: using-24hour-ClaudeCode
description: Bootstrap meta-skill auto-injected by the SessionStart hook of the 24hour-ClaudeCode plugin. Defines the auto-PR-loop runtime contract — how the Stop hook drives commit/push/PR/poll/decide, when to dispatch to phase skills, and how to respond when the hook returns `decision:block` with rework feedback. Use when in a project with this plugin installed and you've just received the runtime preamble; do not invoke directly.
---

# 24hour-ClaudeCode Runtime Contract

<EXTREMELY-IMPORTANT>
You are operating inside the **24hour-ClaudeCode** auto-PR-loop runtime. This document is the contract.

**The Iron Law:** Done means PR `state=MERGED`. Not "auto-merge enabled". Not "CI green". Not "review approved". Until the PR is merged or escalated, the loop continues.

The user authorized this loop the moment they entered this worktree. Do **not** ask permission to commit, push, open PRs, mark ready, or enable auto-merge. Those actions are done by the hook deterministically. Your job is to **edit code in response to feedback** that the hook feeds back to you.
</EXTREMELY-IMPORTANT>

## How the loop runs (Revision 2 — Stop hook owns it)

The plugin uses three hooks:

| Hook | When | What it does |
|---|---|---|
| **SessionStart** | Every session start, `/clear`, auto-compact | `bootstrap.sh` detects environment and injects this skill (you're reading the result). |
| **PostToolUse** (matcher: `Edit \| Write \| MultiEdit`) | After every code-modifying tool | `post-tool-use.sh` touches `<runtime>/dirty`. That's all. |
| **Stop** | When you finish a turn | `stop.sh` — the heavy worker. Mode-aware. See below. |

**Stop is the workhorse.** It's mode-aware via `<runtime>/state.json.mode`:

```
state.mode = idle / waiting_for_preflight_merge / waiting_for_checks / ready_for_rework / merged
```

```
                           ┌────────────────────────┐
                           │   Stop hook fires      │
                           │   (turn boundary)      │
                           └────────┬───────────────┘
                                    │
              ┌─────────────────────┼─────────────────────┐
              ▼                     ▼                     ▼
       mode=idle (or         mode=waiting_for_      mode=merged
       ready_for_rework)     checks                 ─────────────
       ─────────────         ─────────────          Cleanup state.
       diff non-empty?       Poll PR. Decide:       Reset to idle.
         yes →               • feedback_good →
           local checks        gh pr merge --auto
           commit              mode = merged
           push                Inform you ✅
           ensure PR
           mode = waiting    • rework_required →
                               mode = ready_for_rework
                               Output JSON:
                               {"decision":"block",
                                "reason":"<feedback>"}
                               ⚠️ This makes you
                                continue, not stop.

                             • inconclusive →
                               Inform you, retry
                               on next stop.
```

## When you receive `<24hour-ClaudeCode>` blocks

The Stop hook emits informational `additionalContext` blocks wrapped in `<24hour-ClaudeCode>...</24hour-ClaudeCode>`. Common ones:

- **"PR #N (draft) at <url>. CI starting."** → A new commit was just pushed. The next stop will poll. You can stop here, or make more edits if you have related fixes ready.
- **"PR #N is still running."** → CI hasn't finished. Stop here; it'll be checked next time.
- **"✅ PR #N merged."** → Done. Cleanup happens on the next stop. End the loop with a brief success message to the user.
- **"📦 Workflow file changes were auto-split into preflight PR #N."** → You edited a `.github/workflows/*.yml` file. The runtime opened a separate "preflight" PR with just the workflow changes (auto-merge enabled) and held the rest of your diff back. Wait for it to merge — see "When the runtime auto-splits workflow changes" below.
- **"⛔ STOP condition: ..."** → A hard stop fired. Invoke `failure-escalation` to format an escalation message; do NOT auto-retry.

## When the hook returns `{"decision":"block","reason":"..."}`

This is the rework-feedback mechanism. The Stop hook returns this JSON when:

- A local check failed before commit (lint/typecheck/test)
- A push was rejected
- An ensure-pr failure
- After polling: CI failed, or `CHANGES_REQUESTED`, or actionable comments present
- Edit touched a `danger_paths` entry

When you see `decision:block`, **you cannot stop**. Claude continues immediately. The `reason` is your context. Your job:

1. **Read the reason carefully.** It has file:line citations, log snippets, reviewer authors, severity.
2. **Invoke the right phase skill:**
   - `ci-feedback-analysis` — for CI failures
   - `review-feedback-analysis` — for `CHANGES_REQUESTED` or actionable comments
   - `rework-implementation` — to apply the fix per its discipline (minimal change, scope lock)
3. **Edit the cited file(s) and the cited file(s) only.** The PostToolUse hook marks `dirty`; the next Stop will commit + push and the cycle continues.
4. **Do not stop until the diff is fixed** OR a stop condition fires. The Stop hook will emit `feedback_good` (and merge) when feedback resolves.

## Phase skills you dispatch to

| Skill | When |
|---|---|
| `github-actions-onboarding` | Bootstrap detected onboarding incomplete; finish setup before any code edit |
| `verification-before-push` | Before any **manual** push you initiate (e.g., a `--force-with-lease` after `git commit --amend`). The Stop hook's auto-push runs an automated subset; this skill is your mental model for manual cases. |
| `rework-implementation` | After receiving `decision:block` with a rework reason, OR when amending the placeholder commit message. **Required reading for the loop.** |
| `ci-feedback-analysis` | When `decision:block` reason cites CI failure(s) |
| `review-feedback-analysis` | When `decision:block` reason cites reviewer comments / `CHANGES_REQUESTED` |
| `babysit-pr` | When you want to manually inspect PR state mid-loop (rare; the Stop hook owns the babysit) |
| `failure-escalation` | When the Stop hook says `⛔ STOP condition`, or `max_iterations` hit |

## Required actions after auto-commit (mandatory)

When the Stop hook reports a fresh commit ("Iteration #N. PR #M (draft) at..."), you should — on this turn or the next — improve the artifacts the hook wrote with placeholder values:

1. **Amend the commit message** to a Conventional Commit (`feat(scope):`, `fix(scope):`, etc.):
   ```bash
   git commit --amend -m "feat(auth): refresh OAuth before expiry"
   git push --force-with-lease
   ```
   Use `--force-with-lease` (never plain `--force`).

2. **Update PR body** with What / How tested / Closes #N:
   ```bash
   gh pr edit "$PR" --body "## What
   ...
   ## How tested
   - [x] typecheck/lint/test
   ## Linked issue
   Closes #<N>"
   ```

3. **Mark PR ready** (only after verify passes locally):
   ```bash
   gh pr ready "$PR"
   ```

These are NOT mandatory in iteration 1's first stop — the hook moves to `waiting_for_checks` immediately. But they should happen before the PR merges. You can do them on the same turn or any subsequent turn before `feedback_good` triggers auto-merge.

## When the runtime auto-splits workflow changes

If your edits include any `.github/workflows/*.yml` file, the Stop hook will automatically:

1. Open a small "preflight" PR (branch name `preflight/<your-branch>-workflow-<timestamp>`) carrying *only* the workflow changes.
2. Enable auto-merge on it (squash).
3. Park the rest of your diff in the working tree.
4. Set `state.mode = waiting_for_preflight_merge` and `state.preflight_pr = N`.

**Why this exists:** GitHub returns HTTP 401 ("Workflow validation failed") when auto-review tries to authenticate against a PR whose `.github/workflows/*.yml` differs from the default branch. That's a security policy — workflow files must already be on the default branch before they can authorize tokens. Bundling workflow + code in one PR breaks the auto-review loop.

**What you should do:**

- The hook will tell you the preflight PR number. **Do not edit aggressively** while waiting — small fixes are fine, but large new features should wait for the preflight to merge.
- Each subsequent stop polls the preflight PR. On `MERGED`, the hook rebases your branch and falls through to the normal commit/push flow on this same turn.
- On `OPEN`, the hook just informs you and waits.
- On `CLOSED-not-merged`, you'll get `⛔ STOP condition: stop:preflight_closed` — invoke `failure-escalation`.

**Branch-protection caveat:** auto-merge on the preflight PR depends on required checks completing. If you've configured `claude-code-review` as a *required* check in branch protection, the preflight will hang because the auto-review on a workflow-only PR also hits the 401. Don't make `claude-code-review` a required check; let it run as advisory.

**Already-committed workflow files:** if your branch's history (not just working tree) already contains a commit that touched `.github/workflows/`, the hook can't auto-split. It returns `decision:block` asking you to:

```bash
git reset HEAD~ -- .github/workflows/    # un-stage workflow files from the last commit
git commit --amend --no-edit              # rewrite the commit without them
```

Then re-trigger the stop and the auto-split runs cleanly.

**Override:** setting `repair.allow_workflow_in_pr=true` in `.claude/24hour-ClaudeCode.config.json` skips the split entirely. Workflow + code go in one PR; auto-review fails; manual review required. Only use this if you have a specific reason.

## Stop conditions (§Stop Conditions)

Only these reasons authorize the loop to stop. Anything else, you continue.

1. **Not in a worktree** — refuse to drive (caught at SessionStart).
2. **On a protected branch** (main / master / develop / etc.) — refuse to push.
3. **`gh auth` lost mid-loop** — instruct user to `gh auth login`, exit.
4. **`git push` rejected** — non-fast-forward, branch protection. Don't `--force`. Escalate.
5. **CI failed and looks unrelated** to your changes (third-party outage, runner OOM). Use `ci-feedback-analysis`; if it says "cannot fix here", escalate.
6. **Reviewer asks you to edit a `danger_paths` entry** — migrations, infra, .env.production, secrets dirs. Off-limits without explicit user approval.
7. **Same failure two iterations in a row** (`stop:repeated_failure`) — you're stuck. Escalate.
8. **`max_iterations` (default 5) hit** — `stop:max_iterations`. Escalate with timeline.
9. **Diff exceeds `max_diff_lines`** (default 500) — likely runaway repair. Escalate.
10. **Preflight PR closed without merging** (`stop:preflight_closed`) — the workflow-only auto-split PR was closed by user or required check failed. Escalate; ask user to reopen, override, or revert the workflow changes.

When a stop fires, invoke `failure-escalation` to format the user-facing message. The runtime keeps a complete event timeline in `<runtime>/last-run.json` — cite it.

## Forbidden behaviors

- **Never** stop after editing without responding to `decision:block` if returned. Reading the reason is mandatory.
- **Never** use `git commit --no-verify`, `git push --force` (use `--force-with-lease`), `git push --no-gpg-sign`, or any flag that bypasses hooks/signing.
- **Never** call `gh pr merge` yourself — the Stop hook handles auto-merge when feedback is good.
- **Never** delete the runtime lockfile manually. Use `/24hour-ClaudeCode:clear-lock` if it's stuck (after diagnosing why).
- **Never** disable the runtime to "make the loop simpler". If a specific repo shouldn't auto-loop, run `/24hour-ClaudeCode:disable` once; the user explicitly opts out.
- **Never** poll `gh pr view` ad-hoc as the loop's primary state source. The Stop hook + `<runtime>/feedback.json` are authoritative.

## Slash commands (debug only)

- `/24hour-ClaudeCode:status` — runtime state + last 5 events
- `/24hour-ClaudeCode:retry` — clear lock + manually trigger Stop pipeline
- `/24hour-ClaudeCode:setup` — re-run Actions onboarder
- `/24hour-ClaudeCode:enable` / `:disable` — toggle the runtime
- `/24hour-ClaudeCode:clear-lock` — last resort: nuke a stuck lock

These are escape hatches. **Do not depend on them for primary control flow.**

## Index of references

- `references/monitor-template.md` — Monitor verbatim (used by `babysit-pr` skill; usually you don't need it because the Stop hook polls)
- `references/decision-table.md` — event matrix for manual inspection
- `references/quality-gate.md` — review evaluation rules
- `references/blockers.md` — full descriptions of stop conditions
- `references/anti-patterns.md` — failure modes A–H
- `references/workflow-yaml.md` — Claude Code Action params reference
- `references/superset-integration.md` — Superset workspace integration
- `references/official-docs-cheatsheet.md` — official docs pitfalls
