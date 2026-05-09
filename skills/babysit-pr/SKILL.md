---
name: babysit-pr
description: Manual reference for inspecting and reasoning about a PR mid-loop. In Revision 2, the Stop hook (stop.sh) owns the polling and decision logic automatically — this skill is a quick-ref for cases where you want to manually understand WHY the hook decided what it did, or you need to inspect a PR independent of the auto-loop.
---

# Babysit PR — Manual Reference

<EXTREMELY-IMPORTANT>
**The Stop hook owns the babysit loop in Revision 2.** You don't normally need to invoke this skill. The hook polls, decides, and feeds back via `decision:block` automatically.

Use this skill ONLY when:
- You want to manually understand what the hook decided and why (debug)
- The user asked "what's the state of PR #N?" out-of-band
- The Stop hook returned `inconclusive` and you want to dig deeper
- You're testing the runtime and need to reason about state transitions
</EXTREMELY-IMPORTANT>

## Quick state inspection

```bash
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
RUNTIME="$PROJECT_DIR/.claude/runtime/24hour-ClaudeCode"

# Current loop state
jq . "$RUNTIME/state.json"

# Last poll snapshot
jq . "$RUNTIME/feedback.json"

# Last hook run
jq . "$RUNTIME/last-run.json"

# Current PR (if any)
jq . "$RUNTIME/current-pr.json"
```

For a fresh poll without going through the Stop hook:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/poll-github.sh"
bash "${CLAUDE_PLUGIN_ROOT}/scripts/decide-feedback.sh"
```

## Tier timing (when polls aren't auto-driven)

If the Stop hook returned `inconclusive` and you want to manually wait for a stable state:

| Tier | Reviewers | Don't read reviews before… | Hard cap |
|---|---|---|---|
| **A** (only `claude[bot]`) | 2 minutes | 8 minutes |
| **B** (multi-agent) | 5 minutes | 15 minutes |

Detect with:

```bash
gh pr view "$PR" --json reviews --jq '[.reviews[]?.author.login] | unique'
```

Default to A unless you see other agents.

## Manual decision-table reference

Same matrix as `<runtime>/feedback.json` analysis (see `references/decision-table.md` for the full table). Quick map:

| Saw | Action |
|---|---|
| `state=MERGED` | Done. Inform user. Cleanup happens on next stop automatically. |
| `state=CLOSED` (not merged) | Tell user closedAt + closedReason. Exit. |
| `mergeStateStatus=BEHIND` | `git fetch && git merge origin/<BASE> && git push`. Auto-merge resumes on its own. |
| `mergeStateStatus=DIRTY` (real conflicts) | Stop. Show conflicting files. Ask user unless they're trivial new-file additions or lockfiles. |
| Any check `:failure` | Don't auto-retry. Use `ci-feedback-analysis`. |
| New `reviewer` name | Use `review-feedback-analysis`. |

## Monitor template (legacy, only when not using Stop hook)

If you genuinely need a Claude-side persistent monitor (e.g., the user disabled the plugin's Stop hook and wants manual babysit), use the verbatim template at `references/monitor-template.md`. Six ironclad rules apply.

In normal operation (plugin enabled), **don't arm a Monitor**. The Stop hook is the loop driver; arming a separate Monitor creates competing state machines.

## When to dispatch

If `<runtime>/feedback.json` shows feedback you need to act on:

| Feedback shape | Skill to invoke |
|---|---|
| Failed CI checks | `ci-feedback-analysis` |
| `CHANGES_REQUESTED` reviews or actionable comments | `review-feedback-analysis` |
| Both | `ci-feedback-analysis` first (CI usually has cited file:line), then `review-feedback-analysis` |
| All clear | Nothing — the Stop hook will auto-merge on the next pass |

## Anti-patterns

- ❌ Polling `gh pr view` in a tight loop while the Stop hook is also polling — competing pollers
- ❌ Manually invoking `gh pr merge --auto` — the Stop hook handles this on `feedback_good`
- ❌ Running `wait-for-checks.sh` with a long timeout outside the Stop hook — blocks your turn
- ❌ Copying review comments into chat instead of reading them from `<runtime>/feedback.json` (already cleaned + structured)

## Index

- `references/monitor-template.md` — full Monitor template + 6 ironclad rules (legacy)
- `references/decision-table.md` — full event matrix
- `references/quality-gate.md` — tier timing + severity rules
