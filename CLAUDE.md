# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

This is **`24hour-ClaudeCode`**, a Claude Code **plugin** (not a standalone skill, not an application). The repo is structured per the [official plugin format](https://code.claude.com/docs/en/plugins-reference.md):

- `.claude-plugin/{plugin,marketplace}.json` — plugin manifest + self-hosted marketplace
- `hooks/` — three hooks: `SessionStart` (bootstrap.sh) + `PostToolUse` (post-tool-use.sh, light marker) + `Stop` (stop.sh, the heavy orchestrator)
- `skills/` — 1 bootstrap meta-skill (`using-24hour-ClaudeCode`, auto-injected by SessionStart) + 7 phase skills invoked on demand by the `Skill` tool
- `commands/` — 6 debug slash commands (status / retry / setup / enable / disable / clear-lock)
- `scripts/` — 16 deterministic bash helpers (gh / git / runtime state) called by hooks and commands
- `templates/` — workflow YAMLs (rendered into user projects via `render-workflows.sh`) + config schema + Superset lifecycle scripts (setup/run/teardown)
- `references/` — topic deep-dives (English) cross-linked from skills
- `.github/workflows/` — **THIS repo's self-review** workflows (NOT the templates that ship to users). They review PRs to the plugin source itself, with plugin-architecture-aware dimensions. See "Two distinct workflow tiers" below.

Distribution is via `/plugin install <marketplace>/24hour-ClaudeCode`. The plugin can also be cloned manually into `<project>/.claude/plugins/`.

There is no compile step, no test runner, no package manager. Everything is bash + jq + gh.

## Project name vs. on-disk path

The on-disk repo path is currently `worktree-pr-flow/` for git history continuity, but the **plugin slug is `24hour-ClaudeCode`** (declared in `.claude-plugin/plugin.json`). Slash commands, runtime paths, config filenames, and skill cross-references all use `24hour-ClaudeCode`. Do not "fix" this inconsistency — they are intentionally separate.

## Two distinct workflow tiers

This repo has **two sets** of GitHub Actions workflow YAMLs that look similar but serve different audiences. Don't confuse them.

| Where | Audience | Purpose |
|---|---|---|
| **`.github/workflows/claude-code-review.yml`** + **`.github/workflows/claude.yml`** | Plugin maintainers (us) | **Self-review** — fires when someone opens a PR against this repo. The prompt is plugin-architecture-aware (checks 17 dimensions: hook coherence, state machine integrity, decision:block contract, sub-skill orthogonality, etc.). |
| **`templates/claude-code-review.yml`** + **`templates/claude.yml`** | End users who install this plugin | **Generic project review** — these are the static fallbacks that get rendered (or copied with `--static-templates`) into user projects via `render-workflows.sh`. Their prompt invokes the official `code-review` plugin, not custom dimensions. |

Both pairs are needed. **When you change the templates, also confirm the self-review workflows still work** — the renderer logic is implemented in `scripts/render-workflows.sh` and reads the templates as fallback or as base structure.

The self-review workflows specifically encode invariants like "hook architecture coherence", "decision:block contract", "stale-lock detection must remain", "bilingual triggers preserved", "cross-script token consistency". When you add a new architectural invariant (e.g., a new state.json field), update the self-review YAML's prompt so future PRs get audited against it.

## Audit fix conventions (post-Revision 2)

Several defensive helpers exist after the security/correctness audit. **Do not remove these without re-auditing**:

- **`scripts/is-protected-branch.sh`** — single source of truth for "is this branch protected?". Queries real GitHub branch protection (`gh api repos/X/branches/$branch`) with a hardcoded fallback (main/master/develop/dev/staging/production/release/prod + `release/*`/`hotfix/*` globs) when offline. Caches per-branch results in `state.json.protected_branch_cache`. Used by `bootstrap.sh`, `auto-commit.sh`, `check-stop-conditions.sh`. Never bypass it with a fresh inline `case` statement.

- **Stale-lock detection in `runtime-lock.sh`** — before `mkdir $LOCK_DIR`, the script checks if a held lock has a dead PID AND is >30 min old. If both, it clears the orphan and acquires fresh. Without this, a SIGKILL of `stop.sh` deadlocks the runtime forever. The 30-min threshold is conservative because Stop hook timeout is 900s (15 min); only locks older than 2× the max legitimate hold are eligible for stale-clear.

- **`<runtime>/.gitignore`** — bootstrap.sh and `runtime-state.sh init` write a `.gitignore` containing `*` inside `<runtime>/`. This ensures runtime state files (state.json, lock, dirty, current-pr.json, feedback.json, last-run.json) NEVER show up in `git diff` or `git status`. If you ever notice runtime files leaking into a PR diff, the first thing to check is whether this gitignore got removed.

- **`_warnings` array in `feedback.json`** — `poll-github.sh` captures stderr from each `gh` call; on failure it adds a warning entry instead of silently defaulting to `[]`. `decide-feedback.sh` short-circuits to `inconclusive` if any warnings present (don't auto-merge on stale data).

- **Case-insensitive check conclusions in `decide-feedback.sh`** — uses `ascii_downcase` + `IN()` instead of literal string match. GitHub's check conclusion case varies by API path; defensive matching avoids false positives.

- **Actionable-comment regex** — uses imperative-verb pattern (`must fix|need to fix|should fix|please fix|please address|please change|please update`) plus case-sensitive uppercase markers (`TODO:|FIXME:|FIX:|BUG:|XXX:|HACK:`). The previous version (`bug|broken|wrong|...`) false-positived on past-tense praise. Don't widen this pattern without testing the false-positive cases (see test suite in stop.sh smoke tests).

- **Provider question BEFORE Claude OAuth** — `configure-actions.sh` asks `claude / codex / both` at Step 2.5, then conditionally runs `claude setup-token` only if `PROVIDER ∈ {claude, both}`. Codex-only users skip the OAuth dance entirely.

- **Codex action pinned to `@v1.8`** — the `openai/codex-action` repo doesn't have a `@v1` floating tag (verified via `gh api`). Tags are `v1.4`–`v1.8`. The action's input names use **hyphens** (`openai-api-key`, not `openai_api_key`) and its output is `final-message`. Both `templates/codex-review.yml` and the renderer use these correct names.

- **Plugin / marketplace version sync** — `scripts/bump-version.sh` updates both `.claude-plugin/plugin.json` and (when applicable) `.claude-plugin/marketplace.json` atomically. Use `bash scripts/bump-version.sh patch|minor|major|<semver>` or `--check` for drift detection.

## Big-picture architecture (Revision 2 — Stop hook owns the loop)

Three hooks, with strict separation of duties:

```
SessionStart hook  →  bootstrap.sh detects env  →  injects exactly one of:
                       ├── onboarding-incomplete payload
                       ├── dormant payload (not in worktree / protected branch)
                       └── healthy payload (using-24hour-ClaudeCode runtime contract)

PostToolUse hook   →  post-tool-use.sh: touch <runtime>/dirty (5-line marker; cheap)

Stop hook (turn end) → stop.sh: MODE-AWARE ORCHESTRATOR
                       Branches on state.json.mode + git diff:

                       (idle | ready_for_rework) + diff non-empty:
                         danger-paths check → check-stop-conditions →
                         config.checks.commands → auto-commit → push → ensure-pr →
                         iteration handling → mode = waiting_for_checks →
                         emit additionalContext "PR #N draft. CI starting." → exit 0

                       waiting_for_checks:
                         wait-for-checks.sh (with timeout) →
                         poll-github.sh (full snapshot to feedback.json) →
                         decide-feedback.sh → token + reason:
                           • feedback_good   → gh pr merge --auto, mode=merged, exit 0
                           • rework_required → mode=ready_for_rework, return
                                              {"decision":"block","reason":"..."}
                                              ← official mechanism: Claude cannot stop;
                                                 reason is the agent's next-turn context
                           • inconclusive    → wait, retry next stop
                           • stop:*          → invoke failure-escalation, exit 0

                       merged:
                         cleanup current-pr.json + feedback.json + dirty;
                         mode=idle, iteration=0

                       (idle, no diff): silent exit
```

**Key insight — Revision 2:** the agent does NOT poll, does NOT decide, does NOT call `gh pr merge`. The Stop hook does all of that deterministically. The agent's job is solely to **edit code in response to `decision:block.reason`** when the hook returns one.

## scripts/ pipeline (data flow)

```
detect-changes.sh   → emits JSON with files + buckets (code/lock/docs/secrets/workflow/danger)
check-stop-conditions.sh → reads state + config, returns continue|stop:<token>
auto-commit.sh      → stages non-danger files, commits with `auto: WIP` placeholder, returns SHA
ensure-pr.sh        → gh pr view || gh pr create --draft --fill; writes <runtime>/current-pr.json
poll-github.sh      → snapshots state/checks/reviews/comments to <runtime>/feedback.json
runtime-state.sh    → init/get/set/incr atomic state operations (jq + temp+mv)
runtime-lock.sh     → mkdir-based atomic lock with queue flag
configure-actions.sh, render-workflows.sh, detect-project.sh, check-actions.sh, install-superset-config.sh, superset-launch.sh
                    → reused unchanged from the previous skill incarnation
```

## Hook output convention

Both hooks emit JSON to stdout per the Claude Code spec:

```json
{"hookSpecificOutput": {"hookEventName": "<event>", "additionalContext": "<text>"}}
```

The `additionalContext` is appended to the agent's context. Per superpowers' pattern, we wrap critical content in `<EXTREMELY-IMPORTANT>` to ensure attention.

## Auto-generated files

`hooks/on-edit.sh` writes to several runtime files atomically. **Never edit these directly:**

- `<project>/.claude/runtime/24hour-ClaudeCode/state.json` — managed by `runtime-state.sh`
- `<project>/.claude/runtime/24hour-ClaudeCode/lock` — managed by `runtime-lock.sh`
- `<project>/.claude/runtime/24hour-ClaudeCode/last-run.json` — managed by `record_event` in on-edit.sh
- `<project>/.claude/runtime/24hour-ClaudeCode/current-pr.json` — managed by `ensure-pr.sh`
- `<project>/.claude/runtime/24hour-ClaudeCode/feedback.json` — managed by `poll-github.sh`

## Commands (for editing this repo)

```bash
# Smoke-check (the only "test" that exists)
bash -n hooks/*.sh scripts/*.sh

# Validate JSON manifests
jq -e . .claude-plugin/plugin.json
jq -e . .claude-plugin/marketplace.json
jq -e . hooks/hooks.json
jq -e . templates/24hour-ClaudeCode.config.json

# Smoke-test the bootstrap hook on synthetic worktrees
TMP=$(mktemp -d) && cd "$TMP" && git init -q && \
  git -c user.email=x@x -c user.name=x commit --allow-empty -q -m init
TMP_WT=$(mktemp -d) && rmdir "$TMP_WT" && git worktree add "$TMP_WT" -b feat/test -q
CLAUDE_PLUGIN_ROOT=/Users/lesterbot/Downloads/worktree-pr-flow CLAUDE_PROJECT_DIR="$TMP_WT" \
  bash hooks/bootstrap.sh < /dev/null | jq

# Smoke-test the on-edit hook with a fake gh
# (see hooks/on-edit.sh top for the test recipe)

# Verify a full plugin install on a synthetic project
TEST_PROJECT=$(mktemp -d) && cd "$TEST_PROJECT" && git init -q && touch a.txt && \
  git -c user.email=x@x -c user.name=x commit -q -am init
mkdir -p .claude/plugins
ln -s /Users/lesterbot/Downloads/worktree-pr-flow .claude/plugins/24hour-ClaudeCode
# Now simulate Claude Code:
# - bootstrap.sh fires on session start
# - on-edit.sh fires after Edit/Write/MultiEdit
```

There are no `npm` / `pip` / `cargo` / `make` commands.

## Conventions

**Bash scripts:** `set -euo pipefail`. For arrays that may be empty, use safe expansion `${arr[@]+"${arr[@]}"}` (plain `"${arr[@]}"` errors under `set -u` when empty).

**Hook output:** Avoid `$(cat <<EOF ... EOF)` patterns when the body contains apostrophes or unbalanced quotes — bash's parser inside `$(...)` is sensitive even though the outer heredoc is "supposed to be" opaque. Prefer `printf '%s\n' "..." "..."` line-by-line construction. We learned this the hard way during initial development.

**Markdown content for Claude (skills + references):** all English. The Chinese version exists only at `README.zh-CN.md`. Frontmatter for skills is just `name` + `description`. Use strong directive markup (`<EXTREMELY-IMPORTANT>`, "Iron Law") sparingly — once per skill at most, on the most important rule.

**Skill granularity:** small, single-responsibility, one phase each. The bootstrap meta-skill teaches Claude how to dispatch to others. Don't fold logic that should live in a phase skill back into the meta.

**Decision tables in skills:** prefer two-column tables over prose for branching logic. (See `babysit-pr/SKILL.md` for the canonical example.)

**`<runtime>` placeholder convention:** in skill text, `<runtime>` means `<project>/.claude/runtime/24hour-ClaudeCode/`. The skills don't hardcode the path so Claude can substitute correctly when reading.

## What NOT to do

- **Never re-introduce a `~/.claude/plugins/` install path.** The plugin is project-level only because hooks must be project-scoped and workflow YAMLs are repo-tailored.
- **Never add a `prompt:` field to a slash command** that bypasses the corresponding skill. Slash commands are debug helpers; primary flow is hook-driven.
- **Never auto-merge from a hook.** `gh pr merge --auto` is invoked by the agent, mediated by the `using-24hour-ClaudeCode` skill, after the agent has reviewed the diff and written a proper commit message. The hook is deterministic but doesn't make merge-enable decisions.
- **Never block on hook failure.** All hooks exit 0. A hook failure should print to additionalContext and let the agent decide; non-zero exits surface as tool-call errors.
- **Never put apostrophes inside `<<EOF` heredoc bodies that are inside `$(...)` command substitution.** See the `printf '%s\n'` pattern in `on-edit.sh`.
- **Never modify `.github/workflows/` from inside a Claude Code Action run.** GitHub blocks it for security; the rendered workflow blocks it via `--disallowed-tools`.
- **Never rename the `Auto-generated by` headers** in rendered workflow YAMLs. The renderer's manual-edit detection greps that string.

## Plugin name vs. legacy `worktree-pr-flow` references

Some scripts still print "worktree-pr-flow" in error messages or fall back to the old slug. As we update them, replace with `24hour-ClaudeCode`. The migration plan tracks this — see `/Users/lesterbot/.claude/plans/plugin-peaceful-raccoon.md`.

## Phase tracking

Implementation is staged. The migration plan defines 9 phases (0 through 8). Current state: see TaskList. When making changes, identify which phase you're in to avoid landing partial implementations of a future phase.
