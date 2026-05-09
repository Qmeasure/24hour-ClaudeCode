# Quality gate — multi-agent review evaluation

The center of Step 9. Goal: **adopt every valid piece of feedback** (yes, including Minor / Nit) without getting trapped in noise loops.

## 0. Timing tiers (non-negotiable)

Two tiers depending on which review agents your repo has installed.

### Tier A — Claude Code Action only (this skill's default)

| Time since PR open | Action |
|---|---|
| t = 0 | `gh pr create` complete |
| t = 0 | Arm Monitor immediately (the `reviewers=` field is what drives new events) |
| t < 2 min | **Do not enter Step 9.3.** Action runner cold start (queue + checkout + Claude reading) takes 30–60s, then Claude is actually reading. |
| 2 min ≤ t < 8 min | Reviews landed → enter Step 9.3. Nothing yet → keep waiting |
| t = 8 min | Hard cap. Take whatever's there → 9.3. Total silence → go to Step 10 |
| Whole gate | ≤ 60 min wall clock total |

**Why 2 minutes:** Claude Code Action typically posts the first review within 30s–2min cold-start time. Waiting until the 2-minute mark before reading reviews avoids skimming half-formed output.

### Tier B — Action + third-party agents (Codex, Copilot, etc.)

| Time since PR open | Action |
|---|---|
| t = 0 | `gh pr create` + arm Monitor |
| t < 5 min | **Do not enter Step 9.3.** Even if Action says "no concerns", give third-party agents room to speak |
| 5 min ≤ t < 15 min | Reviews landed → 9.3. Silence → keep waiting |
| t = 15 min | Hard cap. 9.3 with whatever's there. Total silence → Step 10 |
| Whole gate | ≤ 60 min |

**Why 5 minutes:** Third-party GitHub Apps trigger via webhook with avg 3–5 min to first comment. Going to Step 10 at 90s because Action said "OK" silently skips them.

### How to detect your tier

```bash
# What review agents does the repo have?
ls .github/workflows/ | grep -E '(claude|codex|copilot|review)'

# What reviewer accounts has this PR seen?
gh pr view <N> --json reviews --jq '[.reviews[]?.author.login] | unique'
```

