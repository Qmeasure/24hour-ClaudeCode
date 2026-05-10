**English** | [中文](FLOW.zh-CN.md)

# 24hour-ClaudeCode — Complete Runtime Flow

This document is the single source of truth for the plugin's runtime behavior. It enumerates **every hook**, the **trigger condition** for each, and the **complete event loop** from project install to PR merge.

---

## Hooks at a glance

| Hook | Trigger | Script | Timeout | Role |
|---|---|---|---|---|
| `SessionStart` | Session start, `/clear`, auto-compact (matcher: `startup\|clear\|compact`) | `hooks/bootstrap.sh` | 10s | Detect environment; inject runtime contract or onboarding instructions |
| `PostToolUse` | After every `Edit` / `Write` / `MultiEdit` tool call (matcher: `Edit\|Write\|MultiEdit`) | `hooks/post-tool-use.sh` | 5s | Light marker — touches `<runtime>/dirty`. Does no real work. |
| `Stop` | Turn boundary — when the main agent finishes a response | `hooks/stop.sh` | 900s | Heavy worker — owns the entire commit/push/PR/poll/decide loop |

**Why this split:** `PostToolUse` fires after every tool call (too granular for "commit when work is done"). `Stop` fires once per turn — exactly when "Claude has finished a coherent set of edits" should produce a commit. The marker pattern lets `Stop` skip work fast on chat-only turns.

Hook output formats (per the Claude Code spec):

```jsonc
// Informational — Claude is allowed to stop
{"hookSpecificOutput": {"hookEventName": "Stop", "additionalContext": "<text>"}}

// Block stop — feeds `reason` back to Claude as next-turn context
{"decision": "block", "reason": "<text>"}
```

---

## Phase 0 — Install & Onboard (one-time per repo)

Triggered by the user manually, not by a hook.

```
┌─ User runs in any project ──────────────────────────────────────────┐
│  /plugin marketplace add Qmeasure/24hour-ClaudeCode                 │
│  /plugin install 24hour-ClaudeCode@qmeasure-plugins                 │
└─────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
              Plugin lands at <project>/.claude/plugins/24hour-ClaudeCode/
                              │
                              ▼
┌─ User runs ─────────────────────────────────────────────────────────┐
│  /24hour-ClaudeCode:setup                                           │
└─────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
   scripts/configure-actions.sh:
     1. Verify gh / claude / git installed + authenticated (workflow scope)
     2. Open https://github.com/apps/claude → user installs App
     3. Run `claude setup-token` → save to `CLAUDE_CODE_OAUTH_TOKEN` secret
     4. Run scripts/detect-project.sh:
          • project type (node/python/go/rust/...)
          • base branch
          • test/lint/typecheck/build commands
          • monorepo flag, repo size
          • style guides (CLAUDE.md, AGENTS.md, ...)
          • danger paths (migrations/, infra/, .env.production, ...)
     5. Ask provider: claude | codex | both
        • If codex/both: ensure OPENAI_API_KEY secret
     6. Detect existing CI workflow in .github/workflows/
        • If no CI: ask whether to generate ci.yml
     7. scripts/render-workflows.sh --provider <choice> [--include-ci]:
          • Render 1–3 workflow YMLs (claude-code-review.yml, claude.yml,
            codex-review.yml, ci.yml — combination depends on choices)
          • Render .claude/24hour-ClaudeCode/review-prompt.md (externalized)
     8. git add → commit → push (with user confirmation per push)
     9. Seed .claude/24hour-ClaudeCode.config.json from template
    10. scripts/runtime-state.sh init → state.json with mode="idle"
    11. scripts/check-actions.sh -v (final health check)
                              │
                              ▼
              ✅ Repo is ready. The auto-loop is live.
```

Onboarding is idempotent — re-running `/24hour-ClaudeCode:setup` is safe.

---

## Phase 1 — Session opens

**Trigger:** every Claude Code session start, every `/clear`, every auto-compact.
**Hook:** `SessionStart` with matcher `startup|clear|compact`.

