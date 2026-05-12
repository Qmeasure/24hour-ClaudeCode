**English** | [中文](README.zh-CN.md)

# 24hour-ClaudeCode

**A magic helper that ships your code for you. You write the change; it does everything else.**

You're using Claude Code in a project. You ask it to fix a bug or add a feature. Normally, after the code is written you still have to:

- Run tests
- Make a commit with a good message
- Push to GitHub
- Open a Pull Request
- Wait for the review bot to look at it
- Respond to feedback (and probably do another round of fixes)
- Click "merge" when everything's green

This plugin does **all of that** for you, automatically. **You write code; it ships the PR.**

---

## How it feels in practice

Here's the recommended way to ship one feature:

> **You:** `/goal Add CSV export to the reports page.`
>
> *(Claude edits, verifies, and keeps working until the goal is met.)*
>
> **Claude:** "Goal complete. I opened PR #142 and am waiting for CI and review."
>
> *(Two minutes later)*
>
> **Claude:** "✅ PR #142 merged: github.com/your-org/your-repo/pull/142"

If something goes wrong, the loop catches it:

> **Claude:** "The auto-review found a bug — the new `/export` endpoint forgot to handle empty datasets (line 48). Fixing now."
>
> *(Claude fixes it. CI re-runs. Passes.)*
>
> **Claude:** "✅ PR #142 merged."

You never typed `git commit`, `gh pr create`, or clicked "merge". The plugin handled all of it.

---

## When to use this plugin

✅ **Good fit:**
- You're working on a real GitHub project
- You want Claude Code to ship features end-to-end without you nudging it
- You're OK letting the worktree automation commit, push, open PRs, and enable auto-merge after the Goal is ready

❌ **Not a good fit (for now):**
- You're doing exploratory work and don't want auto-commits yet
- Your project doesn't use GitHub
- You're working on highly sensitive code (passwords, infrastructure config) — the plugin refuses to touch those by default, but you may want full manual control

---

## Quick start

The flow is **3 steps**: once per machine, once per repo, once per feature. After that, every feature you ship is one `git worktree add` away from a fully automated PR.

```
Step 1 (once per machine)  → install plugin   ─┐  in any terminal
                                               │
Step 2 (once per repo)     → onboard           │  in your project's MAIN folder
                              ↓                │  (the original git checkout)
                              setup wizard     │  on the main branch
                                               │
Step 3 (per feature)       → open a worktree   │  in a NEW folder next to your project
                              code → auto PR  ─┘  (sibling dir)
```

### Before you start — make sure you have these

| Thing | How to check | If missing |
|---|---|---|
| Claude Code CLI installed | `claude --version` | Install from [code.claude.com/docs](https://code.claude.com/docs/) |
| GitHub CLI installed + logged in | `gh auth status` | `gh auth login --scopes workflow` |
| Git identity configured | `git config --global user.name` | `git config --global user.name "..."` + `user.email` |
| **A folder for your project** | You know its full path, e.g. `~/Projects/my-app` | Pick or create one before continuing |
| **Either an existing GitHub repo, OR ready to make a new one** | `gh repo view` works inside the folder | The setup wizard will offer to create it for you |

### Step 1 — Install the plugin (one-time, global, run anywhere)

You can be in any terminal, any folder. The plugin installs into your home dir and applies to every project on this machine.

```bash
# In any terminal:
gh auth login --scopes workflow         # make sure gh has workflow scope
claude plugin marketplace add Qmeasure/24hour-ClaudeCode
claude plugin install 24hour-ClaudeCode@24hour-ClaudeCode
```

Confirm: `claude plugin list` should show `24hour-ClaudeCode@24hour-ClaudeCode` as `enabled`.

After install, **restart Claude Code** (`/exit` then `claude` again) so the plugin's hooks load.

> Plugin code lives at `~/.claude/plugins/...`. You install it once, not per-project.

### Step 2 — Onboard your repo (once per repo, **in your project's main folder**)

> 📍 **Where to run this:** open a terminal *inside your project's main folder* — the original folder where your `.git` directory lives. Not a worktree, not somewhere else.
>
> Example:
> ```bash
> cd ~/Projects/my-app    # ← your actual project path
> pwd                     # confirm you're in the right place
> ls .git                 # this should exist (or you'll create it via the wizard)
> ```

> ⚠️ **Why "main folder" matters:** the setup commits `.github/workflows/claude*.yml` to your repo. GitHub Actions can only authorize them when they're on the **default branch**, so they must land on `main` first. If you run setup from a worktree, the plugin will tell you to switch back to the main folder.

Make sure you're on the main branch (or whichever branch is your repo's default):

```bash
git checkout main         # or: git checkout master / git checkout default branch name
```

Then open a Claude Code session in this folder and run the setup command:

```bash
claude
```

```
/24hour-ClaudeCode:setup
```

