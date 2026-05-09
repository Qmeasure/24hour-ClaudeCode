# Monitor template + 6 ironclad rules

The Monitor is the load-bearing piece that lets this skill drive PR babysit reliably without burning your context window. Each tick prints **comparable scalars**; new state emits a line, unchanged state stays silent. If scalar parsing fails (jq breaks on control chars / pipes swallow nesting / quotes split mid-stream), the state machine degrades to "silence = all good" — the textbook failure is a user staring at chat for 15 minutes thinking the PR merged when in fact the Monitor crashed silently.

The 6 rules below were each written after a real incident. **Copy verbatim. Do not rewrite.**

## Standard Monitor template (the only correct way to babysit a PR)

```
Monitor({
  description: "PR #<N> state (gh --jq only, no shell pipes)",
  persistent: true,
  timeout_ms: 3600000,
  command: `
PR=<N>
prev=""
while true; do
  state=$(gh pr view $PR --json state              --jq '.state'                                                                                  2>/dev/null || echo ERR)
  merge=$(gh pr view $PR --json mergeStateStatus   --jq '.mergeStateStatus'                                                                       2>/dev/null || echo ERR)
  checks=$(gh pr view $PR --json statusCheckRollup --jq '[.statusCheckRollup[]? | select(.conclusion!="" and .conclusion!=null) | .name + ":" + .conclusion] | sort | join(",")' 2>/dev/null || echo ERR)
  revs=$(gh pr view $PR --json reviews             --jq '[.reviews[]?.author.login]  | unique | join(",")'                                       2>/dev/null || echo ERR)

  cur="state=$state merge=$merge checks=$checks reviewers=$revs"
  if [ "$cur" != "$prev" ]; then
    echo "PR#$PR $(date +%H:%M:%S) | $cur"
    prev="$cur"
  fi
  case "$state" in
    MERGED) echo "PR#$PR MERGED -- monitor exiting"; break;;
    CLOSED) echo "PR#$PR CLOSED -- monitor exiting"; break;;
  esac
  sleep 60
done`
})
```

Replace `<N>` with the PR number. `timeout_ms: 3600000` = 60 minutes, covers Step 9 + Step 11 end-to-end.

## The 6 ironclad rules

### 1. Use `gh --jq`, never `gh ... | jq`

PR bodies often contain CJK characters, newlines, or control chars. Piping through external `jq` will fail with:

```
jq: error (at <stdin>:1): Invalid string: control characters from U+0000 through U+001F must be escaped
```

**Correct:** `gh pr view $PR --json state --jq '.state'`
**Wrong:**   `gh pr view $PR --json state | jq -r '.state'`

### 2. No nested string templates `"\(.x):\(.y)"` in jq expressions

Escape levels split between shell and jq; bash eats one quote layer and jq receives malformed input.

**Correct:** `.name + ":" + .conclusion`
**Wrong:**   `"\(.name):\(.conclusion)"`

### 3. Concatenate with `+`, not string templates

Same reason as #2. `+` is jq's string concatenation operator — least sophisticated, most reliable.

### 4. One `gh --jq` call per scalar field

Pulling `--json reviews,comments,timelineItems` in a single call is a bomb — bigger payload, more control chars, harder to parse without fail. Four small calls per tick are safer.

**Correct:** four separate `gh pr view` calls, each pulling one field
**Wrong:**   `gh pr view --json state,merge,checks,reviews` then a giant jq expression

Cost: 4 API calls per tick. With 60s tick interval × 4 fields = 240/hour, well below GitHub's 5000/hour rate limit.

### 5. First tick must emit baseline

`prev=""` cannot equal any real gh output, so the first tick always emits — giving the user/agent a known starting point.

**Forbidden:** `prev="ERR"` or any hardcoded initial value (if the first real state happens to match the init, you stay silent — user thinks the Monitor never started).

### 6. Terminal-state match uses explicit `case "$state" in MERGED) ...; break;;`

**Correct:** `case "$state" in MERGED) ...; break;; CLOSED) ...; break;; esac`
**Wrong:**   `case "$cur" in *MERGED*) ...; esac` (false-matches on `state=NOTMERGED`, `state=AUTO_MERGED`, or any field value containing the substring `MERGED`)

Match only on the precise `state` field, never on the concatenated string.

## Field reference (for ad-hoc queries too)

| `gh pr view <N> --json X` | jq expression | Use |
|---|---|---|
| `state` | `.state` | OPEN / MERGED / CLOSED → exit condition |
| `mergeStateStatus` | `.mergeStateStatus` | CLEAN / DIRTY / BEHIND / BLOCKED / UNSTABLE / UNKNOWN |
| `statusCheckRollup` | `[.statusCheckRollup[]? \| select(.conclusion!="" and .conclusion!=null) \| .name + ":" + .conclusion] \| sort \| join(",")` | Pass / fail / skipped checks |
| `reviews` | `[.reviews[]?.author.login] \| unique \| join(",")` | Which reviewers have spoken |
| `reviewDecision` | `.reviewDecision` | APPROVED / CHANGES_REQUESTED / REVIEW_REQUIRED / null |
| `autoMergeRequest` | `.autoMergeRequest.mergeMethod // "off"` | Whether auto-merge is armed |
| `comments` | `.comments \| length` | Comment count (NEVER pull `body` directly via `--jq` — control chars will break it) |

To read a specific reviewer's body:

```bash
gh pr view <N> --json reviews --jq '.reviews[] | select(.author.login=="<agent>") | .body'
```

## Receiving events → see decision-table.md

The Monitor only emits state-change lines. Mapping events → actions is in `decision-table.md`.

## Why these rules exist

The Monitor isn't a polling loop, it's an **event-stream state machine**.

- Input: 4 scalar fields from `gh pr view`
- State: `prev` (the previous tick's joined string)
- Output: emit when `cur != prev`
- Termination: `state ∈ {MERGED, CLOSED}`

The 6 rules exist so scalar parsing never fails: per-field queries, no nested templates, baseline-first emit, exact-match terminal states. Every rule maps to at least one real "silent for 15 minutes; user thought it merged; actually still OPEN" incident.

## Fallback when Monitor tool isn't available

| Tooling | Fallback |
|---|---|
| Monitor available | Use the template above (preferred) |
| No Monitor, has ScheduleWakeup | `ScheduleWakeup({delaySeconds: 60, prompt: "/loop babysit PR #<N>"})` — full poll every minute, less efficient but works |
| Neither | Tell the user honestly: "I have no Monitor or scheduling tool. I can't persistently babysit. Either keep an always-on session, or watch the PR in your browser." |
| **Forbidden** | `bash sleep` — the harness intercepts long sleeps; turn end = process death |

## When to arm and tear down

- **Arm at Step 9.1.** One Monitor instance covers Step 9 (review gate) through Step 11 (babysit until MERGED).
- **Do not kill and re-arm mid-flow.** Event-stream continuity is what drives correct decisions.
- After a push triggers a review re-run, the Monitor naturally captures the `checks=` change — no re-arm needed.
