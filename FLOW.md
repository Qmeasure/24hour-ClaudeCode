# 24hour-ClaudeCode Flow

This is the architecture source of truth for the skill-first review loop.

## Summary

```text
SessionStart hook = inject the right skill context
Stop prompt hook = route the current session back to review-loop
review-loop skill = complete PR/review/fix/merge workflow
github-actions-onboarding skill = complete repo onboarding workflow
current Claude Code session = fixer
GitHub Claude Code Action = reviewer
scripts = deterministic mechanical helpers only
```

The Stop hook is not a workflow engine. It is a prompt-based router: if Claude appears ready to stop after implementation, it blocks stopping with a short instruction to use `review-loop`.

## Superpowers-Inspired Principles

1. **Hook routes, skill runs workflow.** Hooks may inject context or block stopping with a skill trigger. Hooks must not own long transactions.
2. **Skill carries behavior and judgment.** PR review, rework, CI triage, stopping, merge, and onboarding decisions belong in `review-loop` or `github-actions-onboarding`.
3. **Script is mechanical only.** Scripts need clear input/output, repeatability, and exit codes. They must not commit, push, wait for review, parse loop state, or merge.
4. **Goal mode is native.** Claude Code `/goal` is a built-in session-scoped prompt-based Stop hook. Do not reimplement Goal state with project scripts.
5. **Current session fixes.** The same Claude Code session and WorkTree handle feedback. Do not start another Claude CLI, daemon, or background fixer.
6. **GitHub Action reviews only.** GitHub Claude Code Action is the reviewer, not the repair worker.
7. **Description triggers, body instructs.** Skill frontmatter `description` states when to use the skill; workflow details live in the skill body.

## Hook Table

| Hook | Handler | Purpose |
|---|---|---|
| `SessionStart` | `command: hooks/bootstrap.sh` | Detect environment and inject `github-actions-onboarding` or `using-24hour-ClaudeCode` as context. SessionStart does not support prompt hooks. |
| `Stop` | `prompt` in `hooks/hooks.json` | Decide whether Claude may stop, or block with `REVIEW_LOOP_CONTINUE` so the current session uses `review-loop`. |
| `Stop` while `review-loop` skill is active | `prompt` in `skills/review-loop/SKILL.md` | Keep the active review loop from stopping until `REVIEW_LOOP_DONE`, `REVIEW_LOOP_STOPPED`, or explicit user stop. |

There is no `UserPromptSubmit` Goal hook, no `PostToolUse` dirty marker, no async monitor, and no Stop-hook shell workflow.

## Runtime Files

In each user worktree:

```text
.claude/runtime/24hour-ClaudeCode/
├── .gitignore                 # contains "*" and "!.gitignore"
└── review-loop-state.md       # visible state owned by review-loop skill
```

Allowed review-loop states:

```text
REVIEW_LOOP_ACTIVE
REVIEW_LOOP_DONE
REVIEW_LOOP_STOPPED
```

The state file records PR number, current HEAD SHA, round number, review source, feedback summary, failure fingerprint, stop reason, and timestamp.

## Goal Mode

Use Claude Code's native `/goal <condition>`. Official hooks documentation describes `/goal` as a built-in shortcut for a session-scoped prompt-based Stop hook. This plugin does not create a second Goal guard or marker.

When native `/goal` is still in progress, let the built-in Goal Stop hook keep Claude working. After `/goal` allows the turn to stop, the 24hour-ClaudeCode Stop prompt may route the session to `review-loop`.

## Review Loop Skill

When Stop emits `REVIEW_LOOP_CONTINUE`, Claude must invoke `skills/review-loop/SKILL.md`.

The skill workflow:

1. Confirm the current checkout is a feature worktree, not the main checkout or a protected branch.
2. Mark `REVIEW_LOOP_ACTIVE`.
3. Enforce configured max rounds and repeated-failure stops.
4. Inspect local changes and configured `danger_paths`.
5. Run configured local checks when applicable.
6. Commit current changes.
7. Push current branch.
8. Create, update, and ready the PR.
9. Record `CURRENT_HEAD_SHA=$(git rev-parse HEAD)`.
10. Wait for a completed GitHub Claude Code Action review run whose `headSha` equals `CURRENT_HEAD_SHA`.
11. Read real GitHub review surfaces.
12. Fix blocking/important feedback in the same WorkTree.
13. Classify required external CI failures inside the same skill.
14. Repeat until pass, stopped, or merged.
15. On reliable pass, enable auto-merge or merge, then write `REVIEW_LOOP_DONE`.

The current Claude Code session is the only fixer. The GitHub Action is reviewer only.

## Review Evidence Rules

Do not assume custom verdict artifacts exist.

Valid evidence can come from:

- PR review submissions
- inline review comments
- check run details, annotations, and logs
- PR comments only when clearly tied to the accepted current-SHA review run

Hard gates:

- No missing review as pass.
- No stale review as pass.
- No ambiguous review as pass.
- No auto-merge unless PR head equals current local HEAD SHA.
- If SHA binding cannot be confirmed, write `REVIEW_LOOP_STOPPED`.

## Scripts

Allowed script categories:

- version synchronization
- Superset config file install/verify

Disallowed script categories:

- whole-loop orchestration
- waiting/deciding/merging controllers
- custom verdict artifact gates
- background daemons that write code

## Official Hook Model

Claude Code hooks are not only shell command strings. Official docs list hook handler types `command`, `http`, `mcp_tool`, `prompt`, and `agent`; they also define JSON output modes such as `additionalContext`, `systemMessage`, and Stop prompt decisions. Skill frontmatter can also define hooks scoped to the skill lifecycle.

This plugin uses that model this way:

- `SessionStart` remains a command hook because official docs say `SessionStart` supports `command` and `mcp_tool`, not `prompt`.
- `Stop` is a prompt hook, because routing the current Claude session to a skill is a semantic decision.
- `review-loop` also defines a skill-scoped prompt Stop hook so a closed loop cannot accidentally stop halfway.

Do not add a prompt or agent hook that performs PR/review/merge work. Non-command hooks may route or guard; skills do the workflow.

## Slash Commands

| Command | Purpose |
|---|---|
| `/24hour-ClaudeCode:setup` | Invoke onboarding skill. |
| `/24hour-ClaudeCode:status` | Read visible review-loop state, git status, and current PR. |
| `/24hour-ClaudeCode:retry` | Clear `REVIEW_LOOP_STOPPED` state after the root cause is fixed. |
| `/24hour-ClaudeCode:disable` | Stop automatic review-loop triggering. |
| `/24hour-ClaudeCode:enable` | Re-enable automatic review-loop triggering. |

## Acceptance Checks

Use these checks when changing the runtime:

```bash
bash -n hooks/*.sh scripts/*.sh templates/*.sh
jq -e . hooks/hooks.json
jq -e . .claude-plugin/plugin.json
jq -e . templates/24hour-ClaudeCode.config.json
bash scripts/install-superset-config.sh --verify
```

For Stop routing, inspect `/hooks` in Claude Code and confirm:

- plugin `Stop` hook type is `prompt`
- `review-loop` skill frontmatter defines a `Stop` prompt hook
- no hook entry points to `hooks/stop.sh`, `hooks/goal-submit.sh`, or `hooks/post-tool-use.sh`