```
┌─ SessionStart hook fires → bootstrap.sh ────────────────────────────┐
│                                                                     │
│  Read .claude/24hour-ClaudeCode.config.json                         │
│  ├─ enabled=false → emit "disabled" note, exit 0                    │
│  └─ enabled=true → continue                                         │
│                                                                     │
│  Detect environment:                                                │
│  ├─ in worktree? (git rev-parse --git-dir vs --git-common-dir)      │
│  ├─ on protected branch? (main / master / develop / staging / ...) │
│  ├─ gh authenticated?                                               │
│  ├─ Claude Code Actions deployed? (.github/workflows/claude*.yml)   │
│  └─ config present? (.claude/24hour-ClaudeCode.config.json)         │
│                                                                     │
│  Branch on detection:                                               │
│  ├─ Not in worktree → emit "dormant" note (one line), exit 0        │
│  ├─ Protected branch → emit "dormant" note (one line), exit 0       │
│  ├─ Onboarding incomplete → inject github-actions-onboarding skill  │
│  │                          wrapped in <EXTREMELY-IMPORTANT>        │
│  └─ Healthy → inject using-24hour-ClaudeCode/SKILL.md (the runtime  │
│              contract) wrapped in <EXTREMELY-IMPORTANT>             │
│                                                                     │
│  Initialize <runtime>/state.json with mode="idle" if absent.        │
│  Write <runtime>/.gitignore with `*` so runtime files never leak.   │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
                Output JSON via stdout:
                {"hookSpecificOutput": {
                  "hookEventName": "SessionStart",
                  "additionalContext": "<runtime contract>"
                }}
                              │
                              ▼
              Claude reads the runtime contract and is ready.
```

---

## Phase 2 — Claude edits code

**Trigger:** Claude calls `Edit`, `Write`, or `MultiEdit`.
**Hook:** `PostToolUse` with matcher `Edit|Write|MultiEdit`.

