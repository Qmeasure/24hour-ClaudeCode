# Claude Code Actions 零基础首次配置

> 这份指南面向**从未在仓库里部署过 Claude Code Actions** 的开发者。完成后:
> - PR 自动 review(每次开 PR / push 自动触发)
> - `@claude` 在 PR 评论中提问 / 委托修复
>
> 用 **Claude Pro/Max 订阅**做认证(走 OAuth token,无需 Anthropic API Key)。

---

## 🚀 Quick path:一键配置(推荐)

仓库 root 跑这一行,完成 Step 1–6 全部交互式步骤:

```bash
bash scripts/configure-actions.sh
```

会引导你:
1. 检查 gh CLI / claude CLI / git 装好且登录
2. 打开浏览器装 Claude GitHub App
3. 跑 `claude setup-token` 生成 OAuth token,自动 `gh secret set` 设进去
4. 把 `templates/claude.yml` + `templates/claude-code-review.yml` 复制到 `.github/workflows/`
5. commit + push
6. 跑 `check-actions.sh` 自检健康

完成后回到 [SKILL.md](SKILL.md) 跑 9 步 PR 流程。

**用 Superset 多 worktree**:还要顺便跑 `bash scripts/install-superset-config.sh` 注入 `.superset/config.json`,让每次开新 workspace 自动校验配置。详见 [references/superset-integration.md](references/superset-integration.md)。

---

## 🛠️ 手动 path:6 个步骤逐个走(脚本失败 / 想完全掌控时用)

完成时间:10–15 分钟。

完成后再进入 [SKILL.md](SKILL.md) 的 9 步 PR 流程。

---

## 0. 前置检查

| 项 | 命令 / 验证方式 |
|---|---|
| 已有 GitHub 仓库 | `gh repo view` 不报错 |
| 仓库已 push 至少 1 个 commit | `git log -1` 有输出 |
| 本机装了 `gh` CLI 并登录,且 token 含 `workflow` scope | `gh auth status` 显示 `workflow` scope |
| 本机装了 Claude Code 并登录订阅账号 | `claude --version` 不报错 |
| 你拥有仓库 admin 权限(才能装 GitHub App + 设 secret) | `gh api repos/<owner>/<repo>/collaborators/<your-login>/permission --jq '.permission'` 返回 `admin` |

如有缺项:

- **`gh` 没装**:`brew install gh`(macOS) / 看 [cli.github.com](https://cli.github.com)
- **`workflow` scope 缺**:`gh auth refresh -h github.com -s workflow`
- **Claude Code 没登录**:`claude` 启动后按提示登录

---

## 1. 安装 Claude GitHub App

浏览器打开 → **<https://github.com/apps/claude>**

- 点 **Install**(显示 Configure 表示已装,跳到第 2 步)
- 选你的账号 / 组织
- 选 **Only select repositories** → 勾选目标仓库
- 默认权限不变(Contents / Issues / Pull requests:Read & Write),Install

**为什么要装 App**:
- workflow 跑时需要 GitHub App 的安装 token 来发 review 评论 / commit 修复
- 不装的话 Action 还能跑,但能力受限(用 `GITHUB_TOKEN` 的兜底权限,且评论以 `github-actions[bot]` 名义发)

**验证**:仓库 → Settings → GitHub Apps → 应该看到 Claude 已装。

---

## 2. 生成 OAuth Token

```bash
claude setup-token
```

会:
1. 弹浏览器走 OAuth 授权(用你的 Claude 订阅账号登录)
2. 完成后**终端打印一串 token**(很长,以 `sk-ant-oat01-` 开头)

**立刻复制这串 token**(下一步要用)。

⚠️ **安全红线**:
- ❌ **绝对不要**把 token 贴在聊天里、commit message、issue 描述、Slack/邮件里
- ❌ **绝对不要**写进任何 `.env` 文件 commit 上去
- ✅ **唯一**安全去处:GitHub Secrets(下一步会做)

---

## 3. 设置 GitHub Secret

```bash
gh secret set CLAUDE_CODE_OAUTH_TOKEN -R <owner>/<repo>
```

- 命令会提示 `? Paste your secret` → **粘贴上一步的 token,回车**
- 看到 `✓ Set secret CLAUDE_CODE_OAUTH_TOKEN` 表示成功

**验证**:

```bash
gh secret list -R <owner>/<repo>
# 应该看到一行:CLAUDE_CODE_OAUTH_TOKEN  <时间戳>
```

---

## 4. 写自定义 Workflow YAML

> 不用 `/install-github-app` 自动生成。**自己写**有两个好处:
> 1. 完全掌控参数(权限、超时、模型、`--max-turns` 等)
> 2. 不会和将来的官方默认模板版本冲突

需要两个文件,放 `.github/workflows/` 下。每个字段的含义见 [references/workflow-yaml.md](references/workflow-yaml.md)。

### 4.1 决策点(写之前先想清)

| 决策 | 选项 | 推荐 |
|---|---|---|
| review 模式 | A) 用官方 plugin(简单,持续维护)<br>B) 自定义 prompt(完全可控) | **A**,有特殊需求再 B |
| 权限边界 | read-only(只评论)<br>write(允许 @claude commit 修复) | review-only `read`<br>交互 job `write` |
| 模型 | `claude-sonnet-4-6`(便宜,日常)<br>`claude-opus-4-7`(深度,复杂 PR)<br>`claude-haiku-4-5-20251001`(快/便宜) | **Sonnet** 起步 |
| `--max-turns` | review:3–5<br>@claude 修代码:15–20 | review `5`<br>@claude `15` |
| paths 过滤 | 全跑 / 只代码不文档 | `paths-ignore: ["**.md"]` 起步 |
| concurrency | 取消旧的 / 排队 | `cancel-in-progress: true` |

