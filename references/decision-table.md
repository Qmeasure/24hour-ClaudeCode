# Babysit decision table

This is a manual diagnostic reference for legacy babysit flows. In normal 24hour-ClaudeCode operation, `stop.sh` and the current-SHA `status-*.json` / `verdict-*.json` files are authoritative.

## Event format

Each Monitor line: `PR#<N> HH:MM:SS | state=X merge=Y checks=A:F,B:S,... reviewers=A,B,...`

## 1. `state` field

| Value | Action |
|---|---|
| `OPEN` | Continue watching the other fields |
| `MERGED` | Exit ✅. Send the user the success message (template below) |
| `CLOSED` (not merged) | `gh pr view <N> --json closedAt,closedReason` for cause, tell the user, exit |
| `ERR` | Single ERR is benign. 3 consecutive ERRs → tell user `gh` is broken, exit |

## 2. `mergeStateStatus` field

| Value | Meaning | Action |
|---|---|---|
| `CLEAN` | No conflicts, all merge conditions met | Stay silent, auto-merge takes over |
| `UNSTABLE` | At least one non-required check failed | Stay silent (doesn't block merge) |
| `BLOCKED` | Required check pending, or approval missing | Stay silent, wait |
| `BEHIND` | Base branch advanced, **no conflicts** | **Must update manually** (see below) |
| `DIRTY` | Conflicts present | Resolve (see below) |
| `UNKNOWN` | GitHub still computing | Silent, next tick will refresh |

⚠️ If branch protection has "Require branches up-to-date before merging", auto-merge **does not auto-pull** on `BEHIND` — you must push the update. Confirm with `gh repo view --json branchProtectionRules`.

### Handling `BEHIND` (no conflicts)

Run without asking (replace `<BASE_BRANCH>` with the actual base):

```bash
git fetch origin <BASE_BRANCH>
git merge origin/<BASE_BRANCH> --no-edit
git push
```

The Monitor will pick up `merge=CLEAN` (or the next round's `reviewers=`) and continue.

### Handling `DIRTY` (conflicts)

Default: tell the user you're about to fetch+merge and ask to confirm. Two exceptions where you can proceed without asking:

- All conflicts are added-new files (both sides added a file with the same name; rebase noise — keep your version unless overlap is suspicious)
- All conflicts are lockfiles (`pnpm-lock.yaml` / `package-lock.json` / `yarn.lock` / `Cargo.lock` / `poetry.lock` / `go.sum`) — re-run the install command to regenerate

Anything else (real logic conflicts) → see `blockers.md` #4.

## 3. `statusCheckRollup` field

Format: `name1:conclusion1,name2:conclusion2,...` e.g. `test:success,claude-review:success,build:failure`

| Saw | Action |
|---|---|
| Any `:failure` | **Do not auto-retry.** Exit babysit, tell user the failed check name + log command |
| Any `:cancelled` | Treat like failure |
| All `:success` or `:skipped` | Stay silent, wait |
| `:pending` / `:in_progress` | Stay silent, wait |

Failure message template (see `blockers.md` #5 for the full version):

```
❌ PR #<N> CI failed:
- <check name>: failure
Log: gh run view --log-failed --job=<job_id>
(Get job_id from: gh pr checks <N>)
I exited babysit. Push a fix and I'll resume.
```

**Why not auto-retry:** if the project's CI is stable, failures are real bugs, not flakes. Retry doesn't fix root cause. If your CI genuinely is flaky, mention `gh run rerun <id>` as an option in the user message but don't run it automatically.

## 4. `reviewers` field

Format: `name1,name2,...`, alphabetical

| Change | Action |
|---|---|
| New name appears (e.g. `claude[bot]` → `claude[bot],Codex`) | Loop back to Step 9.3. Pull the new review with `gh pr view`, evaluate per `quality-gate.md` |
| `claude[bot]` appears | Standard: the auto-review landed |
| User commented `@claude fix X` and reviewers field unchanged | Action runs in 30s–3min. After 30s, run `gh run list -w claude.yml --limit 1` to confirm the workflow started |
| `@claude` mention but no new commit after 5 minutes | Action failed: `gh run view <run-id> --log-failed`. Common: 401 (token) / timeout / quota — see `blockers.md` #8 |
| Same names, but new review event timestamp | An agent posted a second review (could overturn the first); re-evaluate |
| No change | Stay silent |

Pull the latest review:

```bash
# Most recent review
gh pr view <N> --json reviews --jq '.reviews[-1]'

# All reviews from a specific agent
gh pr view <N> --json reviews --jq '.reviews[] | select(.author.login=="<agent-login>")'

# Claude Code Action's review specifically
gh pr view <N> --json reviews --jq '.reviews[] | select(.author.login=="claude[bot]")'
```

## 5. Time

| Time since PR open | Action |
|---|---|
| t < 2 min (Tier A) / t < 5 min (Tier B) | Do not enter Step 9.3 yet, regardless of reviewer field |
| Tier A wait expired but no reviews | Continue waiting until 8-min cap |
| Tier B wait expired but no reviews | Continue waiting until 15-min cap |
| t ≥ tier cap (8 min / 15 min) AND `reviewers` empty | Trigger Action diagnostic (`blockers.md` #7) |
| t ≥ tier cap AND reviews landed | Enter Step 9.3, evaluate feedback |
| t = 60 min | **Hard cap.** Tell user current state + history, exit (see `blockers.md` #8) |

## Silence handling

Monitor stays silent when nothing changes. This is correct, not a bug:

- No emit = PR is stable
- Don't ad-hoc poll `gh pr view` "to be sure"

If 30 minutes elapse with zero emits and `state=OPEN` + `merge=CLEAN`:

```bash
gh pr view <N> --json autoMergeRequest --jq '.autoMergeRequest.mergeMethod // "off"'
```

- `off` → Step 10 didn't take effect, re-run `gh pr merge --auto --merge <N>`
- `merge` (or `squash`/`rebase`) → genuinely waiting on required checks, stay silent

### Tier A specific silence check

If 5+ minutes since PR open and `reviewers` is still empty (not even `claude[bot]`):

```bash
gh run list --workflow claude-code-review.yml --limit 5
gh run view <run-id> --log-failed   # if a run exists but failed
```

This is `blockers.md` #7 — Actions didn't trigger. Stop, tell the user.

## Message templates

### Success (state=MERGED)

```
✅ PR #<N> merged: <PR URL>

  review rounds:    <N>
  feedback adopted: <X> items (from <agent A>, <agent B>)
  feedback skipped: <Y> items (reasons: <one-line summary>)
  total time:       <HH:MM> (from PR open to MERGED)
  linked issue:     #<X> (auto-closed)
```

End of turn. No "anything else?".

### 60-minute cap

```
⚠️ PR #<N> hit the 60-minute babysit cap.

  current state:  <state>
  merge status:   <merge>
  recent events:
    - HH:MM:SS state=X merge=Y ...
    - HH:MM:SS state=X merge=Y ...
  PR URL:         <PR URL>

You take over from here. Most likely action:
  - <BLOCKED, waiting on required reviewer> / <DIRTY, conflicts to resolve> / <CI fix needed>
```

### CLOSED without merge

```
❌ PR #<N> closed without merging.

  reason:   <closedReason>
  time:     <closedAt>
  PR URL:   <PR URL>

Babysit exited.
```
