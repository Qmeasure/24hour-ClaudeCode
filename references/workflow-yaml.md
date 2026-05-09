# Claude Code Action workflow YAML — full parameter reference

This document lists **every field configurable in `.github/workflows/*.yml`** for Claude Code Action. Organized in 5 layers; each parameter shows: purpose / default / when to use / pitfalls.

Source: `anthropics/claude-code-action`'s `action.yml` (30 inputs) + GitHub Actions workflow schema.

For "I want effect X — what do I change?" jump to [§F Reverse lookup](#f-reverse-lookup-i-want-x).

---

## A. GitHub Actions framework fields

### A.1 `on:` triggers

| Field | Default | Purpose / pitfall |
|---|---|---|
| `pull_request` | — | PR events; **default fires only on `opened/synchronize/reopened`**; for `ready_for_review` (draft → ready), list explicitly |
| `pull_request.types` | `[opened, synchronize, reopened]` | Sub-events: `opened/synchronize/ready_for_review/reopened/closed` |
| `pull_request.paths` | all | Path allowlist; **at least one matching file** triggers |
| `pull_request.paths-ignore` | empty | Blocklist; **all files must match** to skip; mutually exclusive with `paths` (when both set, `paths` wins) |
| `pull_request.branches` | all | Target-branch allowlist (which base branch the PR targets) |
| `pull_request.branches-ignore` | empty | Reverse |
| `pull_request_target` | — | ⚠️ **Dangerous**: runs with the **target branch's** workflow config and full secrets; vulnerable to fork-PR attacks; avoid by default |
| `issue_comment` | — | Any issue / PR conversation comment |
| `issue_comment.types` | `[created, edited, deleted]` | Usually only `created` |
| `pull_request_review_comment` | — | **Inline** review comments (clicking a line in the diff) |
| `pull_request_review` | — | Whole review submissions (approve/request changes/comment summary) |
| `issues` | — | Issue body events (`opened/edited/labeled/assigned/closed`) |
| `push` | — | Direct push to a branch; rarely useful, overlaps with PR triggers |
| `schedule.cron` | — | Cron, UTC, 5-field format; minimum granularity 5 min, GitHub may delay several min |
| `workflow_dispatch` | — | Manual button; can declare `inputs:` (`type: string/boolean/choice/environment`) |
| `workflow_run` | — | Triggered by another workflow finishing; commonly "auto-fix CI failures" |

### A.2 `concurrency:`

```yaml
concurrency:
  group: claude-${{ github.event.pull_request.number || github.run_id }}
  cancel-in-progress: true   # new push on same PR cancels the in-progress run
```

| Field | Purpose |
|---|---|
| `group` | Runs in the same group are mutually exclusive; expression chooses granularity (commonly per-PR) |
| `cancel-in-progress` | `true` = cancel old; `false` = queue |

**Cost of not setting:** push 5 times in a row, Claude runs 5 times, 5× tokens.

### A.3 Job-level fields

| Field | Default | Purpose |
|---|---|---|
| `runs-on` | — | Required; `ubuntu-latest` (cheapest, 2000 free min/month); `macos-latest` is 10× the cost |
| `if` | true | Expression filter, e.g. `github.actor != 'dependabot[bot]'` |
| `timeout-minutes` | 360 (6h) | **Strongly recommended: 10–15**, so a runaway Action doesn't burn quota for hours |
| `needs` | — | Depend on another job |
| `strategy.matrix` | — | Matrix runs (parallel review of multiple langs/paths) |
| `outputs` | — | Pass values to subsequent jobs |
| `env` | — | Job-level env vars |

### A.4 `permissions:` token scope

Each scope has 3 levels: `read` / `write` / `none`. Too little = Claude blocked; too much = wide blast radius.

| Scope | When Claude needs it | Recommended |
|---|---|---|
| `contents` | Read code / commit / push | review-only: `read`; allow `@claude` to commit: `write` |
| `pull-requests` | Post review comments / edit PR description / labels | `write` |
| `issues` | Comment on / close / label issues | `write` (when issue events trigger) |
| `actions` | Read CI logs to help fix failures | `read` |
| `checks` | Read / create check runs | Usually unnecessary |
| `id-token` | OIDC token for Bedrock / Vertex / Foundry | `write` (cloud-vendor auth); also recommended for OAuth subscription auth (some plugins error otherwise) |
| `packages` | Read private packages | Only when GHCR is involved |
| `statuses` | Modify commit status | Usually unnecessary |

### A.5 `actions/checkout` step parameters

| Field | Default | Purpose / pitfall |
|---|---|---|
| `ref` | event ref | Checkout a different branch/tag/SHA |
| `fetch-depth` | `1` | History depth; **`0` = full history** (needed for blame/log) |
| `submodules` | `false` | Pull submodules (heavy on big repos) |
| `lfs` | `false` | LFS files |
| `token` | `GITHUB_TOKEN` | Use a custom token (GitHub App scenario) |

⚠️ **`fetch-depth: 1` means `git log` only sees 1 commit.** If Claude wants history, change to `0`.

---

## B. Claude Code Action — 30 inputs

### B.1 Triggering & filtering (8)

| Input | Default | Purpose / pitfall |
|---|---|---|
| `trigger_phrase` | `@claude` | Trigger phrase; can change to `/ai`, `@bot`, etc. |
| `assignee_trigger` | — | Trigger when someone is assigned to the issue (e.g. assign to virtual user `@claude`) |
| `label_trigger` | `claude` | Adding this label triggers |
| `track_progress` | `false` | Force tag mode, post a **live-updating progress comment**; only on `pull_request` / `issue` events |
| `allowed_bots` | `""` (none) | Which bots may trigger; `*` = all; **setting `*` on public repos is high-risk** — others' Apps could craft prompt-injection attacks |
| `allowed_non_write_users` | `""` (none) | Allow non-write users to trigger; **security-critical**, only in restricted workflows |
| `include_comments_by_actor` | all | Allowlist comment authors, supports wildcards `*[bot]`, `dependabot[bot]` |
| `exclude_comments_by_actor` | none | Blocklist; on conflict, blocklist wins |

### B.2 Authentication (6, **mutually exclusive**)

| Input | Use |
|---|---|
| `anthropic_api_key` | Anthropic console API; key from console.anthropic.com |
| `claude_code_oauth_token` | Pro/Max subscription; **generated via `claude setup-token`** |
| `use_bedrock: "true"` | AWS Bedrock; needs OIDC + IAM role |
| `use_vertex: "true"` | GCP Vertex AI; needs Workload Identity Federation |
| `use_foundry: "true"` | Microsoft Foundry; needs OIDC |
| `github_token` | Custom GitHub App token (default uses `GITHUB_TOKEN`) |

### B.3 Behavior (4, **most-edited**)

| Input | Purpose |
|---|---|
| `prompt` | Direct instruction text for Claude; if omitted, Claude reads the trigger comment |
| `claude_args` | Pass-through CLI flags (see [§C](#c-claude_args-cli-flags)) |
| `settings` | Inline `settings.json` (JSON string) or file path; can inject hooks / MCP |
| `additional_permissions` | Extra GitHub permissions; commonly `actions: read` (read CI logs) |

### B.4 Branch & commit (7)

| Input | Default | Purpose |
|---|---|---|
| `base_branch` | repo default | Base for new branches Claude creates |
| `branch_prefix` | `claude/` | New-branch prefix; change to `claude-` for dash style |
| `branch_name_template` | `{{prefix}}{{entityType}}-{{entityNumber}}-{{timestamp}}` | Custom naming; placeholders: `{{prefix}}/{{entityType}}/{{entityNumber}}/{{timestamp}}/{{sha}}/{{label}}/{{description}}` |
| `use_commit_signing` | `false` | Sign commits with GitHub's signature verification (GPG passes) |
| `ssh_signing_key` | — | SSH signing key; takes priority over `use_commit_signing` |
| `bot_id` | `41898282` (claude[bot]) | git commit user ID |
| `bot_name` | `claude[bot]` | git commit user name |

### B.5 Comment behavior (3)

| Input | Default | Purpose |
|---|---|---|
| `use_sticky_comment` | `false` | `true` = update **the same** PR comment each round (anti-spam); `false` = new comment each time |
| `classify_inline_comments` | `true` | Buffer inline comments; classify and post all at session end (filters tentative comments) |
| `include_fix_links` | `true` | Add "Fix this" links to reviews; clicking opens local Claude Code to apply |

### B.6 Plugins / Skills (2)

| Input | Purpose |
|---|---|
| `plugin_marketplaces` | Newline-separated marketplace git URLs, e.g. `https://github.com/anthropics/claude-code.git` |
| `plugins` | Newline-separated plugin names, e.g. `code-review@claude-code-plugins` |

The default `claude-code-review.yml` from `/install-github-app` uses both, running the official `/code-review:code-review` skill.

### B.7 Debug / output (4)

| Input | Default | Purpose / pitfall |
|---|---|---|
| `display_report` | `false` | Show Claude's report in GitHub Step Summary; **only with trusted input** (could render malicious content otherwise) |
| `show_full_output` | `false` | Output full JSON including tool-call results — **may leak secrets**, debug only |
| `path_to_claude_code_executable` | — | Custom claude CLI path (advanced: pin old version) |
| `path_to_bun_executable` | — | Custom Bun path |

---

## C. `claude_args` CLI flags

| Flag | Default | Purpose |
|---|---|---|
| `--model` | `claude-sonnet-4-6` | Model: `claude-opus-4-7` / `claude-haiku-4-5-20251001` etc. |
| `--max-turns` | `10` | Max agentic loop turns; **directly drives spend**, see below |
| `--allowed-tools` | all | Tool allowlist, e.g. `"Bash(gh pr *),Read,Grep,Edit"`; supports sub-commands |
| `--disallowed-tools` | empty | Blocklist, e.g. `"Bash(rm *),Bash(git push --force *)"` |
| `--append-system-prompt` | — | Extra instructions appended to system prompt |
| `--mcp-config` | — | MCP server config file path |
| `--debug` | off | Verbose log (in GitHub Actions log) |
| `--json-schema` | — | Constrain Claude to a JSON schema; consumable via `outputs.structured_output` |
| `--resume <session-id>` | — | Resume a previous session (paired with `outputs.session_id`) |

### `--max-turns` selection table

| Scenario | Recommended |
|---|---|
| Pure review, comment only | `3–5` |
| Review + small fix (typo / lint) | `8–10` |
| `@claude` Q&A | `5–8` |
| `@claude` bug fix | `15–20` |
| `ci-failure-auto-fix.yml` auto-recover | `20–30` |
| Large feature implementation | `40–50` (cautious — risk shifts to wallet) |

**Failure mode at the cap:** Claude is cut off mid-task, leaving a half-done commit. Error: `Reached max turns (N), stopping.`

---

## D. Outputs (consumable by later steps)

| Output | Purpose |
|---|---|
| `execution_file` | Full execution record file path |
| `branch_name` | Branch Claude created (if any) |
| `github_token` | Claude App token, reusable in later steps |
| `structured_output` | Structured result when `--json-schema` is set; parse via `fromJSON(...)` |
| `session_id` | Session ID, for next-run `--resume` |

```yaml
- uses: anthropics/claude-code-action@v1
  id: claude
  with: ...

- name: Use the output
  run: |
    echo "Branch: ${{ steps.claude.outputs.branch_name }}"
    echo "Risk: ${{ fromJSON(steps.claude.outputs.structured_output).risk_level }}"
```

---

## E. Implicit configuration (not in YAML, still affects behavior)

| Location | Purpose |
|---|---|
| `CLAUDE.md` (repo root) | Project-wide instructions / style / review standards; auto-loaded by Claude |
| `.claude/settings.json` | Global Claude Code settings; equivalent to the `settings:` input |
| `.claude/skills/*` | Custom skills |
| `.claude/agents/*` | Custom sub-agents |
| GitHub Secrets | `secrets.XXX` references; **the only** safe place to store tokens |

---

## F. Reverse lookup — "I want X"

| What you want | Where to change |
|---|---|
| Only run when `src/` changes | `on.pull_request.paths: ["src/**"]` |
| Skip README / doc changes | `on.pull_request.paths-ignore: ["**.md"]` |
| Don't run on dependabot PRs | `jobs.<id>.if: github.actor != 'dependabot[bot]'` |
| Cancel old runs on new push | `concurrency.cancel-in-progress: true` |
| Limit cost | `claude_args: --max-turns 3 --model claude-sonnet-4-6` |
| Block Claude from `git push` | `claude_args: --disallowed-tools "Bash(git push *)"` |
| Change trigger to `/ai` | `trigger_phrase: "/ai"` |
| Project-wide rules | `CLAUDE.md` at repo root |
| Per-task instructions | `prompt:` |
| Connect to private API / DB | `claude_args: --mcp-config /path/to/mcp.json` |
| Review only external contributors | `if: github.event.pull_request.author_association == 'FIRST_TIME_CONTRIBUTOR'` |
| Use enterprise Bedrock/Vertex | `use_bedrock: "true"` + OIDC |
| Prevent comment spam | `use_sticky_comment: true` |
| Let `@claude` read CI logs | `additional_permissions: actions: read` + `permissions.actions: read` |
| Block Action from creating branches | `claude_args: --disallowed-tools "Bash(git checkout -b *),Bash(git branch *)"` |
| Restrict review focus (e.g. security only) | `prompt: "Only review for security issues..."` |
| Auto-alert on Action failure | `if: failure()` step calling Slack/email webhook |

---

## G. Common configurations

### G.1 Minimum-cost review

```yaml
claude_args: |
  --max-turns 3
  --model claude-sonnet-4-6
permissions:
  contents: read
  pull-requests: write
timeout-minutes: 8
```

### G.2 Skip docs, review only code changes

```yaml
on:
  pull_request:
    paths-ignore:
      - "**.md"
      - "**/CHANGELOG*"
      - "docs/**"
```

### G.3 Allow `@claude` to fix code + commit

```yaml
permissions:
  contents: write
  pull-requests: write
  issues: write
  actions: read
claude_args: |
  --max-turns 15
  --disallowed-tools "Bash(git push --force *),Bash(rm -rf *)"
```

### G.4 Strictest config for a security-sensitive repo

```yaml
permissions:
  contents: read
  pull-requests: write
allowed_bots: ""              # no bot triggers
allowed_non_write_users: ""   # only write-permission users trigger
claude_args: |
  --max-turns 5
  --disallowed-tools "WebFetch,WebSearch,Bash(curl *),Bash(wget *)"
```

---

## H. Configuration resolution order

When a request arrives, Claude Code Action processes config in this order:

1. Workflow YAML `on:` decides whether it triggers
2. `if:` expression decides whether the job runs
3. `permissions:` decides GITHUB_TOKEN scope
4. Action's `with:` injects → trigger phrase, filters, auth
5. `actions/checkout` pulls code into the runner
6. `claude_args` passes to the underlying CLI (`--model` / `--max-turns` / `--allowed-tools`)
7. Claude starts, reads `CLAUDE.md` + `.claude/` directory config
8. `prompt:` injected as user message
9. Agentic loop runs (per turn = think + tool call + observe), bounded by `--max-turns`
10. End → outputs written to `$GITHUB_OUTPUT`, consumable by later steps

When debugging, knowing this order tells you which layer to inspect.