The wizard does the rest. **Every step asks for confirmation; nothing happens without your OK.** The flow:

1. **Verify prerequisites** — `git`, `gh`, `claude` CLIs installed, gh has `workflow` scope, git identity configured.
2. **Locate your repo** — three sub-cases:
   - ✅ You already have a GitHub repo connected → continues automatically.
   - ⚠️ Local git repo but **no GitHub remote** → wizard offers to run `gh repo create` for you (it'll ask name / public-or-private / push). Pick "yes" to create + push in one go.
   - ⚠️ Folder isn't even a git repo yet → wizard offers `git init -b main` + initial commit. You'll need files to commit (a README is enough).
3. **Verify the Claude review bot is installed** — auto-detects via the `check_suites` side-channel (no clicks needed if the App is already installed account-wide, which is the common case). If not detected, the wizard prints the install URL and waits for you to add it.
4. **Set the `CLAUDE_CODE_OAUTH_TOKEN` secret** — the wizard *cannot* run this automatically (both `claude setup-token` and `gh secret set` are interactive — browser OAuth + paste). Instead it **prints the exact 2 CLI commands** for you to run in your terminal, then re-verifies. The exact commands the wizard gives you:
   ```bash
   # in your terminal — DO NOT paste the token into chat
   claude setup-token                                              # OAuth → prints sk-ant-oat01-...
   gh secret set CLAUDE_CODE_OAUTH_TOKEN -R <owner>/<repo>          # paste at prompt
   ```
   Then press Enter back in the wizard; it confirms via `gh api repos/<repo>/actions/secrets/CLAUDE_CODE_OAUTH_TOKEN` (200=set, 404=missing).
5. **Auto-detect** your test / lint / build commands.
6. **Ask** which AI reviews PRs: Claude / OpenAI Codex / both.
7. **Generate workflow YAMLs** tailored to your stack → commit + push to `main`.
8. **Seed** `.claude/24hour-ClaudeCode.config.json` (your local knobs).
9. **Health check** — confirms all wiring.

After the wizard finishes, **do one thing on the GitHub website**: open your repo → Settings → General → ☑️ **Allow auto-merge**. Without this, PRs won't merge automatically after CI passes.

✅ **One-time only.** This repo is done. Every worktree you create from this repo inherits the config automatically — you never re-run setup.

### Step 3 — Ship a feature (per feature, in a worktree **next to** your project)

> 📍 **Where to run this:** still in your project's main folder for the `worktree add` command. The new worktree will be created as a **sibling folder**, then you `cd` into it and start a fresh Claude session.

```bash
# Still in ~/Projects/my-app (your main folder):
git worktree add ../my-feature -b feat/my-feature
#                ↑ creates ~/Projects/my-feature, on a new branch

cd ../my-feature      # move into the worktree folder
claude                # ← start a NEW Claude session here (don't reuse the one from main)
```

> 🔑 **Critical:** you must start a **new** Claude Code session inside the worktree folder. SessionStart hooks only fire once per session, so the runtime only activates when Claude starts up in the worktree dir. (If you `cd` into the worktree from an existing session, the runtime won't engage.)

When Claude opens in `../my-feature`, the plugin auto-detects:
- ✓ inside a worktree
- ✓ main is onboarded (config inherited automatically)
- → **runtime is now ACTIVE in this worktree**. No setup needed.

Tell Claude what to do. **Recommended:** use Claude Code `/goal` mode so the plugin waits until the goal is actually complete before it opens a PR:

```text
/goal Add CSV export to the reports page.
```

Non-Goal prompts still work for small, single-turn changes, but Goal mode is safer for feature work because it blocks PR creation during intermediate turns.

The plugin takes over:

- When the Goal is ready, or when a non-Goal turn ends with a real diff, the Stop hook runs the auto-commit pipeline (commit → push → PR)
- The PR gets reviewed automatically (Claude or Codex, whichever you chose)
- If review or CI fails, the plugin shows Claude the feedback and Claude fixes it — up to 5 retry rounds
- When everything is green, the plugin enables auto-merge and waits for the PR to merge
- Done. From "add CSV export to reports" to "PR merged" — no `git` typing, no clicking "merge".

When the PR merges, optionally clean up:

```bash
cd ~/Projects/my-app                  # back to main folder
git pull                              # pull the merged commit
git worktree remove ../my-feature     # delete the worktree
```

> **Why a worktree?** Each worktree is a separate folder for a separate branch. The plugin **only activates inside worktrees**, so your main folder stays untouched — you can keep using Claude Code normally there for manual edits, exploration, or read-only work, and nothing will be auto-committed.

---

## FAQ — common questions

**Will it commit things I don't want committed?**
No. It only commits files you actually changed in this session. Sensitive paths like `migrations/`, `.env.production`, `infra/`, and `**/secrets/**` are blocked by default — the plugin refuses to auto-commit those and asks you for explicit approval first.

**What if the review keeps failing?**
After 5 fix-and-retry rounds it stops automatically and tells you what's wrong. You take over from there.

**What if I want to make a manual edit and not have it auto-committed?**
Two options:
- Run `/24hour-ClaudeCode:disable` to pause the plugin → make your manual edit → `/24hour-ClaudeCode:enable` when done.
- Or do your edits in the main checkout (not a worktree). The plugin only activates inside worktrees.

**Will it touch my main branch?**
No. It refuses to push to `main`, `master`, `develop`, `staging`, etc. You have to be on a feature branch.

**How do I see what it's doing right now?**
Run `/24hour-ClaudeCode:status` — it shows the current PR, how many fix rounds happened, and any warnings.

**The auto-review is too strict / too loose. Can I tune it?**
Yes. The review prompt is **inline in the workflow YAML** itself. Edit the `prompt:` block in `.github/workflows/claude-code-review.yml` (and/or `codex-review.yml`), commit, push. Changes apply to the next PR — no re-setup needed. The prompt is auto-tailored to your repo's actual structure (top-level dirs, entry files, danger paths, repo summary) at render time.

**How do I update to the latest version?**
```bash
claude plugin marketplace update 24hour-ClaudeCode        # refresh marketplace metadata from GitHub
claude plugin update 24hour-ClaudeCode@24hour-ClaudeCode  # install the new version
```
After updating, **restart Claude Code** (`/exit` then `claude` again) so the new hooks load. Check the installed version any time with `claude plugin list`. The workflow YAMLs in your project's `.github/workflows/` are *not* touched by a plugin update — re-run `/24hour-ClaudeCode:setup` if you want to regenerate them.

**How do I uninstall it?**
```
/plugin uninstall 24hour-ClaudeCode
```
This removes the plugin. The workflow files in `.github/workflows/` and your API token in GitHub Secrets stay in place — delete those manually if you want a complete cleanup.

---

## Troubleshooting

| Symptom | What to do |
|---|---|
| "It seems stuck" | Run `/24hour-ClaudeCode:status`. If something's stuck longer than 2 min, try `/24hour-ClaudeCode:clear-lock` |
| "It can't push my code" | Check `gh auth status`. Re-authenticate if needed. |
| "It said the loop hit a limit" | The plugin tried 5 times and couldn't make CI/review happy. Read its message and fix manually. |
| "Reviews aren't happening" | Make sure GitHub's "Claude" app is installed on your repo and `CLAUDE_CODE_OAUTH_TOKEN` is set as a secret. Run `/24hour-ClaudeCode:setup` again. |
| "I want to start fresh" | `/24hour-ClaudeCode:setup` is safe to re-run — it won't break existing config |

---

## Customization (optional)

After setup, your project has these knob files:

```
your-project/
├── .claude/24hour-ClaudeCode.config.json              ← main settings
└── .github/workflows/claude-code-review.yml           ← review prompt (in the prompt: block)
└── .github/workflows/codex-review.yml (if codex)      ← review prompt for Codex
```

The most common changes:

| What you want | How |
|---|---|
| Focus reviews on something specific (e.g., security only) | Edit the `prompt:` block in `.github/workflows/claude-code-review.yml` |
| Allow more retry rounds before giving up | Change `repair.max_iterations` in the config file (default 5) |
| Add a path that should NEVER be auto-committed | Add a glob to the `danger_paths` array in the config file |
| Skip running tests before each commit (faster but riskier) | Set `checks.run_local_tests: false` in the config file |

---

## Slash commands

These are escape hatches — you don't normally need them.

| Command | What it does |
|---|---|
| `/24hour-ClaudeCode:setup` | (Re)run the setup wizard |
| `/24hour-ClaudeCode:status` | Show what's happening right now |
| `/24hour-ClaudeCode:retry` | Force-restart the auto-PR loop after a hiccup |
| `/24hour-ClaudeCode:disable` | Pause the plugin for this project |
| `/24hour-ClaudeCode:enable` | Resume after pausing |
| `/24hour-ClaudeCode:clear-lock` | Last resort: unstick a stuck loop |

---

## What you need to have

Before installing:

- A Claude Pro or Max subscription
- A GitHub account
- The GitHub CLI installed (`gh`) and signed in
- Git version 2.20 or newer (for worktree support)

That's it. No Node.js, Python, or other languages required.

---

## Curious how it actually works?

The plugin uses Claude Code's **hook** system — small scripts that run automatically at specific moments (when a session starts, after Claude makes an edit, when Claude finishes a turn).

If you want to understand the architecture under the hood — which hooks fire when, how the loop iterates, how the runtime state machine works — see **[FLOW.md](FLOW.md)** ([中文版](FLOW.zh-CN.md)).

---

## License

MIT
