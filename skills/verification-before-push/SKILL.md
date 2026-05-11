---
name: verification-before-push
description: Pre-push gate — diff review, no-secrets, no-destructive-ops, no-runaway-diff, project local checks. The on-edit hook runs an automated subset of this; this skill is the human-readable mental model and is also invoked before any manual push (e.g., a force-push from rework-implementation).
---

# Verification Before Push

Before any push (auto or manual), every one of these has to be true. The on-edit hook automates most checks; you invoke this skill manually before `git push --force-with-lease` (commit amends) or before any push that bypasses the hook.

## Iron Law

<EXTREMELY-IMPORTANT>
**A push to remote is broadcasted work.** Once it lands, the Action workflow fires, CI starts, reviewers may load it. Don't push code you wouldn't want a teammate to read in their morning standup.
</EXTREMELY-IMPORTANT>

## The pre-push checklist (6 items)

### 1. Diff review

```bash
git diff origin/<base-branch>...HEAD                # what's in this PR
git diff --staged                                    # what's about to be committed
git status --short                                   # any unstaged drift?
```

Read every line of the diff yourself. If you see something you didn't mean to add (debug logs, commented-out code, half-finished thoughts), revert it now.

### 2. No secrets

```bash
git diff origin/<base-branch>...HEAD | grep -iE 'password|api[_-]?key|secret|token|bearer|x-api-key|aws_access_key' || echo "✓ no obvious secrets"
```

Also check no new `.env*` files snuck in:

```bash
git diff --name-only origin/<base-branch>...HEAD | grep -E '^\.env' && echo "⛔ .env file in diff — STOP" || echo "✓ no .env files"
```

If a secret is in the diff: stop, remove it, **rotate the secret** (assume it's already compromised), then push.

### 3. No destructive ops

```bash
# These commands should NEVER appear in your diff
git diff origin/<base-branch>...HEAD | grep -E 'rm -rf|truncate table|drop table|DROP DATABASE|--force-with-lease|reset --hard'
```

If any match:
- `rm -rf` in a script → did you mean `find ... -delete` with a narrower scope?
- `DROP TABLE` / `TRUNCATE` → use a proper migration with rollback
- `git push --force` (without `-with-lease`) → never; the with-lease variant is mandatory

### 4. No runaway diff size

```bash
git diff origin/<base-branch>...HEAD --shortstat
```

The plugin no longer caps diff size — the auto-review action will flag oversized PRs at review time. But if you're crossing module boundaries (e.g. schema migration + code that uses it), splitting into sequential PRs (Expand → Migrate → Contract, see `references/anti-patterns.md` E) is still better for reviewability.

### 5. Project local checks pass

```bash
# Whatever the project uses; check .claude/24hour-ClaudeCode.config.json checks.commands
pnpm typecheck
pnpm lint
pnpm test
```

Fail-fast: if typecheck fails, don't bother running lint/test. Fix and re-verify.

The on-edit hook ran these automatically before its auto-commit. You're invoking this skill because you're doing a **manual** push (e.g., after a `--amend`). You must run them yourself.

### 6. Commit message is informative

```bash
git log -1 --format='%s%n%n%b'
```

Read the message you're about to push. Does it explain **why**? Or does it just say "WIP" / "fix" / "update"? If the latter, amend before push:

```bash
git commit --amend
```

Conventional Commits format is required (see `rework-implementation` skill for types).

## When this skill is invoked vs. the hook

| Scenario | Who runs verification |
|---|---|
| Auto-edit by the agent → on-edit hook fires | Hook runs subset (#5 only, per `config.checks.commands`) |
| Agent amends commit message after hook (`git commit --amend`) | **You** invoke this skill before `git push --force-with-lease` |
| User invokes `/24hour-ClaudeCode:retry` | Hook runs subset; you should still mentally run #1–#4 |
| Pushing a hand-written commit (no hook) | **You** run all 6 |

## Anti-patterns

- ❌ Running tests but not reading the diff
- ❌ "Looks fine" without actually grepping for secrets
- ❌ `git push --force` (use `--force-with-lease`)
- ❌ Pushing before the local typecheck completes ("CI will catch it")
- ❌ Pushing 800-line diffs ("the reviewer will tell us if it's too big")