Default is **Tier A** (this skill's standard assumption). If yours is Tier B, the rest of this document applies — only the time windows change to 5/15.

## 1. Severity matrix

> **Project tailoring:** the Reject list is a *generic baseline*. Real Reject boundaries come from your repo's `CLAUDE.md` / `AGENTS.md` / `STYLE_GUIDE.md` top-of-file rules. Append project-specific lines at the bottom of this section.

### Reject — block merge, return to Step 4

If any of these triggers, the PR shouldn't have been opened in this shape. Generic absolute boundaries:

1. Modifying signing keys, certs, keystores, or any credential file
2. Putting any secret into a client-bundled variable (typical dangerous prefixes: `EXPO_PUBLIC_*`, `NEXT_PUBLIC_*`, `VITE_*`, `REACT_APP_*`, `PUBLIC_*`)
3. Modifying `.env.production`, `.env.staging`, or third-party platform secrets without human review
4. Pushing directly to a protected branch, bypassing PR
5. Production schema changes lacking idempotence (`IF NOT EXISTS`, rollback script, expand-contract migration)
6. Hardcoding user PII into LLM prompts or third-party API calls

**Project-specific Rejects** (maintainers fill in):

```
- <line 1, e.g.: "no edits to <dir>/", "no use of <library>", "no direct DB writes outside repository layer">
- <line 2>
```

### Major — fix or justify, but must respond

Generic checklist:

1. Missing input validation at a system boundary (route handler / external API)
2. SQL injection risk (string concat vs parameterized query)
3. N+1 query (await in a loop)
4. Unhandled Promise rejection / swallowed errors with no logging
5. Producer/consumer naming mismatch in queues / messaging
6. Violating a project hard-rule from `CLAUDE.md` (design tokens, naming rules, mandatory components)
7. Material performance regression (algorithmic complexity, sync I/O in hot paths)
8. Breaking API compatibility (renamed field, changed return shape) without versioning

### Minor — note + skip if not central

1. Test coverage missing for important branch
2. Naming ambiguity, could be more specific
3. Duplicated code that should extract a helper

### Ignore — do not adopt this kind of feedback

- Line width / indent / blank lines (formatter's job)
- Comment density / style (unless misleading)
- Variable name style (unless against project convention)
- Commit-message format

## 2. Multi-agent feedback merge

When ≥2 agents speak, evaluate per the table:

| Situation | Action |
|---|---|
| Multiple agents flag the same issue | Priority +1 (weak signals stack into a strong signal); fix regardless of original severity |
| Single agent speaks, others silent | Apply original severity (Reject/Major must fix; Minor/Nit evaluate then fix if reasonable) |
| **Any severity, genuinely valid feedback** | Fix in Step 9.4, including Minor / Nit / style |
| Genuinely invalid feedback | Reply on the PR explaining why; skip ("project convention", "violates CLAUDE.md top rule") |
| Agent conflict (A says add cache; B says don't) | Default to project `CLAUDE.md`. No explicit rule → keep current state, reply explaining |

### Telling valid from invalid

Valid feedback signals:
- Cites specific code lines, data, or doc reference
- Names the consequence (runtime bug / security hole / perf issue)
- Suggests an actionable fix (not a vague "consider improving")

Invalid feedback signals:
- Vague suggestion ("consider better naming")
- Directly conflicts with `CLAUDE.md` top rules
- Misread context (agent thinks file X is part of unrelated module Y)

### Special case — merge-commit confusion

If a reviewer flags base-branch changes that the merge commit pulled in (PR diff is 5 files but reviewer comments on 50 unrelated lines), confirm the actual diff:

```bash
gh pr view <N> --json files --jq '[.files[]?.path] | sort | join("\n")'
```

Then reply: "Confirmed PR diff is only X files; the lines mentioned came from a base-branch merge and are out of scope."

## 2.5 The Action self-fix path

If your repo has `claude.yml` (the `@claude` interaction workflow), you have two fix paths:

### Path A — local fix (classic)

```bash
git add <files>
git commit -m "review: address <agent> on PR #<N> — <one-line summary>"
git push
```

### Path B — delegate to the Action

Comment on the PR:

```
@claude fix the race condition on src/foo.ts:47, add SELECT FOR UPDATE
```

`claude.yml` triggers; Action checks out, edits, commits, pushes to the PR branch. New commit appears in 30s–3min.

### Picking a path

| Scenario | Path |
|---|---|
| Multi-file, judgment-heavy, project-context-needed | A — you understand the whole better than the Action |
| Single-line, reviewer cited file:line clearly | B — saves time |
| Touches sensitive paths (.env.production, etc.) | A, plus this is `blockers.md` #6 |
| Feedback is ambiguous / you want to reject | Neither — reply on PR |

### Path B caveats

- Action commit triggers a new `pull_request: synchronize`, Monitor catches the `reviewers=` change → loop back to 9.2 for fresh review. **Don't skip the new wait.**
- If `claude.yml` has `permissions: contents: read`, the Action can't push. It posts a comment saying "no permission". Fix: edit YAML, set `contents: write`.
- If the Action fails (quota / 401 / timeout), it does NOT auto-retry. Check `gh run list -w claude.yml --limit 1`. If failed, switch to Path A or fix the underlying issue.

## 3. Anti-loop limits

| Limit | Threshold | What happens at the threshold |
|---|---|---|
| Same suggestion adopted | ≤ 2 times | 3rd time same agent says it → reply "evaluated multiple times, keeping as is", skip |
| Total wall clock | ≤ 60 min | Force Step 10 |
| Tier A wait per round | ≤ 8 min | Whatever's there → 9.3 |
| Tier B wait per round | ≤ 15 min | Whatever's there → 9.3 |
| Wait for `@claude` to commit fix | ≤ 5 min | No new commit by 5 min → check `gh run list -w claude.yml`, fall back to Path A if failed |

## 4. Commit message template for fix commits

```
review: address <agent> on PR #<N> — <one-line summary>

- adopted <agent A>'s <X> suggestion (reason: valid + multi-agent agreement)
- adopted <agent B>'s <Y> suggestion (reason: Major)
- skipped <agent C>'s <Z> suggestion (reason: conflicts with CLAUDE.md ignore-list, replied on PR)

Co-Authored-By: Claude <noreply@anthropic.com>
```

## 5. After push, loop back to 9.2

A push triggers:
- CI re-runs (typecheck / lint / test)
- Every review agent re-reviews (Actions on `pull_request: synchronize`; Apps similarly)

**Do not skip the wait window** going straight to Step 10 — the re-review may surface new issues.

A single PR may loop 9.2 ↔ 9.4 two or three times before all reviewers go silent.

## 6. "All silent" / "all approved" — gate exit

Enter Step 10 when any of:

- Every speaking agent has `reviewDecision=APPROVED`
- Every comment from every agent has been replied to (adopted or explained)
- Tier A: 8 min of total silence; Tier B: 15 min of total silence
- 60-minute wall-clock cap

When the condition is met → run `gh pr merge --auto --merge <N>` immediately. Do not ask the user.

⚠️ **Tier A silence backstop:** if 8 min elapse and `reviewers=` is still empty, run `gh run list -w claude-code-review.yml --limit 3`. If the workflow never ran or all runs failed → this is `blockers.md` #7 (Actions didn't trigger), stop and tell the user.

## 7. Legitimate "PR too small, agent skipped" outcome

Several built-in review agents (claude-review, the official `code-review` plugin) have system prompts that effectively say:

> "If the PR is <30 lines of pure docs / typo / changelog, just respond 'looks good, skipping detailed review'."

PRs of that shape (typo, single-line README, dependency patch bump) get total agent silence — and that's **normal**, not a failure mode. Tier A: 8 min silence → Step 10. Tier B: 15 min → Step 10.

Don't panic and ask the user. **Precondition:** confirmed the workflow actually ran via `gh run list` (not a config issue, just an intentional skip).
