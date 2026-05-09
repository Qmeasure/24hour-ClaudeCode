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

## Quick start (about 10 minutes, only once per project)

You only do this once for each project. After setup, the plugin works automatically forever.

### Step 1 — Install the plugin

In Claude Code, type:

```
/plugin marketplace add Qmeasure/24hour-ClaudeCode
/plugin install 24hour-ClaudeCode@24hour-ClaudeCode-marketplace
```

> **What's a plugin?** Think of it as an "app" for Claude Code. Once installed, it adds new behavior to Claude. This one adds the auto-PR superpower.

### Step 2 — Run the setup wizard

```
/24hour-ClaudeCode:setup
```

The wizard does the rest. It will:

1. Check that the basic tools (`git`, `gh`, `claude`) are installed and signed in
2. Open GitHub in your browser to install the Claude review bot on your repo
3. Generate an API token from your Claude subscription and save it as a GitHub secret (this is what lets the auto-review bot run)
4. Read your project to detect what test/lint commands you use
5. Ask: "Which AI should review your PRs? Claude / OpenAI Codex / both?"
6. Generate the right config files for your project type
7. Show you the plan before pushing — you confirm before anything goes live

The wizard explains every step in plain English. **Nothing happens without your OK.**

### Step 3 — Start working

Open a worktree for your task:

```bash
git worktree add ../my-feature -b feat/my-feature
cd ../my-feature
claude
```

Now ask Claude to do something. The plugin takes over from there.

> **What's a worktree?** It's a way to have multiple "checkouts" of the same project at the same time. Each worktree is a separate folder with its own branch.
>
> The plugin **only activates inside worktrees**, so you can keep using Claude Code normally in your main folder without any of this firing.

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