```
┌─ PostToolUse hook fires after each Edit/Write/MultiEdit ────────────┐
│                                                                     │
│  post-tool-use.sh (5 lines):                                        │
│    mkdir -p <runtime>                                               │
│    touch <runtime>/dirty                                            │
│    exit 0                                                           │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

That's the entire role of `PostToolUse`. No JSON output. No commits. The dirty flag is a fast hint for the upcoming `Stop` hook ("a tool call modified files this turn"). `git diff` remains the source of truth.

---

## Phase 3 — Turn ends, the loop runs

**Trigger:** Claude finishes the response (turn boundary).
**Hook:** `Stop` (no matcher; fires every turn end).

This is the workhorse. It is **mode-aware** — `state.json.mode` ∈ {`idle`, `waiting_for_preflight_merge`, `waiting_for_checks`, `ready_for_rework`, `merged`}.

```
┌─ Stop hook fires → stop.sh ─────────────────────────────────────────┐
│                                                                     │
│  Pre-checks:                                                        │
│  ├─ enabled=false  → exit 0 silently                                │
│  ├─ not in worktree → exit 0 silently                               │
│  └─ Acquire <runtime>/lock                                          │
│       └─ if held by prior Stop in flight → exit 0 silently          │
│                                                                     │
│  Read mode from <runtime>/state.json (default: idle)                │
│  Read dirty flag and git diff state                                 │
│                                                                     │
│  ┌─ DISPATCH BY MODE ──────────────────────────────────────────────┐│
│  │                                                                ││
│  │  CASE A — mode ∈ {idle, ready_for_rework} AND diff non-empty   ││
│  │           [PRE-PR BRANCH]                                       ││
│  │  ─────────────────────────────────────────────────────────────  ││
│  │  1. detect-changes.sh — classify files (code / lock / docs /   ││
│  │       secrets / workflow / danger)                              ││
│  │     └─ buckets.workflow non-empty AND                           ││
│  │        repair.allow_workflow_in_pr ≠ true →                     ││
│  │           1a. Refuse if .github/workflows/* in committed       ││
│  │               history (return decision:block with manual       ││
│  │               git-reset instructions; see stop:committed_      ││
│  │               workflow_changes in failure-escalation).          ││
│  │           1b. Otherwise call split-workflow-pr.sh:             ││
│  │                 • Save workflow file content                    ││
│  │                 • Revert workflow files on the user's branch   ││
│  │                 • Create preflight/<branch>-workflow-<ts>      ││
│  │                   from origin/<base>                            ││
│  │                 • Apply ONLY workflow changes; commit + push   ││
│  │                 • gh pr create + gh pr merge --auto --squash   ││
│  │                 • Switch back to user's branch                 ││
│  │           1c. state.mode = waiting_for_preflight_merge          ││
│  │               state.preflight_pr = N                            ││
│  │               Emit "📦 Auto-split into preflight PR #N", exit. ││
│  │     └─ if any path matches danger_paths → return decision:block││
│  │        with reason "edit touches sensitive path; need approval" ││
│  │  2. check-stop-conditions.sh — verify max_iterations, branch   ││
│  │     protection, gh auth, diff size                              ││
│  │     └─ if stop:* token returned → emit info + invoke           ││
│  │        failure-escalation, exit 0                               ││
│  │  3. Run config.checks.commands (lint/typecheck/test) fail-fast ││
│  │     └─ on any failure → return decision:block with reason     ││
│  │        "local check failed: <last 50 lines>"                   ││
│  │  4. auto-commit.sh — stage non-danger files,                    ││
│  │       commit "auto: WIP on <branch> [HH:MM:SS]" (placeholder) ││
│  │  5. git push -u origin <branch>                                ││
│  │  6. ensure-pr.sh — gh pr view || gh pr create --draft --fill   ││
│  │  7. Iteration accounting:                                       ││
│  │     • mode was ready_for_rework → iteration += 1               ││
│  │     • mode was idle → iteration = 1 (first push for this PR)   ││
│  │  8. State transitions:                                          ││
│  │     • mode = waiting_for_checks                                 ││
│  │     • pr_number = N                                             ││
│  │     • Clear <runtime>/dirty                                     ││
│  │  9. Initial poll-github.sh (best effort baseline)              ││
│  │ 10. Emit additionalContext:                                    ││
│  │     "Iteration #N. PR #M (draft) at <url>. CI starting."       ││
│  │     exit 0  (Claude is allowed to stop; next Stop resumes)     ││
│  │                                                                ││
│  ├────────────────────────────────────────────────────────────────┤│
│  │                                                                ││
│  │  CASE B — mode = waiting_for_checks                            ││
│  │           [POST-PR BRANCH — POLL & DECIDE]                      ││
│  │  ─────────────────────────────────────────────────────────────  ││
│  │  1. wait-for-checks.sh --pr N --timeout=config.repair.wait_s   ││
│  │     • Returns 0: all checks reached terminal conclusion        ││
│  │     • Returns 1: timeout — emit "still running" info, exit 0   ││
│  │  2. poll-github.sh — full snapshot to <runtime>/feedback.json: ││
│  │     • PR state + mergeStateStatus + isDraft                     ││
│  │     • All checks (with conclusions)                             ││
│  │     • All reviews (state + body)                                ││
│  │     • All comments (issue + inline review comments)             ││
│  │     • Failed-job logs (last 50 lines per failed check)          ││
│  │  3. decide-feedback.sh — apply the matrix:                      ││
│  │                                                                ││
│  │     ── feedback_good ──                                         ││
│  │     gh pr merge --auto --merge (or squash/rebase per config)   ││
│  │     mode = "merged"                                             ││
│  │     emit "✅ PR #N merged: <url>", exit 0                       ││
│  │                                                                ││
│  │     ── rework_required ──                                       ││
│  │     mode = "ready_for_rework"                                   ││
│  │     return JSON:                                                ││
│  │       {"decision":"block",                                      ││
│  │        "reason":"PR #N feedback requires rework. Iter N+1/M.\n ││
│  │                  <feedback summary>\n                           ││
│  │                  Apply minimal fixes per rework-implementation."}││
│  │     ⚠ This blocks Claude from stopping. Claude reads `reason`   ││
│  │       as next-turn context and continues editing.               ││
│  │                                                                ││
│  │     ── inconclusive ──                                          ││
│  │     emit "Polled, can't decide yet. Will retry next stop."     ││
│  │     exit 0                                                      ││
│  │                                                                ││
│  │     ── stop:max_iterations / stop:repeated_failure ──           ││
│  │     emit STOP message + invoke failure-escalation skill        ││
│  │     exit 0                                                      ││
│  │                                                                ││
│  ├────────────────────────────────────────────────────────────────┤│
│  │                                                                ││
│  │  CASE C — mode = idle, diff empty                              ││
│  │           [CHAT-ONLY TURN]                                      ││
│  │  ─────────────────────────────────────────────────────────────  ││
│  │  Nothing to do. Release lock. exit 0.                           ││
│  │                                                                ││
│  ├────────────────────────────────────────────────────────────────┤│
│  │                                                                ││
│  │  CASE D — mode = merged                                         ││
│  │           [POST-MERGE CLEANUP]                                  ││
│  │  ─────────────────────────────────────────────────────────────  ││
│  │  Delete <runtime>/current-pr.json, feedback.json, dirty         ││
│  │  Reset state.json: mode="idle", iteration=0, pr_number=null     ││
│  │  exit 0                                                         ││
│  │                                                                ││
│  ├────────────────────────────────────────────────────────────────┤│
│  │                                                                ││
│  │  CASE E — mode = waiting_for_preflight_merge                    ││
│  │           [WORKFLOW-FILE PREFLIGHT IN FLIGHT]                   ││
│  │  ─────────────────────────────────────────────────────────────  ││
│  │  gh pr view <preflight_pr> --json state                        ││
│  │     └─ MERGED → git fetch + git rebase origin/<base>;          ││
│  │       state.mode = idle, state.preflight_pr = null;            ││
│  │       FALL THROUGH to Case A (commits remaining diff).         ││
│  │       Rebase conflict → emit info "resolve manually", exit.    ││
│  │     └─ OPEN → emit info "still waiting", exit 0.               ││
│  │     └─ CLOSED-not-merged → emit "stop:preflight_closed",       ││
│  │       reset to idle, invoke failure-escalation.                ││
│  │                                                                ││
│  └────────────────────────────────────────────────────────────────┘│
│                                                                     │
│  Always: release <runtime>/lock on exit (via trap)                  │
│  Always: append event to <runtime>/last-run.json                    │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Phase 3.5 — Workflow auto-split (Case A 1a–1c, expanded)

**Why:** GitHub returns HTTP 401 ("Workflow validation failed") when the Claude App tries to authenticate against a PR whose `.github/workflows/*.yml` differs from the default branch. The plugin's auto-review breaks on any PR that mixes workflow + code changes. Solution: split the workflow changes into a separate "preflight" PR that auto-merges first.

```
┌─ Case A 1b — split-workflow-pr.sh ──────────────────────────────────┐
│                                                                     │
│  Inputs (stdin or auto-detected):                                   │
│    • workflow file paths (from buckets.workflow)                    │
│                                                                     │
│  1. Detect base branch via gh repo view --json defaultBranchRef     │
│  2. Refuse if any workflow file in committed (un-pushed) history    │
│     (out of v1 scope; user fixes manually via git reset/amend)      │
│  3. Save current working-tree content of each workflow file to      │
│     $TMPDIR (one file per path)                                     │
│  4. On the user's branch: revert each workflow file to              │
│     origin/<base>'s version (so the diff no longer contains them);  │
│     untracked workflow files removed entirely                       │
│  5. Stash any remaining non-workflow changes (so the next checkout  │
│     doesn't carry them over)                                        │
│  6. git checkout -b preflight/<branch>-workflow-<timestamp>         │
│       starting from origin/<base>                                   │
│  7. Apply saved workflow content to the preflight branch;           │
│       git add .github/workflows/<paths>; commit                     │
│  8. git push -u origin <preflight-branch>                           │
│  9. gh pr create --base <base> --head <preflight-branch>            │
│       (PR title: "ci: workflow pre-merge for <branch>")             │
│ 10. gh pr merge --auto --squash <pr_num>                            │
│ 11. git checkout <user-branch>; git stash pop                        │
│       (working tree now contains code-only changes)                 │
│ 12. Output PR number on stdout; exit 0                              │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
                state.mode = waiting_for_preflight_merge
                state.preflight_pr = N
                              │
              (subsequent stops handle Case E above)
```

**Branch-protection caveat.** Auto-merge on the preflight PR depends on required checks completing. If the user has configured `claude-code-review` as a *required* branch-protection check, the preflight will hang because the auto-review on a workflow-only PR also hits the 401. The plugin documents this in `using-24hour-ClaudeCode/SKILL.md`; users must keep `claude-code-review` advisory.

**Override.** Setting `repair.allow_workflow_in_pr=true` in `.claude/24hour-ClaudeCode.config.json` skips the split; workflow + code go in one PR; auto-review fails; manual review required.

**Out of scope (v1).** Already-committed workflow files are not auto-extracted (would require interactive rebase / `git filter-branch`). The hook returns `decision:block` with manual git-reset instructions.

---

## Phase 4 — Claude reacts to `decision:block`

**Trigger:** the previous Stop hook returned `{"decision":"block","reason":"..."}`.
**Hook:** none — this is Claude's reasoning loop.

```
Claude receives `reason` as next-turn context:
  "PR #N feedback requires rework. Iteration <X>/<MAX>.
   <feedback summary with file:line citations>
   Apply minimal fixes per the rework-implementation skill."
                              │
                              ▼
Claude invokes the appropriate phase skill:
  ├─ ci-feedback-analysis        (if CI failed)
  ├─ review-feedback-analysis    (if CHANGES_REQUESTED or actionable comments)
  └─ rework-implementation       (always — for the actual code changes)
                              │
                              ▼
Claude edits the cited files
                              │
                              ▼
PostToolUse hook fires → touches <runtime>/dirty
                              │
                              ▼
Claude finishes turn → Stop hook fires
                              │
                              ▼
              Loops back into Phase 3, Case A (pre-PR branch)
              with mode=ready_for_rework → iteration += 1
```

---

## Phase 5 — Auto-merge & success

When `decide-feedback.sh` returns `feedback_good`:

```
Stop hook (mode=waiting_for_checks):
  1. gh pr merge "$PR" --auto --merge   (or --squash / --rebase per config)
  2. state.mode = "merged"
  3. record_event "merged"
  4. emit additionalContext: "✅ PR #N merged: <url>"
  5. exit 0
                              │
                              ▼
Claude sees the success message; the user's task is done.
                              │
                              ▼
On the NEXT Stop fire (any subsequent turn):
  Stop hook (mode=merged):
    Cleanup current-pr.json, feedback.json, dirty
    state.mode = "idle", iteration = 0, pr_number = null
    exit 0
                              │
                              ▼
                  Runtime is back to idle — ready for the next feature.
```

---

## State machine summary

```
            (turn ends, no diff)              (turn ends, diff non-empty)
                  │                                       │
                  ▼                                       ▼
       ┌─────────────────────┐                 ┌──────────────────────┐
       │    idle             │ ─── PHASE 3.A ─→│ waiting_for_checks   │
       │    iteration=0      │                 │  iteration=1         │
       └─────────────────────┘                 └──────────────────────┘
                  ▲                                       │
                  │                                       │ PHASE 3.B
                  │                                       │
        ┌─────────┴─────────┐                       ┌─────┴─────┐
        │   merged          │                       │  decide   │
        │  (cleanup pass)   │                       └─────┬─────┘
        └─────────▲─────────┘                             │
                  │                                       │
        feedback_good                                rework_required
                  │                                       │
                  │                                       ▼
                  │                          ┌──────────────────────┐
                  └──── (auto-merge) ────────│  ready_for_rework    │
                                             │  Stop returns        │
                                             │  decision:block      │
                                             └──────────┬───────────┘
                                                        │
                                                        ▼
                                              Claude edits → next turn
                                                        │
                                                        ▼
                                             back to PHASE 3.A
                                             (iteration += 1)
```

---

## Stop conditions (loop termination)

Enforced by `scripts/check-stop-conditions.sh` (in pre-PR branch) and `scripts/decide-feedback.sh` (in post-PR branch):

| Condition | Token | Where caught |
|---|---|---|
| `iteration >= max_iterations` (default 5) | `stop:max_iterations` | decide-feedback.sh |
| Same failure 2 iterations in a row | `stop:repeated_failure` | check-stop-conditions.sh (via `<runtime>/last-run.json` fail_streak) |
| Branch is protected | `stop:protected_branch` | check-stop-conditions.sh |
| `gh auth status` fails | `stop:gh_auth_lost` | check-stop-conditions.sh |
| `git push` rejected | `stop:push_rejected` | stop.sh (push step) |
| Diff exceeds `max_diff_lines` (default 500) | `stop:diff_too_large` | check-stop-conditions.sh |
| Edit touches `danger_paths` | `stop:danger_path` | stop.sh (via detect-changes.sh) |

When any fires:
- Stop hook emits an `additionalContext` STOP message.
- `failure-escalation` skill is invoked to format the user-facing message.
- Loop terminates; user must intervene.

---

## Runtime state files

```
<project>/.claude/runtime/24hour-ClaudeCode/
├── .gitignore         # contains `*` — runtime files never leak into git diffs
├── state.json         # {enabled, repo, branch, pr_number, mode, iteration, max_iterations, last_status}
├── lock/              # directory; presence = stop.sh in flight
│   └── holder         # {pid, acquired_at}
├── lock.queued        # presence = another Stop fired during lock-held
├── dirty              # presence = code-modifying tool used this turn (set by post-tool-use.sh)
├── last-run.json      # {ts, status, detail, fail_streak} per stop.sh invocation
├── current-pr.json    # last known PR snapshot (number, url, isDraft, head SHA, ...)
└── feedback.json      # last poll: pr + checks + reviews + comments + failed_jobs
```

All writes are atomic (temp + mv). Direct edits are forbidden — always go through `scripts/runtime-state.sh`, `scripts/runtime-lock.sh`, or `scripts/poll-github.sh`.

---

## End-to-end timeline (one feature)

```
T+0:00   User opens worktree, starts Claude Code
         └─ SessionStart hook → bootstrap.sh → inject runtime contract

T+0:01   User: "add OAuth refresh logic"

T+0:30   Claude finishes editing src/auth/handler.ts
         └─ PostToolUse hook fires after each Edit → touches dirty
         └─ Stop hook fires (turn end)
            └─ Case A: pre-PR branch
               • detect-changes ✓
               • verify (lint/typecheck/test) ✓
               • commit "auto: WIP on feat/oauth-refresh [10:00:30]"
               • push origin feat/oauth-refresh
               • gh pr create --draft → PR #142
               • mode = waiting_for_checks
               • emit "Iteration #1. PR #142 draft. CI starting."

T+0:30   Claude is allowed to stop. User reads the message.
         User says: "looks good"

T+0:31   Claude responds with brief confirmation (no edits)
         └─ Stop hook fires (turn end)
            └─ Case B: waiting_for_checks branch
               • wait-for-checks.sh — CI still running, timeout
               • emit "CI still running. Will check next stop."

T+3:00   User: "check progress"

T+3:01   Claude responds
         └─ Stop hook fires
            └─ Case B: wait-for-checks ✓ (all green)
               • poll-github → feedback.json: all success, no review comments
               • decide-feedback → feedback_good
               • gh pr merge --auto --merge 142
               • mode = merged
               • emit "✅ PR #142 merged: <url>"

T+3:01   User sees success message.

T+3:02   User starts a new feature in the same worktree
         └─ Stop hook fires later (mode=merged)
            └─ Case D: cleanup → mode=idle, iteration=0
         └─ Loop ready for next feature.
```

---

## Slash commands (debug only — never primary control flow)

| Command | Effect |
|---|---|
| `/24hour-ClaudeCode:status` | Show state.json, last-run.json, current-pr.json contents |
| `/24hour-ClaudeCode:retry` | Force-clear lock, manually trigger Stop hook once |
| `/24hour-ClaudeCode:setup` | Re-run the onboarder (Phase 0) |
| `/24hour-ClaudeCode:enable` | Set `config.enabled = true` |
| `/24hour-ClaudeCode:disable` | Set `config.enabled = false` (both hooks go silent) |
| `/24hour-ClaudeCode:clear-lock` | Last resort — delete `<runtime>/lock` after diagnostics |

The main flow is hook-driven. These commands exist as escape hatches.

---

## Optional: Superset workspace integration

Phases 0–5 above are the **Claude Code-driven** flow. They run regardless of whether you use [Superset](https://docs.superset.sh) (a 3rd-party multi-worktree manager).

If your team uses Superset to manage worktrees as "workspaces", the plugin offers an **optional** integration that wraps around the auto-PR loop. Superset's lifecycle hooks are **separate from** Claude Code's hooks — they fire at different boundaries and serve different purposes.

### Comparison

| Layer | Trigger | Scope | What it does |
|---|---|---|---|
| **Claude Code hooks** (this plugin) | session start / tool boundary / turn boundary | Single conversation | Drives the auto-PR loop (Phases 1–5) |
| **Superset hooks** (optional, 3rd-party) | workspace open / Run button / workspace close | Worktree lifecycle | Provisions the worktree (deps, env), starts dev server, cleans up |

They overlap only at **workspace-open time** — Superset's `setup.sh` calls `check-actions.sh` to validate the auto-PR loop is healthy before the user starts coding.

### Superset's three lifecycle scripts

Installed by `bash scripts/install-superset-config.sh` (one-time, per repo). Lives at `<repo>/.superset/`:

```
when user opens a workspace ──→ .superset/setup.sh
                                  ├─ verify worktree (git worktree list)
                                  ├─ verify plugin installed at .claude/plugins/24hour-ClaudeCode/
                                  ├─ verify gh authed + workflow scope
                                  ├─ verify Claude Code Actions deployed (calls scripts/check-actions.sh)
                                  ├─ initialize <runtime>/ directory (calls runtime-state.sh init)
                                  ├─ install project deps (npm/pnpm/yarn/bun/pip/poetry/cargo/...)
                                  └─ print one-screen cheat sheet of commands
                                  ⚠ Forbidden here: commit, push, create PR, wait CI, auto-merge

when user clicks Run ────────→ .superset/run.sh
                                  └─ start project's dev server (project-specific; user customizes)
                                  ⚠ Forbidden here: trigger PR flow, read CI, auto-merge

when user closes workspace ──→ .superset/teardown.sh
                                  ├─ clear runtime lock + transient decision files
                                  └─ print reminder: "if PR is MERGED, clean up worktree from MAIN checkout"
                                  ⚠ Forbidden here: close PR, delete remote branch, merge PR
```

### Where Superset overlaps with the auto-PR loop

```
T+0       User opens Superset workspace
          └─ Superset runs .superset/setup.sh (NOT a Claude Code hook)
             • check-actions.sh validates workflow YAMLs + secret
             • runtime-state.sh init creates <runtime>/state.json (mode=idle)
             • prints cheat sheet

T+0:01    User opens Claude Code in this workspace
          └─ Claude Code's SessionStart hook fires bootstrap.sh (Phase 1)
             • Reads the same <runtime>/ Superset's setup.sh just initialized
             • Injects the runtime contract; Claude is ready

          From here, Phases 2–5 run normally. Superset is dormant
          unless the user clicks Run (calls run.sh — independent of the loop).

T+later   User closes the workspace
          └─ Superset runs .superset/teardown.sh (NOT a Claude Code hook)
             • Clears runtime lock so a future workspace creation is clean
```

### Without Superset

Everything still works the same. Replace step T+0 above with:

```
T+0       User runs: git worktree add ../my-feature -b feat/my-feature
          User runs: cd ../my-feature && claude
          (User is responsible for running deps install themselves.)
```

The Claude Code hooks (Phases 1–5) are identical regardless. **The Superset integration is purely a convenience layer** for teams who already use Superset to manage worktrees.

### Activation

```bash
# In the main checkout, one-time:
bash .claude/plugins/24hour-ClaudeCode/scripts/install-superset-config.sh
git add .superset/ && git commit -m "Add Superset config" && git push
```

After this, every Superset workspace your team opens runs through the lifecycle scripts above. Verify with:

```bash
bash .claude/plugins/24hour-ClaudeCode/scripts/install-superset-config.sh --verify
```

See `references/superset-integration.md` for full details, customization, and troubleshooting.
