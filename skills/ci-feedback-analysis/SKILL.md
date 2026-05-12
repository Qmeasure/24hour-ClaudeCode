---
name: ci-feedback-analysis
description: Read GitHub Actions check failure logs from the Stop hook's current-SHA status, <runtime>/feedback.json diagnostics, or `gh run view`; classify the failure (test/lint/type/build/infra), and produce a minimal-fix plan. Use after the Stop hook returns CI feedback or babysit-pr detects a failed check; never re-run failed CI without understanding the cause.
---

# CI Feedback Analysis

You're here because a required CI check has `conclusion=failure` (or `cancelled`) and the Stop hook's `decision:block.reason` or the babysit-pr skill handed off to you.

<EXTREMELY-IMPORTANT>
**Never auto-rerun a failed check.** Diagnose first. If the same check failed in iteration N-1 and now fails in iteration N for the same reason, that's the `stop:repeated_failure` condition — escalate via failure-escalation, do not loop.
</EXTREMELY-IMPORTANT>

## Step 1 — Pull the failure summary

```bash
PR=<PR-number>     # from <runtime>/current-pr.json or gh pr view --json number
gh pr checks "$PR" --json name,conclusion,detailsUrl --jq '.[] | select(.conclusion == "failure" or .conclusion == "cancelled")'
```

For each failed check, get the most recent run ID and its log:

```bash
RUN=$(gh pr view "$PR" --json statusCheckRollup --jq '.statusCheckRollup[] | select(.conclusion=="FAILURE") | .detailsUrl' | grep -oE '[0-9]+$' | head -1)
gh run view --log-failed "$RUN" | tail -200    # the last 200 lines usually contain the actual error
```

## Step 2 — Classify the failure

| Bucket | Telltale signs | Owner |
|---|---|---|
| **Test failure** | `jest`, `vitest`, `pytest`, `cargo test`, `go test` in command line; `expected ... received ...`; assertion errors | Code under test |
| **Lint failure** | `eslint`, `ruff`, `golangci-lint`, `clippy`; rule names; line:column citations | The line/column cited |
| **Type failure** | `tsc`, `mypy`, `pyright`, `cargo check`; `cannot assign type X to Y`; `error TS` codes | Likely an import or signature change |
| **Build failure** | `webpack`, `vite`, `bun build`, `cargo build`; `Cannot find module`, missing imports | Recently added / removed import |
| **Infra failure** | `Error: container exited`, `OOM killed`, `runner timeout`, `429 from registry`, `gh-actions: lost connectivity` | Not your code; environmental |

**Save the bucket** — your fix plan depends on it.

## Step 3 — Produce a minimal-fix plan

Output to the user (one screen):

```
PR #<N> CI failure analysis
─────────────────────────────────────────────
Check:    <check name>
Bucket:   <test|lint|type|build|infra>
Run URL:  <details URL>

Root cause (from log):
  <one-paragraph excerpt of the error, ≤5 lines>

Files implicated (cited in stack trace):
  - src/foo.ts:42
  - src/bar.ts:103

Minimal fix:
  <≤3 sentence plan: which file, what change, why this addresses the error>

Estimated diff size: <small / medium / large>
Risk of breaking other things: <low / medium / high>
```

## Step 4 — Hand off to rework-implementation

Tell the next skill:

> "ci-feedback-analysis classified this as `<bucket>` failure. Root cause: <one-line>. Apply the minimal fix in `src/foo.ts:42` per the plan above."

Then invoke `rework-implementation`.

## Special cases

### Infra failure (not your code)

Don't edit code. Add a comment to the PR explaining you believe the failure is environmental, and suggest one retry:

```bash
gh pr comment "$PR" --body "CI check \`<name>\` failed with what appears to be an infrastructure issue (<one-line summary>). Will retry once."
gh run rerun "$RUN" --failed
```

If the rerun also fails, escalate via `failure-escalation` (this is `stop:repeated_failure`, even though the cause is environmental).

### Pre-existing failure (your PR didn't break this)

If `git log` shows the failing test was already failing on the base branch:

```bash
git fetch origin
git log --oneline origin/main -- <failing test file>
gh run list --workflow <workflow-name> --branch main --limit 5
```

Reply on the PR with this evidence and skip the fix. Don't try to fix base-branch problems in your PR.

### Flaky test (your PR + sometimes passes)

If the test name is on the project's known-flaky list (check `.flaky-tests.txt`, `flaky.json`, or similar):

```bash
gh pr comment "$PR" --body "Test \`<name>\` is on the flaky list. Rerunning."
gh run rerun "$RUN" --failed
```

Otherwise treat as a real failure.

## Anti-patterns

- ❌ Reading only the failure summary, not the actual stack trace
- ❌ Making changes outside the cited file:line
- ❌ "Fixing" by adding `--ignore` / `# noqa` / `// eslint-disable` to silence
- ❌ Auto-retrying without diagnosis
- ❌ Including unrelated "while I'm in here" cleanup in the fix
