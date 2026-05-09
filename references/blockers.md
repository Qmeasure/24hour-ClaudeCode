# Blockers — the only authorized reasons to stop and ask

This skill's design is "don't stop mid-flow". The list below is the **complete** set of authorized stops. Anything not on this list, you continue.

## The 8 authorized blockers

### 1. Pre-flight #1 — not in a worktree

```
I only drive worktrees, not main checkouts. Create one with:
  git worktree add ../my-feature
…then re-enter Claude Code from inside that path.
```

### 2. Pre-flight #2 — on a protected branch

If `git branch --show-current` returns `main` / `master` / `develop` / `dev` / `staging` / `production` / `release` / `prod`:

```
You're on `<branch>`, which I treat as protected. I won't push there.
Switch to a feature branch (git switch -c feat/your-thing) and re-run.
```

### 3. Scope unclear after one ask

If after Step 3's single scope question the user gives an ambiguous answer ("um, fix the bug?"):

```
I need a one-line description of the change so I can write the commit message
and PR body. Examples:
  "fix the OAuth refresh race in auth/handler.ts"
  "add CSV export to /reports page"
  "rename `User.name` → `User.displayName` across the API"
What are we shipping?
```

If the second answer is still unclear, escalate (this case is rare).

### 4. DIRTY conflicts not on the safe-list

Conflict safe-list (resolve directly without asking):
- All conflicts are added-new-files (no overlap with base)
- All conflicts are lockfiles (`pnpm-lock.yaml` / `package-lock.json` / `yarn.lock` / `Cargo.lock` / `poetry.lock` / `go.sum`) — re-run install to regenerate

Anything else (real logic conflicts) → stop:

```
PR #<N> is DIRTY. Conflicts:
  - src/foo.ts
  - src/bar.tsx
These look like overlapping logic changes — I'll need your call. Should I:
  a) git fetch && git merge origin/<BASE>, then I attempt the merge?
  b) leave it for you to resolve manually?
```

### 5. Required CI check failed

CI failures may be real bugs, or external (third-party API down, runner OOM, flaky test). If the failure looks unrelated to your changes:

```
PR #<N> failed: <check name>
Log shows: <one-line summary>
This doesn't look like our code — possibly:
  - <hypothesis 1>
  - <hypothesis 2>
Should I retry the check, or do you want to investigate?
```

If the failure is clearly your bug, fix it without asking.

### 6. Reviewer asks you to edit a sensitive path

A review comment requesting a change to a path on `--disallowed-tools` (migrations, infra, .env.production, secrets, deploy keys, etc.). The disallow list is auto-built from `scripts/detect-project.sh`'s `DANGER_PATHS`.

```
Reviewer suggested editing <sensitive-path>, which is on this repo's
sensitive-paths list. By project policy, I won't auto-fix there.

Reviewer's suggestion:
  <quote>

How should I handle it?
  - Approve: tell me explicitly to make the edit
  - Reject:  I'll reply on the PR explaining why we keep it as-is
  - Defer:   leave the comment unaddressed; you handle it later
```

### 7. The Action workflow didn't run (or failed)

After PR open, if 5 minutes elapse and `reviewers` is still empty AND:

```bash
gh run list --workflow claude-code-review.yml --limit 3
```

shows 0 runs, or all are `failure` / `cancelled` → stop.

Likely causes:

| Symptom | Cause | Fix |
|---|---|---|
| No runs at all | YAML syntax error | `gh workflow view claude-code-review.yml` shows the parse error |
| Runs `failure` with 401 in logs | `CLAUDE_CODE_OAUTH_TOKEN` missing or expired | `claude setup-token` then `gh secret set` to overwrite |
| No runs, workflow `disabled` | App not installed on repo | https://github.com/apps/claude → Configure → add repo |
| Runs hit `usage limit exceeded` | Free runner quota (2000min/month) gone | Wait until next month or upgrade |
| Runs hit `rate_limit_exceeded` | Claude subscription daily quota gone | Wait 5 hours, or switch to API key auth |

```
⚠️ Claude Code Action isn't working on PR #<N>.
Current state: <gh run list output>
Likely cause: <row from table>
Suggested fix: <one command>

I can't continue babysitting (nothing to react to). Fix and I'll resume.
```

### 8. 60-minute wall-clock cap reached

If 60 minutes have passed since PR open and `state` is still `OPEN`:

```
⚠️ Hit the 60-minute cap on PR #<N>.
Current state: <state, mergeStateStatus, reviewers, checks summary>
History:
  <bullet list of every Monitor event so far>

Options:
  - Extend: I'll keep going if you say so
  - Hand off: take it from here
  - Abandon: gh pr close <N>
```

---

## Cases that look like blockers but aren't

| Situation that feels like "stop and ask" | Why you continue | What to do |
|---|---|---|
| Code is done, want user to review before push | The user authorized at worktree boundary; chat-review is wasted work | Push. Real review happens on the PR by `claude[bot]` |
| Auto-merge enabled, want to confirm | DoD is `state=MERGED`, not "auto-merge on" | Babysit |
| Lots of review feedback, unsure of priority | Severity matrix is in Step 9.3 — judge yourself | Adopt by default; reply-and-skip the unreasonable |
| 60 min approaching, want to ask whether to continue | The cap is the cap — when it hits, stop. Until then, keep going | Continue |
| `BEHIND` shows up | Base advanced, no conflicts → must update | `git fetch && git merge origin/<BASE> && git push` |
| Step 10 done, wonder if babysit is needed | Step 11 is the same continuation. Auto-merge can fail (BEHIND, conflicts, CI flakes) | Babysit anyway |
| 2-min wait window expired but not all reviewers have spoken | Tier B caps wait at 15 min; quiet by then = quiet | Wait until cap |
| 3rd round of review fixes — feels like a lot | Cap is 5 rounds + 60 min total | Continue until cap |

---

## Format for blocker messages

Three lines:

```
⚠️ <one-sentence reason for stopping>

<observation / data / quote>

<decision needed, with options>
```

Be terse. No "could you please" or "if it's not too much trouble". Give the user options, not open-ended questions.
