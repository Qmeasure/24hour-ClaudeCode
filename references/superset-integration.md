# Superset workspace integration

This document explains how 24hour-ClaudeCode plugs into the [Superset](https://docs.superset.sh) client.

**Use case:** you manage multiple worktrees of one repo through Superset (each workspace = one feature/fix/chore worktree). When opening a workspace, you want **automatic verification** that Claude Code Actions is healthy.

---

## 1. The three Superset hooks

| Hook | When it runs | Purpose |
|---|---|---|
| `setup` | After a new workspace is created (worktree git checkout complete) | Verify env, install deps, copy `.env` |
| `teardown` | Before workspace deletion (only after teardown completes) | Stop Docker, clear caches; **failure does not block**, force-delete is available |
| `run` | When the user clicks Run | Start dev server / run tests in the dedicated pane |

Each hook is a string array, executed in order. Any non-zero exit = hook failure.

## 2. Three environment variables Superset provides

When running setup/teardown/run commands, Superset sets:

| Variable | Meaning |
|---|---|
| `SUPERSET_ROOT_PATH` | Absolute path to the main repo checkout (used to locate skill installation, templates) |
| `SUPERSET_WORKSPACE_NAME` | Current workspace name (usually = branch name) |
| `SUPERSET_WORKSPACE_PATH` | Absolute path to this worktree (cwd when commands run) |

## 3. Config file lookup priority

Superset reads in this order (first found wins):

1. `~/.superset/projects/<project-id>/config.json` — **personal override** (not in version control)
2. `<worktree>/.superset/config.json` — **per-worktree** (rarely useful)
3. `<repo-root>/.superset/config.json` — **project default** (in version control, team-shared)

Bonus: `<repo-root>/.superset/config.local.json` is **auto-gitignored** for personal additions to project defaults.

---

## 4. Recommended config (the skill's template)

`.superset/config.json` plus the three hook scripts at the repo root (installed by `bash scripts/install-superset-config.sh`):

```json
{
  "setup": ["./.superset/setup.sh"],
  "teardown": ["./.superset/teardown.sh"],
  "run": ["./.superset/run.sh"]
}
```

The installed files are:

- `.superset/setup.sh` — verifies plugin/worktree/gh/Actions health, initializes runtime state, and installs detected dependencies.
- `.superset/run.sh` — starts a detected dev command or prints an explicit customization prompt.
- `.superset/teardown.sh` — prints safe cleanup guidance before Superset removes the workspace.

The `setup` hook:

1. Checks the skill is installed at `<root>/.claude/plugins/24hour-ClaudeCode`
2. Health-checks Claude Code Actions
3. Prints a one-screen cheat sheet of commands you can run inside this workspace

**Why setup verifies but doesn't reconfigure:**

- Installing the GitHub App, generating the OAuth token, setting the secret, pushing workflow YAML — all of these are **repo-level one-time** operations.
- Re-doing them per workspace would: waste time, regenerate tokens unnecessarily, repeatedly overwrite secrets.
- Right pattern: run `/24hour-ClaudeCode:setup` once from main checkout. Setup just verifies after.

**Why teardown doesn't auto-remove the worktree:**

- Teardown runs *inside* the worktree. Removing yourself = suicide (Superset's force-delete bypasses this).
- Worktree cleanup must happen in the main checkout (see `SKILL.md` "user clean-up after merge" section).

---

## 4.5 How to actually activate the integration

Running `bash scripts/install-superset-config.sh` only **creates the config and hook scripts**. By itself, this doesn't make Superset use them. Three steps complete activation:

### Step 1: commit + push (team-shared mode)

For teammates to inherit the config, it must be in version control. The installer asks "commit + push now?" — pick yes. Otherwise, manually:

```bash
git add .superset/config.json .superset/setup.sh .superset/run.sh .superset/teardown.sh
git commit -m "Add Superset workspace config"
git push
```

(With `--local`, the config goes to `.superset/config.local.json` and is **auto-added to .gitignore**. Skip this step.)

### Step 2: register the repo with Superset (one-time)

Superset must know the repo is a "project" before it watches `.superset/config.json`. How:

| Your state | Action |
|---|---|
| Already added this repo to Superset | **Nothing**. Next workspace creation picks up the config |
| Not added yet | Open Superset client → Add Project → point at this repo's local path |
| Don't have Superset locally | See https://docs.superset.sh. If your team uses it but you don't, just commit the config — they pick it up |

> ⚠️ This step has **no standard CLI** — different Superset client versions differ. The installer detects `superset` in PATH but does not run any registration command.

### Step 3: verify activation (anytime)

**Without opening Superset:**

```bash
bash scripts/install-superset-config.sh --verify
```

Expected output:

- ✓ Found `.superset/config.json`
- ✓ Config references `.superset/setup.sh`, `run.sh`, and `teardown.sh`
- ✓ Found `.superset/setup.sh`, `.superset/run.sh`, and `.superset/teardown.sh`
- ✓ scripts/check-actions.sh exists and is executable
- ✓ `.superset/config.json` and the three hook scripts are tracked in git
- ✓ Superset CLI is installed: `/usr/local/bin/superset`

Any ✗ exits non-zero.

**With Superset, open a fresh workspace:** the workspace terminal pane should show:

```
╭─────────────────────────────────────────────────────────────────────╮
│ 24hour-ClaudeCode — workspace ready                                 │
│   worktree: feat/my-thing                                           │
│   path:     /path/to/worktree                                       │
╰─────────────────────────────────────────────────────────────────────╯

✓ Skill installed at /path/to/repo/.claude/plugins/24hour-ClaudeCode
✓ Claude Code Actions configured

─── What to do in this workspace ───
  ...
```

Seeing this banner = integration is live.

### Common misunderstandings

| Misunderstanding | Reality |
|---|---|
| "Running install-superset-config.sh activated it" | No — the script only creates the file. Activation = commit + push + Superset knows the repo |
| "Existing workspaces also auto-run setup" | No — setup only runs on **new** workspace creation. Existing workspaces must be recreated to pick it up |
| "Putting config.json in the worktree is enough" | No — Superset priority: `~/.superset/projects/<id>/config.json` > `<worktree>/.superset/config.json` > `<repo-root>/.superset/config.json`. For team sharing, repo root |
| "config.local.json should also be committed" | No — it's designed to be personal, auto-gitignored |

---

## 5. Team-shared vs personal customization

**Team-shared** (in version control):
- `.superset/config.json` — declares the setup/run/teardown commands
- `.superset/setup.sh`, `.superset/run.sh`, `.superset/teardown.sh` — default hook implementations
- `.github/workflows/claude*.yml` — workflow config
- `templates/` — workflow templates

**Personal-only** (not in version control):
- `.superset/config.local.json` — your additions on top of project default (e.g. `cp ~/private.env .env`)
- `~/.superset/projects/<id>/config.json` — completely overrides project defaults

### Customizing without losing defaults

`.superset/config.local.json` is the right place. Example:

```json
{
  "setup": [
    "./.superset/setup.sh",
    "cp ~/private.env .env",
    "docker-compose up -d db"
  ]
}
```

Note: when both `.superset/config.json` AND `.superset/config.local.json` exist, Superset uses **only the highest-priority one** found. So if you put a `config.local.json` it must include all the setup commands you want (re-include `./.superset/setup.sh`).

---

## 6. Typical multi-worktree workflow

First-time onboarding from a fresh repo:

```
┌────────────────────────────────────────────────────┐
│ Main checkout (repo root)                          │
│ $ cd ~/code/myrepo                                 │
│ $ git clone <skill-url> .claude/plugins/24hour-ClaudeCode │
│ $ bash /24hour-ClaudeCode:setup │
│   (installs skill + Actions + Superset config)     │
│ $ git push   # (already done by onboarder)         │
└────────────────────────────────────────────────────┘
                    │
                    │ User opens new workspace in Superset
                    ▼
┌────────────────────────────────────────────────────┐
│ Superset workspace #1 (worktree auto-created)      │
│ → setup hook runs .superset/setup.sh → ✓           │
│ → cheat sheet prints in terminal pane              │
│ → User edits code in Claude Code                   │
│ → PostToolUse hook fires → skill auto-engages      │
│ → PR open → Action review → auto-merge → MERGED    │
└────────────────────────────────────────────────────┘
                    │
                    │ Concurrently open workspace #2, #3...
                    ▼
┌────────────────────────────────────────────────────┐
│ Workspaces #2/#3 — independent worktrees           │
│ Don't interfere; share the same repo's Actions     │
└────────────────────────────────────────────────────┘
```

Subsequent repos: repeat from main-checkout step, once per repo.

---

## 7. Debugging hooks

When a hook fails:

```bash
# Read the setup output (visible in workspace terminal pane on creation)
# Look for ✗ ERROR or ⚠ WARN lines

# Manually re-run the setup hook (from the worktree):
./.superset/setup.sh

# Re-onboard if Actions config drifted:
cd "$SUPERSET_ROOT_PATH" && bash /24hour-ClaudeCode:setup
```

If teardown fails and the workspace can't be deleted, Superset offers **Force Delete** which skips teardown. Use this only when the teardown command itself is broken (not when there's a real lock or volume to clean).

---

## 8. Relationship to the 11-step PR flow

The Superset setup hook is **preparation**, not part of the PR flow:

| Superset phase | Role in skill |
|---|---|
| Setup (workspace creation) | Pre-flight verification — passing means the skill is ready to run |
| User edits code in Claude Code | The 11-step PR flow runs autonomously (auto-engaged by PostToolUse hook) |
| Teardown (workspace deletion) | After DoD — skill is done; teardown reminds user to clean the worktree from main |

---

## 9. Troubleshooting

| Symptom | Diagnosis |
|---|---|
| `zsh: no such file or directory: ./.superset/setup.sh` | The repo committed `.superset/config.json` without committing the hook scripts. From the main checkout, rerun `bash scripts/install-superset-config.sh --force`, then commit `.superset/setup.sh`, `.superset/run.sh`, and `.superset/teardown.sh` with the config. |
| Setup says `scripts/check-actions.sh` is missing | Plugin not installed at `.claude/plugins/24hour-ClaudeCode`, or the setup script points at the wrong plugin path. From repo root: `ls .claude/plugins/24hour-ClaudeCode/scripts/check-actions.sh` |
| Setup says `gh CLI not authenticated` | Workspace terminal inherits user's `~/.config/gh`, but if Superset runs in a container it may not. Run `gh auth login` in the workspace terminal |
| Teardown hangs | Some command in the hook is hanging. Use Force Delete |
| Superset can't find `.superset/config.json` | You're inside a worktree, not repo root — or `~/.superset/projects/<id>/config.json` is overriding it |
| Want to add a personal setup command (e.g. set private env) | Write `.superset/config.local.json` (auto-gitignored) |