### 4.2 创建 `claude-code-review.yml`(自动 review,模式 A 推荐)

```bash
mkdir -p .github/workflows
```

把下面内容存为 `.github/workflows/claude-code-review.yml`:

```yaml
name: Claude Code Review

on:
  pull_request:
    types: [opened, synchronize, reopened, ready_for_review]
    paths-ignore:                    # ← 按需调:不想 review 的文件
      - "**.md"
      - "**/CHANGELOG*"
      - "**/*.lock"

concurrency:
  group: claude-review-${{ github.event.pull_request.number }}
  cancel-in-progress: true

jobs:
  review:
    runs-on: ubuntu-latest
    timeout-minutes: 10              # ← 兜底熔断,跑飞自动停
    permissions:
      contents: read                 # review-only,不改代码
      pull-requests: write           # 留 review 评论
      issues: read
      id-token: write
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 1

      - uses: anthropics/claude-code-action@v1
        with:
          claude_code_oauth_token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
          # 用官方 code-review skill(质量好,持续维护)
          plugin_marketplaces: 'https://github.com/anthropics/claude-code.git'
          plugins: 'code-review@claude-code-plugins'
          prompt: '/code-review:code-review ${{ github.repository }}/pull/${{ github.event.pull_request.number }}'
          claude_args: |
            --max-turns 5
            --model claude-sonnet-4-6
          use_sticky_comment: true   # 同一 PR 多次 review 更新同一条评论
```

**模式 B(自定义 prompt)**:把 `plugin_marketplaces` / `plugins` 删掉,把 `prompt` 改成自己的指令,例:

```yaml
          prompt: |
            Review this PR. Focus on:
            - Correctness, logic bugs
            - Security (injection, secrets, auth)
            - Edge cases and error handling
            - Code quality (readability, naming)
            Skip trivial style nits. Be concise. Cite file:line for issues.
```

### 4.3 创建 `claude.yml`(@claude 交互 + 修代码)

把下面内容存为 `.github/workflows/claude.yml`:

```yaml
name: Claude Code

on:
  issue_comment:
    types: [created]
  pull_request_review_comment:
    types: [created]
  pull_request_review:
    types: [submitted]
  issues:
    types: [opened, assigned]

concurrency:
  group: claude-${{ github.event.issue.number || github.run_id }}
  cancel-in-progress: true

jobs:
  claude:
    if: |
      (github.event_name == 'issue_comment' && contains(github.event.comment.body, '@claude')) ||
      (github.event_name == 'pull_request_review_comment' && contains(github.event.comment.body, '@claude')) ||
      (github.event_name == 'pull_request_review' && contains(github.event.review.body, '@claude')) ||
      (github.event_name == 'issues' && (contains(github.event.issue.body, '@claude') || contains(github.event.issue.title, '@claude')))
    runs-on: ubuntu-latest
    timeout-minutes: 15
    permissions:
      contents: write                # ← 允许 @claude commit 修复
      pull-requests: write
      issues: write
      actions: read                  # 读 CI 结果
      id-token: write
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0             # 全量历史(允许 @claude 看 git log/blame)

      - uses: anthropics/claude-code-action@v1
        with:
          claude_code_oauth_token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
          additional_permissions: |
            actions: read
          claude_args: |
            --max-turns 15
            --model claude-sonnet-4-6
            --disallowed-tools "Bash(git push --force *),Bash(rm -rf *)"
```

