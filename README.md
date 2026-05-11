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

Here's what shipping one feature looks like:

> **You:** "Add CSV export to the reports page."
>
> *(Claude edits 3 files. You say "looks good".)*
>
> **Claude:** "✅ I committed your changes, opened PR #142, and CI is running. I'll check back in a moment."
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
- You're OK letting an automated process commit and push your code (it asks before any push; nothing happens secretly)

❌ **Not a good fit (for now):**
- You're doing exploratory work and don't want auto-commits yet
- Your project doesn't use GitHub
- You're working on highly sensitive code (passwords, infrastructure config) — the plugin refuses to touch those by default, but you may want full manual control

---

## Quick start

The flow is **3 steps**, done once per machine + once per repo. After that, every feature you ship is one `git worktree add` away from a fully automated PR.

```
Step 1 (once per machine)  → install plugin  ─┐
                                              │
Step 2 (once per repo)     → onboard ON MAIN  │  ← config lives on main
                                              │     workflow YAMLs need
Step 3 (per feature)       → open a worktree  │     to be on default branch
                              code → auto PR ─┘
```

### Step 1 — Install the plugin (one-time, global)

```bash
# Make sure gh CLI has workflow scope (required to push .github/workflows/*.yml later)
gh auth login --scopes workflow

# Install the plugin once — it auto-applies to every repo on this machine
claude plugin marketplace add Qmeasure/24hour-ClaudeCode
claude plugin install 24hour-ClaudeCode@24hour-ClaudeCode
```

Confirm: `claude plugin list` should show `24hour-ClaudeCode@24hour-ClaudeCode` as `enabled`.

After install, **restart Claude Code** (`/exit` then `claude` again) so the plugin's hooks load.

> **Why "global"?** Plugin code installs to `~/.claude/plugins/...`, but it activates per-project automatically. You don't reinstall for each new repo.

### Step 2 — Onboard your repo (once per repo, **on the main branch**)

> ⚠️ **Run setup from the main checkout, not from a worktree.** Setup commits workflow YAMLs (`.github/workflows/claude*.yml`) — GitHub Actions can only authorize them when they're on the **default branch**, so they must land on main first. If you try to run setup inside a worktree, the plugin will tell you to switch.

```bash
cd ~/your-repo
git checkout main            # be on main, not a feature branch
claude                       # open Claude Code session
```

When the session opens, the plugin auto-detects that onboarding is incomplete and prompts you. Run:

```
/24hour-ClaudeCode:setup
```

The wizard does the rest. Each step asks for confirmation; **nothing happens without your OK**:

1. Verify `git`, `gh`, `claude` CLIs are installed and signed in (with `workflow` scope)
2. Open GitHub in your browser → you install the Claude review bot on this repo
3. Generate an OAuth token from your Claude subscription → save it as the `CLAUDE_CODE_OAUTH_TOKEN` GitHub secret
4. Read your project to detect test / lint / build commands
5. Ask: "Which AI should review your PRs? Claude / OpenAI Codex / both?"
6. Generate workflow YAMLs tailored to your stack → **commit + push to main**
7. Seed `.claude/24hour-ClaudeCode.config.json` (your local knobs)
8. Run a health check to confirm everything is wired

**Then one manual step on GitHub:** Settings → General → ☑️ **Allow auto-merge** (or pull requests won't auto-merge after CI passes).

✅ Once done, this repo never needs setup again — every worktree you create from now on inherits the config automatically.

### Step 3 — Ship a feature (per feature, in a worktree)

```bash
git worktree add ../my-feature -b feat/my-feature
cd ../my-feature
claude
```

The plugin auto-detects: ✓ in worktree, ✓ main is onboarded → **runtime is now ACTIVE in this worktree**. No setup needed.

Tell Claude what to do. The plugin takes over:

- Every code edit triggers an auto-commit pipeline (commit → push → draft PR)
- The PR gets reviewed automatically (Claude or Codex, whichever you chose)
- If the review or CI fails, the plugin shows Claude the specific feedback and Claude fixes it — up to 5 retry rounds
- When everything is green, the plugin enables auto-merge and waits for the PR to merge
- Done. The whole cycle from your "add CSV export to reports" to "PR merged" runs without you typing `git` or clicking "merge".

> **Why a worktree?** It's a separate folder for each branch, so the plugin only ever auto-commits in dedicated feature dirs — your main checkout stays clean and manual. The plugin **only activates inside worktrees**; it's silent in your main folder.

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
Yes. Edit `.claude/24hour-ClaudeCode/review-prompt.md` in your project. That's a plain English file telling the review bot what to focus on. Changes apply to the next PR; no re-setup needed.

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
├── .claude/24hour-ClaudeCode.config.json     ← main settings
└── .claude/24hour-ClaudeCode/review-prompt.md ← what the review bot looks for
```

The most common changes:

| What you want | How |
|---|---|
| Focus reviews on something specific (e.g., security only) | Edit `.claude/24hour-ClaudeCode/review-prompt.md` |
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
