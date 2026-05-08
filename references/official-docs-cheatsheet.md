# 官方 docs 关键点速查(零基础踩坑率最高的 10 条)

> 摘录自 [anthropics/claude-code-action/docs](https://github.com/anthropics/claude-code-action/tree/main/docs)。
>
> 这些不是文档全文,是**最容易踩坑、零基础最容易卡住**的关键点。每条给"文档原话 + 我们的处理"。

---

## 1. OIDC `id-token: write` 是必需的

**官方原话**(faq.md):

> If you're using the default GitHub App authentication, you must add the `id-token: write` permission to your workflow:
> ```yaml
> permissions:
>   contents: read
>   id-token: write   # Required for OIDC authentication
> ```
> The OIDC token is required in order for the Claude GitHub app to function.

**我们的处理**:本 skill 提供的两个 workflow 模板(`templates/claude.yml` / `templates/claude-code-review.yml`)默认都设了 `id-token: write`。`scripts/check-actions.sh` 会校验缺失情况并报 WARN。

---

## 2. `github-actions` user 不能触发嵌套 workflow

**官方原话**(faq.md):

> The `github-actions` user cannot trigger subsequent GitHub Actions workflows. This is a GitHub security feature to prevent infinite loops. To make this work, you need to use a Personal Access Token (PAT) instead, which will act as a regular user.

**对本 skill 影响**:

- ❌ 你写一个 workflow,里面调 `gh pr create` → 这个新 PR 不会触发 `claude-code-review.yml`
- ❌ Action 里 push 了 commit → 新一轮 `pull_request: synchronize` 不会触发再 review

**变通**:

```yaml
# 在 workflow 里要触发链式 action 时,改用 PAT
- name: Push (triggering downstream workflows)
  run: gh pr create ...
  env:
    GH_TOKEN: ${{ secrets.MY_PAT_WITH_REPO_SCOPE }}
```

或:用 GitHub App token(`actions/create-github-app-token`)代替默认 GITHUB_TOKEN。

**实际频率**:本 skill 9 步流程里,**用户**手动 push 才能触发 review,不会撞上这个限制。但如果你扩展成"完全自动化"(`@claude` workflow 里又调 `gh pr create`),就会撞。

---

## 3. Claude **不能改** `.github/workflows/*` 文件

**官方原话**(faq.md):

> The GitHub App for Claude doesn't have workflow write access for security reasons. This prevents Claude from modifying CI/CD configurations that could potentially create unintended consequences.

**对本 skill 影响**:

- 用户在 PR 评论 `@claude 把 workflow 改一下加 paths-ignore` → Action 会失败,只留个 review 评论说"我没权限改 .github/workflows"
- 修 workflow 必须**人工**改

**变通**:

```yaml
# 给 workflow 写权限(需要 PAT 或 custom GitHub App)
- name: Generate App Token
  id: app-token
  uses: actions/create-github-app-token@v2
  with:
    app-id: ${{ secrets.APP_ID }}
    private-key: ${{ secrets.APP_PRIVATE_KEY }}
- uses: anthropics/claude-code-action@v1
  with:
    github_token: ${{ steps.app-token.outputs.token }}    # ← App 装的时候勾选了 workflow 权限
```

但**绝大多数情况下**这是 feature 不是 bug——不让 Action 改 CI 配置是好事。

---

## 4. 只 write-permission 用户能 trigger Claude

**官方原话**(faq.md):

> Only users with **write permissions** to the repository can trigger Claude. This is a security feature to prevent unauthorized use.

**对本 skill 影响**:

- 外部贡献者开 PR → 他自己评论 `@claude 帮我改 X` 不会触发(没有 write 权限)
- 维护者评论 `@claude` 才会触发

**变通**:用 `allowed_non_write_users` input 显式放行(**有安全风险,详见 anti-patterns.md H1**)。

---

## 5. Bash 工具默认全禁

**官方原话**(faq.md):

> The Bash tool is **disabled by default** for security. To enable individual bash commands using `claude_args`:
> ```yaml
> claude_args: |
>   --allowedTools "Bash(npm:*),Bash(git:*)"   # Allows only npm and git commands
> ```

**对本 skill 影响**:

- 没显式开 Bash → @claude 改完代码后**没法跑 typecheck / test 验证**就 commit
- 默认模板**已开 Bash**,但加了黑名单防爆炸:`--disallowed-tools "Bash(git push --force *),Bash(rm -rf *)"`

**怎么细粒度白名单**(更安全,但易漏命令):

```yaml
claude_args: |
  --allowedTools "Read,Write,Edit,Grep,Glob,Bash(pnpm:*),Bash(git status),Bash(git diff),Bash(git add *),Bash(git commit *)"
```

---

## 6. `403 Resource not accessible by integration`

**官方原话**(faq.md):

> This error occurs when the action tries to fetch the authenticated user information using a GitHub App installation token... **Solution**: The action now includes `bot_id` and `bot_name` inputs that default to Claude's bot credentials.

**对本 skill 影响**:Action v1 已默认处理(`bot_id: 41898282` / `bot_name: claude[bot]`),不用管。如果你看到 403 → 升级 action 到 `@v1`。

---

## 7. `--mcp-config` 加自定义 MCP server

**官方原话**(configuration.md):

> ```yaml
> claude_args: |
>   --mcp-config '{"mcpServers": {"sequential-thinking": {"command": "npx", "args": ["-y", "@modelcontextprotocol/server-sequential-thinking"]}}}'
>   --allowedTools mcp__sequential-thinking__sequentialthinking
> ```

**何时用**:让 @claude 能查你私有数据库 / 内部 API / 文档站。本 skill 默认模板**没**接 MCP,需要时按上面格式加。

⚠️ **Secret 注入**:MCP server 需要 API key 时,通过 `env:` 传:

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

**绝不**把 `secrets.MY_API_KEY` 写进 git 里的 `.mcp.json`,临时文件 + heredoc 才安全。

---

## 8. `settings:` input 注入 hooks 和 env

**官方原话**(configuration.md):

> ```yaml
> settings: |
>   {
>     "model": "claude-opus-4-1-20250805",
>     "env": {"DEBUG": "true"},
>     "permissions": {"allow": ["Bash", "Read"], "deny": ["WebFetch"]},
>     "hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "echo Running bash..."}]}]}
>   }
> ```

**何时用**:复杂配置(model + env + permissions + hooks)塞 `claude_args` 行不通,改用 `settings` JSON 或文件路径。

**简单配置**:用 `claude_args`(`--max-turns 5 --model claude-sonnet-4-6`)即可。

**官方建议**:"Use `claude_args` for simple configurations and `settings` for complex configurations with hooks and environment variables."

---

## 9. `enableAllProjectMcpServers` 默认 true

**官方原话**(configuration.md):

> The `enableAllProjectMcpServers` setting is always set to `true` by this action to ensure MCP servers work correctly.

**含义**:你 repo 根 `.mcp.json` 里声明的 MCP server,Action 会**自动启用**。无需在 workflow 里再列。

⚠️ **副作用**:`.mcp.json` 里别放敏感信息,会被 Action 加载执行。

---

## 10. Mode auto-detection(interactive vs automation)

**官方原话**(faq.md):

> The action intelligently detects whether to run in interactive mode or automation mode:
> - **With `prompt` input**: Runs in **automation mode** - executes immediately without waiting for @claude mentions
> - **Without `prompt` input**: Runs in **interactive mode** - waits for @claude mentions in comments

**对本 skill 影响**:

- `claude-code-review.yml` 传了 `prompt:` → **automation mode**,PR 一开自动跑
- `claude.yml` 没传 `prompt:` → **interactive mode**,等 `@claude` 触发

**别撞**:同一个 workflow 文件,既传 `prompt:` 又监听 `issue_comment` → 行为混乱(自动跑还是等触发?)。模板把这俩拆成两个文件就是这个原因。

---

## 索引到原文

| 主题 | 官方文档 |
|---|---|
| 配置(env / settings / MCP) | docs/configuration.md |
| FAQ(认证 / 触发 / 调试) | docs/faq.md |
| 安全(token / 权限 / 注入) | docs/security.md |
| 安装步骤 | docs/setup.md |
| 各种 use case 示例 | docs/usage.md |
| 云厂商(Bedrock / Vertex / Foundry) | docs/cloud-providers.md |
| 自定义自动化 | docs/custom-automations.md |
| 局限性 | docs/capabilities-and-limitations.md |
| 从 beta 升级 v1 | docs/migration-guide.md |
| 实战方案合集 | docs/solutions.md |

直接访问:<https://github.com/anthropics/claude-code-action/tree/main/docs>
