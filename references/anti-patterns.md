# Anti-patterns — failure modes that break the loop without looking broken

This file is what *not* to do. 90% of skill failures cluster into the 8 categories below (A–G are workflow; H is Actions-specific config).

## A. Stopping mid-flow to ask the user (most common)

LLM training has a strong "report after each step" reflex. This skill is built to run end-to-end from Step 1 to `state=MERGED`. Every "report + confirm" forces the user to nudge you back.

### Wrong

| Wrong phrasing | Why wrong | Right behavior |
|---|---|---|
| "Code is done, want me to push?" | User already authorized at worktree boundary | Push |
| "PR is open, should I enable auto-merge?" | `--auto` is itself deferred — enabling has zero risk | Enable immediately |
| "Tests pass, want to review?" | The user reviews on the PR page, not in chat | Finish steps 6–11, give PR URL |
| "Done, want to see the diff?" | Mock-reviewing in chat = double review = wasted | Push, let the actual review agent look |
| "Want to confirm direction first?" | Direction is settled before code; mid-flow stops are blockers only | See `blockers.md` |
| "Auto-merge enabled, are we good?" | DoD is `state=MERGED`, not "auto-merge on" | Babysit |

### Right

```
User: "fix the timeout issue the review agent flagged on PR #100"

You execute:
  1. Read review (severity matrix from quality-gate.md)
  2. Edit code
  3. typecheck/lint/test
  4. commit
  5. push
  6. wait for next round (Monitor)
  7. silence → auto-merge already enabled, babysit continues
  8. state=MERGED → success message to user
0 chat questions in between.
```

## B. Fake babysit / long sleep

### Wrong

```bash
# All of these don't work
sleep 600 && gh pr view 100         # harness intercepts
echo "wait 10 min" && sleep 600     # same
"I'll come back in 6 min"           # turn ends = process dies
"I'll keep monitoring" (does nothing) # user thinks you're babysitting; you aren't
```

### Right

- Preferred: Monitor (`mcp__claude_ai_*` or harness-provided)
- Fallback: `ScheduleWakeup({delaySeconds: 60, prompt: "/loop babysit PR #N"})`
- Neither: tell the user honestly "I have no babysit tooling; keep an always-on session active"

**Forbidden:** saying "I'll come back later" then ending the turn.

## C. Modifying the Monitor jq expression

### Wrong

```bash
# All explode
gh pr view 100 --json state,merge | jq '...'                  # pipe eats control chars
gh pr view 100 --json reviews --jq '.reviews[].author.login'  # multi-line output, prev breaks
gh pr view 100 --json reviews --jq "\(.author):\(.body)"      # nested string template
```

### Right

Copy the template from `monitor-template.md` verbatim. The 6 ironclad rules are non-negotiable — every "small optimization" is a previously-discovered failure mode.

## D. Cheating the quality-gate timing

### Wrong

| Wrong timing | Why wrong |
|---|---|
| At t=90s, built-in review says OK → straight to Step 10 | Third-party agents haven't even fired yet → multi-agent gate skipped |
| At t=10s, enable auto-merge with no review wait | Gate completely defeated |
| At t=5min, only 1 reviewer spoke → forced to wait until 30min | Over-waits; busts 60-min cap |
| Don't like the feedback so don't reply | Same agent will resurface it next round → death loop |

### Right

```
t=0:        gh pr create
t=0:        arm Monitor
t<2 min:    don't enter Step 9.3 (Tier A) / t<5min (Tier B)
t=tier-cap: enter 9.3 with whatever's there
t=60min:    force Step 10 (hard cap)
```

## E. Schema/data migrations as ordinary feature PRs

### Wrong

Bundling schema/migration changes with business code in one PR, expecting one-shot review + auto-merge.

### Why wrong

- Reviewers struggle to spot hidden renames or data destruction in big diffs (gate is weak)
- Rollback requires reverting two layers (compounding risk)
- Blocks others' PRs (schema lock holds the base branch; everyone goes BEHIND)

### Right — Expand → Migrate → Contract

1. **PR 1 (expand):** add the new column nullable / with default; code reads + writes both old and new
2. Bake on staging (typically 1 day) and prod (typically 1 week)
3. **PR 2 (contract):** drop the old column or add NOT NULL; code uses only new

Each PR runs through this skill independently. Adjust pacing to your release cadence.

## F. Letting the reviewer override project conventions

Review agents occasionally suggest things like "add an emoji for friendliness" / "introduce lodash" / "use raw hex colors". When these conflict with your project's `CLAUDE.md` / style guide top rules, they are **not valid suggestions**.

### Right reaction

Reply on the PR with the specific rule reference:

```
Skipping: conflicts with <CLAUDE.md / STYLE_GUIDE.md section name>:
  - <rule 1 quoted>
  - <rule 2 quoted>
```

Don't be swayed. Downweight or invert the agent's suggestion based on your project's top-of-file rules.

## G. Skipping the next-round wait after pushing fixes

### Wrong

```
Step 9.4 push fix
→ straight to Step 10 (gh pr merge --auto)
→ didn't wait for CI rerun or agent re-review
```

`--auto` waits for CI fine, but **skipping the agent re-review** loses the multi-round gate. New commits may have new bugs the agent flags on round 2 — but auto-merge is enabled, CI passes, and the bug merges.

### Right

push → loop back to Step 9.2 → Monitor catches `reviewers=` change → re-evaluate → silence → Step 10.

Two-to-three rounds per PR is normal.

## H. Claude Code Actions config mistakes

### H1. OAuth token leaked

Putting the `claude_code_oauth_token` value into:
- chat / code comments / debug output
- commit messages / source comments
- `.env` files committed to git
- log lines like `echo $CLAUDE_CODE_OAUTH_TOKEN`

A leaked token lets anyone with read access burn your Claude Pro/Max subscription quota until you revoke.

**Right:**

```bash
# Pipe via stdin so token never enters shell history or any file
gh secret set CLAUDE_CODE_OAUTH_TOKEN -R <owner>/<repo>
# At "? Paste your secret": paste, hit enter
```

If a token leaked: `claude setup-token` regenerates and invalidates the old one.

### H2. `permissions: read` but expecting `@claude` to commit

The default from `/install-github-app` is read-only. User comments `@claude fix X`; the Action runs, finds no write permission, **silent fail** — leaves a "no permission" PR comment, code unchanged.

**Right:**

```yaml
permissions:
  contents: write       # required for @claude to commit
  pull-requests: write
  issues: write
  actions: read         # to read CI logs
  id-token: write       # OIDC
```

### H3. Workflow filename collision

Local hand-written `.github/workflows/claude.yml`, then `/install-github-app` auto-generates the same path, causing a push conflict — or worse, the install pushes to GitHub directly via API and your local copy gets rejected on next push.

**Right:**

```bash
# Check what's already remote
gh api repos/<owner>/<repo>/contents/.github/workflows --jq '.[].name'

# Conflict? rebase first
git pull --rebase origin main
```

### H4. No `concurrency`

Five pushes in a row → five workflow runs in parallel → 5x token consumption.

**Right:**

```yaml
concurrency:
  group: claude-${{ github.event.pull_request.number || github.run_id }}
  cancel-in-progress: true
```

### H5. No `timeout-minutes`

Default GitHub Actions timeout is **6 hours**. A runaway Action (infinite loop, stuck LLM call, bun install hanging) burns 6h of tokens.

**Right:**

```yaml
jobs:
  review:
    timeout-minutes: 10    # review-only job
  claude:
    timeout-minutes: 15    # @claude commit job (multi-step possible)
```

### H6. `--max-turns` too low for the task

Default `--max-turns: 10` is fine for review or single-line fixes. Multi-file refactors at `--max-turns: 10` get cut off mid-job, leaving **half-done commits** — some files updated, some not, imports inconsistent.

**Right:**

```yaml
# review-only (comment, no edit)
claude_args: --max-turns 5

# @claude small bug fix
claude_args: --max-turns 10

# @claude multi-file refactor
claude_args: --max-turns 20
```

See `workflow-yaml.md §C` for the full reference.

### H7. Duplicate triggers

```yaml
# claude-code-review.yml
on:
  pull_request:
    types: [opened, synchronize]

# claude.yml
on:
  pull_request:                 # also listens on pull_request
    types: [opened, synchronize]
  issue_comment: ...
```

Every PR runs review twice → 2× tokens.

**Right:** split by responsibility:
- `claude-code-review.yml` — `pull_request` only (auto review)
- `claude.yml` — comment events only (`issue_comment`, `pull_request_review_comment`, `pull_request_review`, `issues`)

The renderer (`scripts/render-workflows.sh`) produces split triggers by default.

### H8. OAuth token stuffed into the API-key field

```yaml
anthropic_api_key: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}   # ← wrong field
```

OAuth tokens authenticate via Anthropic's OAuth endpoint (subscription billing). API keys authenticate via console (per-token billing). The Action picks the auth flow based on which input field you set; mismatching causes 401.

**Right:** pick one, not both.

```yaml
# subscription auth
claude_code_oauth_token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}

# OR API-key auth
anthropic_api_key: ${{ secrets.ANTHROPIC_API_KEY }}
```