### 4.4 push 上去

```bash
git add .github/workflows/claude-code-review.yml .github/workflows/claude.yml
git commit -m "Add Claude Code Actions workflows"
git push
```

---

## 5. 验证

### 5.1 开测试 PR

```bash
git checkout -b test-claude-actions
echo "" >> README.md
echo "<!-- testing claude code actions -->" >> README.md
git add README.md
git commit -m "test: trigger claude review"
git push -u origin test-claude-actions
gh pr create --fill
```

### 5.2 看 Actions 跑

```bash
# 查看 workflow 运行
gh run list -L 5

# 查看具体 run 日志(替换 <RUN_ID>)
gh run view <RUN_ID>
```

期望看到:
- `Claude Code Review` workflow 触发,30s–2min 跑完
- PR 页面出现 Claude 的 review 评论(sticky)

### 5.3 测试 @claude 交互

在 PR 评论里贴:

```
@claude 这个 PR 改了什么?
```

期望:30s–2min 内,Claude 在 PR 评论回复你。

### 5.4 测试 @claude 改代码

在 PR 评论里贴:

```
@claude 在 README 末尾加一行 "Verified by Claude Code Action."
```

期望:Claude 在 PR 分支上 commit & push 这一行,你刷新 PR 能看到新的 commit。

### 5.5 清理测试 PR

```bash
gh pr close <PR_NUMBER> --delete-branch
```

---

## 6. 常见问题

### Q: workflow 跑了但 step 失败,日志含 `401 Unauthorized`

OAuth token 失效或没配对。重做:

```bash
claude setup-token              # 生成新 token
gh secret set CLAUDE_CODE_OAUTH_TOKEN -R <owner>/<repo>  # 粘贴新 token 覆盖旧的
```

### Q: workflow 完全没触发(`gh run list` 空)

检查:
- workflow YAML 有没有语法错:`gh workflow view claude-code-review.yml`
- App 有没有装到当前 repo:`https://github.com/apps/claude` → Configure → 看 repo 列表
- 触发条件:`paths-ignore` 是否把所有变更文件都排除了
- token 上传时 secret 名字必须**完全是** `CLAUDE_CODE_OAUTH_TOKEN`(大小写敏感)

### Q: review 评论说"我没权限改文件"

`claude.yml` 的 `permissions:` 设了 `contents: read`,改成 `write` 即可(参考上面 4.3 模板)。

### Q: 跑一次烧好多 token / quota

调:
- `--max-turns` 调小(review 用 3,@claude 修代码用 10)
- `--model claude-sonnet-4-6` 比 Opus 便宜 5x
- `--disallowed-tools "WebFetch,WebSearch"` 禁联网,联网消耗大
- `concurrency.cancel-in-progress: true` 防止 push 风暴重复跑
- `timeout-minutes: 10` 兜底熔断
- `paths-ignore` 跳过文档 / lockfile

### Q: 我有第三方 review agent(Codex / Copilot)还想保留

完全兼容。`reviewers` 字段会同时含 `claude[bot]` 和其他 agent。流程不变,只是 review 来源是合并集。

### Q: 触发器配错重复触发了

如果 `claude-code-review.yml` 和 `claude.yml` 都监听了 `pull_request`,每个 PR 会跑两遍。**正确**:

- `claude-code-review.yml` 只接 `pull_request`
- `claude.yml` 只接 comment 类事件(`issue_comment` / `pull_request_review_comment` / 等)

按本指南的模板 4.2 / 4.3 不会撞。

### Q: 我能用 API Key 而不是订阅 OAuth 吗?

可以。把 `claude_code_oauth_token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}` 改为:

```yaml
anthropic_api_key: ${{ secrets.ANTHROPIC_API_KEY }}
```

并 `gh secret set ANTHROPIC_API_KEY` 设进去(从 console.anthropic.com 拿 key)。**优点**:跑 Action 不消耗你订阅日 quota。**缺点**:按 token 计费,自己充值。

---

## 配置完了下一步

→ [SKILL.md](SKILL.md) — 9 步 PR 流程(从写代码到 state=MERGED)

→ [references/workflow-yaml.md](references/workflow-yaml.md) — 30+ 参数全参考(深度调优)
