---
name: review-feedback-analysis
description: Triage Claude Code Action verdict blocking findings or manual PR review comments by severity, then produce an adopt-or-justify decision per item. Use after the Stop hook returns review feedback or babysit-pr diagnostics show new review comments.
---

# Review Feedback Analysis

You're here because the Stop hook returned a current-SHA review verdict with blocking findings, or a reviewer (`claude[bot]`, a third-party agent, or a human) posted feedback during manual diagnostics. Your job: classify each item, decide adopt-or-skip, prepare the input for `rework-implementation`.

<EXTREMELY-IMPORTANT>
**Adopt by default, even Minor and Nit.** The bar to skip is "demonstrably wrong" or "conflicts with project CLAUDE.md hard rule". A reply that says "I disagree" is not enough — give a reason, cite the rule.
</EXTREMELY-IMPORTANT>

## Step 1 — Determine the tier (timing window)

| Tier | Reviewers | Wait window | Hard cap |
|---|---|---|---|
| **A** | Only `claude[bot]` from this skill's `claude-code-review.yml` | 2 minutes | 8 minutes |
| **B** | `claude[bot]` + third-party agents (Codex, Copilot, etc.) or human reviewers | 5 minutes | 15 minutes |

Detect with:

```bash
gh pr view "$PR" --json reviews --jq '[.reviews[]?.author.login] | unique'
```

Default to A unless you see other agents.

**Don't read reviews before the wait window expires.** Reading a half-formed review wastes a fix cycle. (See `references/quality-gate.md §0`.)

## Step 2 — Pull each review's body

```bash
gh pr view "$PR" --json reviews --jq '.reviews[] | {author: .author.login, state: .state, body: .body, submittedAt: .submittedAt}'
```

For inline comments specifically:

```bash
gh api "repos/<owner>/<repo>/pulls/$PR/comments" --jq '.[] | {author: .user.login, path: .path, line: .line, body: .body}'
```

## Step 3 — Classify each item by severity

| Severity | Definition | Default action |
|---|---|---|
| **Reject** | Blocks merge: correctness bug, security issue, breaks public API contract | Adopt unless reviewer is demonstrably wrong |
| **Major** | Should fix before merge: logic concern, missing test for important branch, type hole | Adopt unless cost vastly exceeds benefit |
| **Minor** | Style / naming / organization | Adopt by default |
| **Nit** | Subjective taste | Adopt unless adopting balloons the diff significantly |

### Reject signals (any one fires)

- Modifying signing keys, certs, keystores, credential files
- Putting any secret into a client-bundled variable (`EXPO_PUBLIC_*`, `NEXT_PUBLIC_*`, `VITE_*`, `REACT_APP_*`)
- Modifying `.env.production`, `.env.staging`, third-party platform secrets
- Pushing directly to a protected branch
- Schema change without idempotence or rollback plan
- Hardcoded user PII in LLM prompts or third-party APIs

### Major signals

- Missing input validation at a system boundary
- SQL injection risk
- N+1 queries
- Unhandled Promise rejection / swallowed errors with no log
- Producer/consumer name mismatch in queues
- Material perf regression
- API compat break without versioning

### Skip signals (don't auto-adopt)

- Vague suggestion ("consider better naming")
- Conflicts with `<project>/CLAUDE.md` top rules — quote the rule when replying
- Misread context (agent thinks file X is in unrelated module Y); verify with `gh pr view --json files`

## Step 4 — Multi-agent merge rules

When ≥2 agents speak on the same item:

| Situation | Adjustment |
|---|---|
| Multi-agent agreement | Priority +1 (weak signals stack) — fix regardless of original severity |
| Single agent flags, others silent | Original severity |
| Agent A says "add X", Agent B says "don't add X" | Default to project `CLAUDE.md`. No explicit rule → keep current state, reply explaining |

## Step 5 — Produce the triage table

Output to user before invoking rework-implementation:

```
PR #<N> review triage (round <iter>)
─────────────────────────────────────────────
Reviewers spoken:  <list>
Tier:              <A|B>
Items:             <total count>

Severity breakdown:
  Reject:  <count>  → must adopt or escalate
  Major:   <count>  → adopt unless demonstrably wrong
  Minor:   <count>  → adopt by default
  Nit:     <count>  → adopt by default unless diff balloons

Adopt list:
  1. <item summary> — <severity> — <file:line> — <reviewer>
  2. ...

Skip list (with justifications):
  1. <item summary> — reason: <one-line>
  2. ...

Hand off to rework-implementation with adopt list.
```

## Step 6 — Hand off to rework-implementation

```
"review-feedback-analysis adopted N items, skipped M. Apply the adopt list to the cited file:line locations using minimal-change repair."
```

Then invoke `rework-implementation`.

## Reply to skipped items on the PR

For each skipped item, post a reply on the PR (NOT in chat):

```bash
gh pr comment "$PR" --body "Re: <item summary> — Skipping: <one-line reason citing rule or evidence>."
```

Skipping silently is forbidden. Every skip needs a reply, otherwise the agent will re-raise the same comment next round.

## Special case — merge-commit confusion

If a reviewer flags base-branch changes that the merge commit pulled in:

```bash
gh pr view "$PR" --json files --jq '[.files[]?.path] | sort | join("\n")'
```

Reply: "Confirmed PR diff is only files X/Y. The lines mentioned came from a base-branch merge and are out of scope."

## Anti-loop

- Same comment adopted twice in different iterations → escalate (`stop:repeated_failure`).
- Same skip-justification offered twice on same comment → escalate (the agent isn't accepting your reasoning; you can't keep replying forever).

See `references/anti-patterns.md` G for the full anti-loop rules.
