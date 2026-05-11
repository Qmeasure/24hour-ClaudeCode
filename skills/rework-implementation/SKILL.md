---
name: rework-implementation
description: Apply minimal-change repairs based on a triage from ci-feedback-analysis or review-feedback-analysis, or feedback received via the Stop hook's decision:block.reason. Defines the discipline: scope-locked repair, per-fix verify, commit messages that cite the failure source. Also covers the mandatory commit-amend after the Stop hook's auto-commit placeholder.
---

# Rework Implementation

You're here for one of three reasons:

1. The Stop hook just auto-committed with a placeholder `auto: WIP on <branch>` message. You need to **amend** it to a proper Conventional Commit.
2. The Stop hook returned `{"decision":"block","reason":"<feedback>"}`. You need to apply the cited fixes.
3. `ci-feedback-analysis` or `review-feedback-analysis` produced an adopt list. You need to apply each item, verify, and let the next Stop push.

## Iron Law

<EXTREMELY-IMPORTANT>
**Minimal change.** Touch only the files cited in the adopt list. No "while I'm here" cleanup. No drive-by refactors. Adding a single import to fix a typecheck is fine; rearranging the file isn't.
</EXTREMELY-IMPORTANT>

## Mode 1 — Amend the auto-commit placeholder

After the on-edit hook commits with `auto: WIP on <branch> [HH:MM:SS]` and pushes, you must replace that message immediately:

### Step 1 — Decide the conventional commit type

| Type | Use for |
|---|---|
| `feat` | A new user-visible capability |
| `fix` | Bug fix |
| `chore` | Tooling, config, deps |
| `refactor` | Code change without behavior change |
| `docs` | Docs-only |
| `test` | Test-only |
| `perf` | Performance, not user-visible |
| `build` / `ci` | Build/CI config |
| `style` | Formatting, semicolons |
| `review` | Addressing a specific review item — **only in iteration ≥ 2** |

### Step 2 — Compose the message

```
<type>(<scope>): <one-line subject ≤72 chars>

<optional body: why this change exists; do not repeat what the diff shows>

Co-Authored-By: Claude <noreply@anthropic.com>
```

Example:

```
feat(auth): refresh OAuth tokens before they expire

The previous implementation refreshed only on 401 — bad UX during
peak traffic where the auth server itself was rate-limited.

Co-Authored-By: Claude <noreply@anthropic.com>
```

### Step 3 — Amend and push

```bash
git commit --amend -m "$(cat <<'COMMIT'
feat(auth): refresh OAuth tokens before they expire

<body>

Co-Authored-By: Claude <noreply@anthropic.com>
COMMIT
)"
git push --force-with-lease
```

**Never** plain `--force`. Always `--force-with-lease` so concurrent pushes don't get clobbered.

## Mode 2 — Apply review/CI fixes

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

### Step 4 — Commit the round

When all items verify locally, commit:

```bash
git add <only the touched files>
git commit -m "review: address <agent> on PR #<N> — <one-line>"
```

Body (optional but encouraged):

```
- adopted <agent>'s <item> (reason: Reject — security)
- adopted <agent>'s <item> (reason: Major — type hole)
- skipped <agent>'s <item> (reason: conflicts with CLAUDE.md, replied on PR)
```

### Step 5 — Don't push manually; let the Stop hook do it

In Revision 2, you do **not** call `git push` yourself after a rework round. The flow is:

1. You edit files (PostToolUse hook touches `<runtime>/dirty`).
2. You finish the turn — the Stop hook fires.
3. The Stop hook detects the diff, runs config.checks.commands, commits + pushes.
4. Mode transitions to `waiting_for_checks`.
5. The next Stop hook polls + decides.

If you `git push` manually, you bypass the Stop hook's verify-then-commit flow and skip the iteration counter increment. Trust the loop.

The exception: when amending a placeholder commit (Mode 1), `git push --force-with-lease` is required to publish the amend. That's not a rework push; it's a metadata fix.

## Anti-patterns

- ❌ "While I'm in this file, let me also fix..." — out of scope, reject the urge
- ❌ Bundling a feature change with review fixes — split into two PRs after merge
- ❌ Re-running the whole test suite after every single-item fix — use targeted runs
- ❌ Using `git commit --no-verify` to skip pre-commit hooks
- ❌ Plain `git push --force` — always `--force-with-lease`
- ❌ Skipping the local verify between items — silently breaking adjacent items is the #1 cause of `stop:repeated_failure`

## Hand-off after rework

After push:
- The on-edit hook fires again on your edits → Iteration #N+1, new auto-commit.
- The babysit-pr skill picks up on the next PR `synchronize` event.

You don't manually start the next round; the loop handles it.
