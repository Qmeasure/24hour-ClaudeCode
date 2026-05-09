# Official docs cheatsheet — the 10 things that bite beginners hardest

Excerpts from [anthropics/claude-code-action/docs](https://github.com/anthropics/claude-code-action/tree/main/docs).

These aren't full doc transcripts — they're the **highest-incidence pitfall points** for new users. Each entry has the official quote + how this skill handles it.

---

## 1. OIDC `id-token: write` is required

**Official (faq.md):**

> If you're using the default GitHub App authentication, you must add the `id-token: write` permission to your workflow:
> ```yaml
> permissions:
>   contents: read
>   id-token: write   # Required for OIDC authentication
> ```
> The OIDC token is required in order for the Claude GitHub app to function.

**This skill:** both rendered workflow templates set `id-token: write` by default. `scripts/check-actions.sh` flags missing instances as WARN.

---

## 2. The `github-actions` user can't trigger nested workflows

**Official (faq.md):**

> The `github-actions` user cannot trigger subsequent GitHub Actions workflows. This is a GitHub security feature to prevent infinite loops. To make this work, you need to use a Personal Access Token (PAT) instead, which will act as a regular user.

**Implications:**

- ❌ A workflow calling `gh pr create` won't trigger `claude-code-review.yml` on the new PR
- ❌ When the Action pushes a commit, the resulting `pull_request: synchronize` won't re-fire review

**Workarounds:**

```yaml
# Use a PAT to chain into downstream workflows
- name: Push (triggering downstream workflows)
  run: gh pr create ...
  env:
    GH_TOKEN: ${{ secrets.MY_PAT_WITH_REPO_SCOPE }}
```

Or use a GitHub App token (`actions/create-github-app-token`) instead of the default `GITHUB_TOKEN`.

**Frequency in this skill:** the 11-step flow has the **user** doing the manual push, so this limitation never bites. It would bite if you extended into "fully automated" (`@claude` workflow that itself calls `gh pr create`).

---

## 3. Claude **cannot edit** `.github/workflows/*` files

**Official (faq.md):**

> The GitHub App for Claude doesn't have workflow write access for security reasons. This prevents Claude from modifying CI/CD configurations that could potentially create unintended consequences.

**Implications:**

- A `@claude please update the workflow to add paths-ignore` comment will fail; the Action just leaves a "no permission" comment
- Workflow edits must be **manual**

**Workaround:**

```yaml
- name: Generate App Token
  id: app-token
  uses: actions/create-github-app-token@v2
  with:
    app-id: ${{ secrets.APP_ID }}
    private-key: ${{ secrets.APP_PRIVATE_KEY }}
- uses: anthropics/claude-code-action@v1
  with:
    github_token: ${{ steps.app-token.outputs.token }}    # the App must have workflow scope
```

But **mostly this is a feature, not a bug** — preventing the Action from editing CI config is a safety win.

---

## 4. Only write-permission users can trigger Claude

**Official (faq.md):**

> Only users with **write permissions** to the repository can trigger Claude. This is a security feature to prevent unauthorized use.

**Implications:**

- An external contributor opens a PR and comments `@claude help with X` — won't trigger (no write perm)
- A maintainer commenting `@claude` will trigger

**Workaround:** `allowed_non_write_users` input explicitly opens this up — **security-sensitive**, see anti-patterns.md H1.

---

## 5. Bash tool is disabled by default

**Official (faq.md):**

> The Bash tool is **disabled by default** for security. To enable individual bash commands using `claude_args`:
> ```yaml
> claude_args: |
>   --allowedTools "Bash(npm:*),Bash(git:*)"   # Allows only npm and git commands
> ```

**Implications:**

- Without explicit Bash enable, `@claude` can't run `typecheck` / `test` to verify before committing
- This skill's default templates **enable Bash** but use a blocklist to prevent disasters: `--disallowed-tools "Bash(git push --force *),Bash(rm -rf *)"`

**Granular allowlist version** (safer but easy to miss commands):

```yaml
claude_args: |
  --allowedTools "Read,Write,Edit,Grep,Glob,Bash(pnpm:*),Bash(git status),Bash(git diff),Bash(git add *),Bash(git commit *)"
```

---

## 6. `403 Resource not accessible by integration`

**Official (faq.md):**

> This error occurs when the action tries to fetch the authenticated user information using a GitHub App installation token... **Solution**: The action now includes `bot_id` and `bot_name` inputs that default to Claude's bot credentials.

**This skill:** Action v1 handles this (`bot_id: 41898282` / `bot_name: claude[bot]`); nothing to do. If you see 403 → upgrade the Action ref to `@v1`.

---

## 7. `--mcp-config` for custom MCP servers

**Official (configuration.md):**

> ```yaml
> claude_args: |
>   --mcp-config '{"mcpServers": {"sequential-thinking": {"command": "npx", "args": ["-y", "@modelcontextprotocol/server-sequential-thinking"]}}}'
>   --allowedTools mcp__sequential-thinking__sequentialthinking
> ```

**When to use:** let `@claude` reach private DBs, internal APIs, doc sites. This skill's default templates **don't** include MCP — add when needed.

⚠️ **Secret injection:** when MCP servers need API keys, pass via `env:`:

```yaml
- name: Create MCP Config
  run: |
    cat > /tmp/mcp.json << EOF
    {"mcpServers": {"my-api": {"command": "npx", "args": ["..."],
      "env": {"API_KEY": "${{ secrets.MY_API_KEY }}"}}}}
    EOF
- uses: anthropics/claude-code-action@v1
  with:
    claude_args: --mcp-config /tmp/mcp.json
```

**Never** commit `secrets.MY_API_KEY` into a `.mcp.json` in git. Heredoc to a temp file is the safe pattern.

---

## 8. `settings:` input injects hooks and env

**Official (configuration.md):**

> ```yaml
> settings: |
>   {
>     "model": "claude-opus-4-1-20250805",
>     "env": {"DEBUG": "true"},
>     "permissions": {"allow": ["Bash", "Read"], "deny": ["WebFetch"]},
>     "hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "echo Running bash..."}]}]}
>   }
> ```

**When to use:** complex configuration (model + env + permissions + hooks) is impractical via `claude_args`; use `settings` (JSON or file path).

**Simple configuration:** stay on `claude_args` (`--max-turns 5 --model claude-sonnet-4-6`).

**Official guidance:** "Use `claude_args` for simple configurations and `settings` for complex configurations with hooks and environment variables."

---

## 9. `enableAllProjectMcpServers` is always true

**Official (configuration.md):**

> The `enableAllProjectMcpServers` setting is always set to `true` by this action to ensure MCP servers work correctly.

**Meaning:** any MCP server declared in your repo's `.mcp.json` will be auto-enabled by the Action. No need to list them in the workflow again.

⚠️ **Side effect:** don't put sensitive info in `.mcp.json`; the Action will load it.

---

## 10. Mode auto-detection (interactive vs. automation)

**Official (faq.md):**

> The action intelligently detects whether to run in interactive mode or automation mode:
> - **With `prompt` input**: Runs in **automation mode** — executes immediately without waiting for @claude mentions
> - **Without `prompt` input**: Runs in **interactive mode** — waits for @claude mentions in comments

**This skill:**

- `claude-code-review.yml` passes `prompt:` → **automation mode**, fires on PR open
- `claude.yml` omits `prompt:` → **interactive mode**, waits for `@claude` mention

**Don't mix:** in the same workflow file, both passing `prompt:` AND listening on `issue_comment` produces undefined behavior (auto-run or wait?). The split-file template avoids this.

---

## Index back to upstream

| Topic | Official doc |
|---|---|
| Config (env / settings / MCP) | docs/configuration.md |
| FAQ (auth / triggers / debug) | docs/faq.md |
| Security (tokens / perms / injection) | docs/security.md |
| Setup steps | docs/setup.md |
| Use case examples | docs/usage.md |
| Cloud vendors (Bedrock / Vertex / Foundry) | docs/cloud-providers.md |
| Custom automations | docs/custom-automations.md |
| Capabilities & limits | docs/capabilities-and-limitations.md |
| Beta → v1 migration | docs/migration-guide.md |
| Real-world solutions | docs/solutions.md |

Direct: <https://github.com/anthropics/claude-code-action/tree/main/docs>
