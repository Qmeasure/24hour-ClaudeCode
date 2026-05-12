---
name: rework-implementation
description: Apply minimal-change repairs based on a triage from ci-feedback-analysis or review-feedback-analysis, or feedback received via the Stop hook's decision:block.reason. Defines the discipline: scope-locked repair, per-fix verify, and no manual push during the automatic loop.
---

# Rework Implementation

You're here for one of two reasons:

1. The Stop hook returned `{"decision":"block","reason":"<feedback>"}`. You need to apply the cited fixes.
2. `ci-feedback-analysis` or `review-feedback-analysis` produced an adopt list. You need to apply each item, verify, and let the next Stop hook commit/push/review again.

## Iron Law

<EXTREMELY-IMPORTANT>
**Minimal change.** Touch only the files cited in the adopt list. No "while I'm here" cleanup. No drive-by refactors. Adding a single import to fix a typecheck is fine; rearranging the file isn't.
</EXTREMELY-IMPORTANT>

## Apply review/CI fixes

### Step 1 — Read the adopt list

It came from the previous skill (`ci-feedback-analysis` or `review-feedback-analysis`). Each item has: file:line, severity, the change to make.

### Step 2 — Apply changes one item at a time

For each item:
- Open the file at the cited line.
- Make the smallest change that addresses the feedback.
- Save.

After each item, run `git diff <file>` to confirm only the cited area changed. If your change spilled into unrelated code, **revert and redo smaller**.

### Step 3 — Verify per item

After each fix, run the project's relevant local check on the touched file/package only:

```bash
# Examples
pnpm tsc --noEmit                      # typecheck
pnpm test src/foo.test.ts               # only the related test
ruff check path/to/foo.py               # only the touched file
golangci-lint run ./pkg/foo/...         # only the touched package
```

If verify fails after a single fix, you broke something. Revert that fix, re-think, retry.

### Step 4 — Do not commit or push manually

In Revision 2, you do **not** call `git push` yourself after a rework round. The flow is:

1. You edit files (PostToolUse hook touches `<runtime>/dirty`).
2. You finish the turn — the Stop hook fires.
3. The Stop hook detects the diff, runs config.checks.commands, commits + pushes.
4. Mode transitions to `waiting_for_review`.
5. The same Stop hook waits for current-SHA CI + Claude Code Action review, then blocks again, stops safely, or merges.

If you `git push` manually, you bypass the Stop hook's verify-then-commit flow and skip the iteration counter increment. Trust the loop.

## Anti-patterns

- ❌ "While I'm in this file, let me also fix..." — out of scope, reject the urge
- ❌ Bundling a feature change with review fixes — split into two PRs after merge
- ❌ Re-running the whole test suite after every single-item fix — use targeted runs
- ❌ Using `git commit --no-verify` to skip pre-commit hooks
- ❌ Manual `git push` during an automatic rework round — let the Stop hook push
- ❌ Skipping the local verify between items — silently breaking adjacent items is the #1 cause of `stop:repeated_failure`

## Hand-off after rework

After edits:
- PostToolUse marks the worktree dirty.
- When you finish the turn, the Stop hook commits, pushes, waits for current-SHA CI + Claude Code Action review, then blocks again, stops safely, or merges.

You don't manually start the next round; the loop handles it.
