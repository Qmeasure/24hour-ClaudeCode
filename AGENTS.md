# Repository Guidelines

## Project Structure & Module Organization

This repository contains the `24hour-ClaudeCode` Claude Code plugin. Core runtime logic lives in `scripts/` and `hooks/`: scripts handle detection, workflow rendering, GitHub checks, locking, commits, and PR state; hooks wire that logic into Claude Code lifecycle events. Slash-command docs are in `commands/`, reusable agent workflows are in `skills/`, starter files are in `templates/`, and design references are in `references/`. User-facing docs are `README*.md` and `FLOW*.md`.

## Build, Test, and Development Commands

- `bash scripts/render-workflows.sh --dry-run`: render workflow YAML to stdout without modifying files.
- `bash scripts/render-workflows.sh --show-vars`: inspect detected project context used by workflow templates.
- `bash scripts/check-actions.sh -v`: verify GitHub Actions, secrets, and review wiring for an onboarded repo.
- `bash scripts/install-superset-config.sh --verify`: check Superset integration files when touching Superset templates.
- `bash -n scripts/*.sh hooks/*.sh`: run shell syntax validation before committing.

There is no package manager build step in this repo; changes are mostly shell, Markdown, JSON, and YAML.

## Coding Style & Naming Conventions

Shell scripts use Bash with defensive defaults such as `set -euo pipefail` where appropriate. Prefer small helper functions, explicit errors, quoted variable expansions, and existing helpers over duplicated logic. Keep script names lowercase and hyphenated, for example `check-actions.sh` or `runtime-state.sh`. Markdown should use clear headings, short steps, and copyable command blocks.

## Testing Guidelines

No formal unit test framework is present. For script changes, run `bash -n` on modified shell files plus a targeted dry run or verification command. For workflow template changes, run `bash scripts/render-workflows.sh --dry-run` and inspect generated YAML. For GitHub integration changes, use `bash scripts/check-actions.sh -v` in an onboarded test repository.

## Commit & Pull Request Guidelines

Recent history uses Conventional Commit-style messages, especially `chore:` and `fix(scope): ...` such as `chore: bump version to 1.0.14` and `fix(stop): docs/lock/trivial-only PRs short-circuit straight to auto-merge`. Keep commits focused and mention the changed runtime area when useful. Pull requests should include a concise behavior summary, verification commands run, linked issue if applicable, and screenshots only when rendered documentation or UI-like output changed.

## Security & Configuration Tips

Never commit tokens or local secrets. GitHub secrets such as `CLAUDE_CODE_OAUTH_TOKEN` must be configured through `gh secret set`, not stored in repo files. Treat `.claude/24hour-ClaudeCode.config.json` and generated workflow YAML as contract surfaces; preserve backward compatibility unless the change intentionally migrates users.
