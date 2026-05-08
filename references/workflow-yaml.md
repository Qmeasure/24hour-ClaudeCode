# Claude Code Action Workflow YAML 全参数参考

> 本文档列出**所有可在 `.github/workflows/*.yml` 里配置的字段**。分 5 层组织,每个参数给:作用 / 默认值 / 何时用 / 坑点。
>
> 数据源:`anthropics/claude-code-action` 仓库的 `action.yml`(30 个 inputs)+ GitHub Actions 官方 workflow schema。
>
> 想快速找"达到 X 效果改哪里",直接跳到 [§F 反查表](#f-想达到-x-改哪里反查表)。

---

## A. GitHub Actions 框架字段

### A.1 `on:` 触发器

| 字段 | 默认 | 作用 / 坑点 |
|---|---|---|
| `pull_request` | — | PR 事件;**默认仅触发 `opened/synchronize/reopened`**;要触发 `ready_for_review`(从 draft 转正)必须显式列出 |
| `pull_request.types` | `[opened, synchronize, reopened]` | 子事件,常用 `opened/synchronize/ready_for_review/reopened/closed` |
| `pull_request.paths` | 全部 | 路径白名单,**至少一个文件命中**就触发 |
| `pull_request.paths-ignore` | 空 | 黑名单,**所有文件都命中**才忽略;和 `paths` 互斥(同时设以 `paths` 为准) |
| `pull_request.branches` | 全部 | 目标分支白名单(过滤 PR 要 merge 进哪个分支) |
| `pull_request.branches-ignore` | 空 | 反向 |
| `pull_request_target` | — | ⚠️ **危险**:以**目标分支**的 workflow 配置运行,且能读 secrets;给 fork PR 用会被攻击,默认别用 |
| `issue_comment` | — | 任何 issue / PR 的 conversation tab 评论 |
| `issue_comment.types` | `[created, edited, deleted]` | 通常只用 `created` |
| `pull_request_review_comment` | — | **行内** review 评论(diff 里点行号那种) |
| `pull_request_review` | — | 整个 review 提交(approve/request changes/comment 整体) |
| `issues` | — | issue 本体事件(`opened/edited/labeled/assigned/closed`) |
| `push` | — | 直接 push 到分支;一般不用,会和 PR 重复 |
| `schedule.cron` | — | 定时,UTC 时间,5 字段格式;最小粒度 5 分钟,但 GitHub 经常顺延几分钟 |
| `workflow_dispatch` | — | 手动按钮,可定义 `inputs:` 接收参数(`type: string/boolean/choice/environment`) |
| `workflow_run` | — | 别的 workflow 跑完后触发,常用于"CI 挂了自动修" |

### A.2 `concurrency:` 并发控制

```yaml
concurrency:
  group: claude-${{ github.event.pull_request.number || github.run_id }}
  cancel-in-progress: true   # 同一 PR 新 push 来了,取消上一个还在跑的 workflow
```

| 字段 | 作用 |
|---|---|
| `group` | 同 group 的 run 互斥;表达式决定粒度(常用按 PR 号) |
| `cancel-in-progress` | `true` = 取消旧的;`false` = 排队等 |

**不设的代价**:用户连 push 5 次,Claude 跑 5 遍,token 五倍。

### A.3 Job 级字段

| 字段 | 默认 | 作用 |
|---|---|---|
| `runs-on` | — | 必填;`ubuntu-latest`(免费 quota 最大,2000 min/月);`macos-latest` 单价 10 倍 |
| `if` | true | 表达式过滤,例:`github.actor != 'dependabot[bot]'` |
| `timeout-minutes` | 360(6 小时) | **强烈建议设 10–15**,Claude 跑飞了不至于烧爆 quota |
| `needs` | — | 依赖前置 job |
| `strategy.matrix` | — | 矩阵跑(同时 review 多个语言/路径) |
| `outputs` | — | 给后续 job 传值 |
| `env` | — | job 级环境变量 |

### A.4 `permissions:` Token 权限边界

每个 scope 三档:`read` / `write` / `none`。给少了 Claude 干不动,给多了爆炸面大。

| Scope | Claude 啥时候用 | 建议值 |
|---|---|---|
| `contents` | 读代码 / commit / push | review-only 用 `read`;允许 @claude 改代码用 `write` |
| `pull-requests` | 留 review 评论 / 改 PR 描述 / 标 label | `write` |
| `issues` | 评论 issue / 关闭 / 改 label | `write`(用 issue 触发时) |
| `actions` | 读 CI 日志,辅助修 CI 失败 | `read` |
| `checks` | 看 / 创建 check run | 一般不需要 |
| `id-token` | OIDC token,给 Bedrock/Vertex/Foundry | `write`(只有走云厂商时);走 OAuth 订阅也建议设,不然某些 plugin 报错 |
| `packages` | 读私有 package | 只在用到 GHCR 时 |
| `statuses` | 改 commit status | 一般不需要 |

### A.5 `actions/checkout` 步骤参数

| 字段 | 默认 | 作用 / 坑点 |
|---|---|---|
| `ref` | 当前事件 ref | 想 checkout 别的分支/tag/SHA 时用 |
| `fetch-depth` | `1` | 拉多少历史;**`0` = 全量历史**(blame/log 才需要) |
| `submodules` | `false` | 拉子模块,大仓库谨慎 |
| `lfs` | `false` | LFS 文件 |
| `token` | `GITHUB_TOKEN` | 用自定义 token(GitHub App 场景) |

⚠️ **`fetch-depth: 1` 时 `git log` 只有 1 条**,Claude 想看历史会失败,改 `0`。

---

## B. Claude Code Action 30 个 inputs

### B.1 触发与过滤(8 个)

| 参数 | 默认 | 作用 / 坑点 |
|---|---|---|
| `trigger_phrase` | `@claude` | 触发词,可改 `/ai`、`@bot` 等 |
| `assignee_trigger` | — | 把某人 assign 到 issue 触发(例:assign 给 `@claude` 这个虚拟用户名) |
| `label_trigger` | `claude` | 打这个 label 触发 |
| `track_progress` | `false` | 强制 tag 模式,留**实时更新的进度评论**;只对 `pull_request` / `issue` 事件生效 |
| `allowed_bots` | `""`(全禁) | 允许哪些 bot 触发;`*` 全允许;**公开仓库设 `*` 是高危**——别人的 App 能伪造 prompt 攻击你 |
| `allowed_non_write_users` | `""`(禁) | 让无写权限的人也能触发;**安全极敏感**,只用在受限 workflow |
| `include_comments_by_actor` | 全包含 | 白名单评论作者,支持通配符 `*[bot]`、`dependabot[bot]` |
| `exclude_comments_by_actor` | 不排除 | 黑名单;同时在黑白名单 → 黑名单优先 |

### B.2 认证(6 个,**互斥选一**)

| 参数 | 用于 |
|---|---|
| `anthropic_api_key` | 走 Anthropic 官方 API,从 console.anthropic.com 拿 key |
| `claude_code_oauth_token` | 走 Pro/Max 订阅,**`claude setup-token` 生成** |
| `use_bedrock: "true"` | AWS Bedrock,需 OIDC + IAM role |
| `use_vertex: "true"` | GCP Vertex AI,需 Workload Identity Federation |
| `use_foundry: "true"` | Microsoft Foundry,需 OIDC |
| `github_token` | 自定义 GitHub App 的 token(默认用 `GITHUB_TOKEN`) |

### B.3 行为指令(4 个,**最常改**)

| 参数 | 作用 |
|---|---|
| `prompt` | 直接给 Claude 的指令文本;不传则等 trigger phrase 时按评论内容跑 |
| `claude_args` | 透传给 Claude CLI 的 flag(见 [§C](#c-claude_args-cli-flags)) |
| `settings` | 内联 `settings.json`(JSON 字符串)或文件路径,可注入 hooks / MCP |
| `additional_permissions` | 给 Claude 额外的 GitHub 权限,目前主要是 `actions: read`(让它读 CI 日志) |

### B.4 分支与 commit(7 个)

| 参数 | 默认 | 作用 |
|---|---|---|
| `base_branch` | repo 默认分支 | Claude 创新分支时基于哪条 |
| `branch_prefix` | `claude/` | 新分支前缀;改 `claude-` 用 dash 风格 |
| `branch_name_template` | `{{prefix}}{{entityType}}-{{entityNumber}}-{{timestamp}}` | 自定义命名;占位符:`{{prefix}}/{{entityType}}/{{entityNumber}}/{{timestamp}}/{{sha}}/{{label}}/{{description}}` |
| `use_commit_signing` | `false` | 用 GitHub 的 commit signature verification(GPG 校验通过) |
| `ssh_signing_key` | — | SSH 签名私钥,优先级高于 `use_commit_signing` |
| `bot_id` | `41898282`(claude[bot]) | git commit 时的 user ID |
| `bot_name` | `claude[bot]` | git commit 时的 user name |

### B.5 评论行为(3 个)

| 参数 | 默认 | 作用 |
|---|---|---|
| `use_sticky_comment` | `false` | `true` = 同一 PR 始终更新**同一条**评论(防刷屏);`false` = 每次新评论 |
| `classify_inline_comments` | `true` | 行内评论先缓存,session 结束统一分类(过滤试探性评论)再发 |
| `include_fix_links` | `true` | review 里附"Fix this"链接,点开本机 Claude Code 直接修 |

### B.6 插件 / Skills(2 个)

| 参数 | 作用 |
|---|---|
| `plugin_marketplaces` | 换行分隔的 marketplace git URL,例:`https://github.com/anthropics/claude-code.git` |
| `plugins` | 换行分隔的 plugin 名,例:`code-review@claude-code-plugins` |

`/install-github-app` 默认生成的 `claude-code-review.yml` 就用了这俩,跑官方 `/code-review:code-review` skill。

### B.7 调试 / 输出(4 个)

| 参数 | 默认 | 作用 / 坑点 |
|---|---|---|
| `display_report` | `false` | 把 Claude 报告显示在 GitHub Step Summary;**仅用于受信输入**(不然可能渲染恶意内容) |
| `show_full_output` | `false` | 输出全量 JSON 含所有工具调用结果——**会暴露 secret**,只在 debug 时开 |
| `path_to_claude_code_executable` | — | 自定义 claude CLI 路径(高级:固定旧版本) |
| `path_to_bun_executable` | — | 自定义 Bun 路径 |

---

## C. `claude_args` CLI flags

| Flag | 默认 | 作用 |
|---|---|---|
| `--model` | `claude-sonnet-4-6` | 模型;可填 `claude-opus-4-7` / `claude-haiku-4-5-20251001` |
| `--max-turns` | `10` | agentic loop 最大轮数;**直接决定钱包**,见下方专题 |
| `--allowed-tools` | 默认全开 | 工具白名单,例 `"Bash(gh pr *),Read,Grep,Edit"`;细到子命令 |
| `--disallowed-tools` | 空 | 黑名单,例 `"Bash(rm *),Bash(git push --force *)"` |
| `--append-system-prompt` | — | 追加到 system prompt 末尾的额外指令 |
| `--mcp-config` | — | MCP server 配置文件路径,接外部数据源 |
| `--debug` | off | 详细日志(到 GitHub Actions log) |
| `--json-schema` | — | 让 Claude 按指定 schema 输出 JSON;可被 `outputs.structured_output` 消费 |
| `--resume <session-id>` | — | 继续之前中断的 session(配合 `outputs.session_id`) |

### `--max-turns` 选择参考表

| 场景 | 建议值 |
|---|---|
| 纯 review 只评论不改代码 | `3–5` |
| review + 小修复(typo / lint) | `8–10` |
| `@claude` 交互问答 | `5–8` |
| `@claude` 让它修 bug | `15–20` |
| `ci-failure-auto-fix.yml` 自动修复 | `20–30` |
| 大型 feature 实现 | `40–50`(谨慎,主要风险变成钱) |

**触发上限的失败模式**:Claude 中途被掐断,留下半成品 commit。报错:`Reached max turns (N), stopping.`

---

## D. Outputs(后续 step 可消费)

| Output | 作用 |
|---|---|
| `execution_file` | Claude 这次跑的完整记录文件路径 |
| `branch_name` | Claude 创建的分支名(如果创建了) |
| `github_token` | Claude App token,后续 step 复用 |
| `structured_output` | 用 `--json-schema` 时的结构化结果,`fromJSON(...)` 解析 |
| `session_id` | session ID,下次 `--resume` 用 |

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

## E. 隐式配置(不在 YAML 里,但影响行为)

| 位置 | 作用 |
|---|---|
| `CLAUDE.md`(repo 根) | 项目通用指令 / 风格 / 评审标准,Claude 自动读 |
| `.claude/settings.json` | 全局 Claude Code 设置,等价 `settings:` input |
| `.claude/skills/*` | 自定义 skill |
| `.claude/agents/*` | 自定义 sub-agent |
| GitHub Secrets | `secrets.XXX` 引用,**唯一**安全的存 token 位置 |

---

## F. "想达到 X 改哪里"反查表

| 想做的事 | 改哪里 |
|---|---|
| 只在 PR 改动 src/ 时跑 | `on.pull_request.paths: ["src/**"]` |
| README / 文档改动不跑 | `on.pull_request.paths-ignore: ["**.md"]` |
| 防止 dependabot 触发 | `jobs.<id>.if: github.actor != 'dependabot[bot]'` |
| PR 连续 push 只跑最后一次 | `concurrency.cancel-in-progress: true` |
| 限制成本 | `claude_args: --max-turns 3 --model claude-sonnet-4-6` |
| 不让 Claude 跑 git push | `claude_args: --disallowed-tools "Bash(git push *)"` |
| 触发词改成 `/ai` | `trigger_phrase: "/ai"` |
| 项目通用规则 | repo 根放 `CLAUDE.md` |
| 单次任务的特殊指令 | `prompt:` |
| 接入私有 API / 数据库 | `claude_args: --mcp-config /path/to/mcp.json` |
| 只对外部贡献者 review | `if: github.event.pull_request.author_association == 'FIRST_TIME_CONTRIBUTOR'` |
| 用企业 Bedrock/Vertex | `use_bedrock: "true"` + OIDC |
| 防止 review 评论刷屏 | `use_sticky_comment: true` |
| 让 @claude 能看 CI 日志 | `additional_permissions: actions: read` + `permissions.actions: read` |
| 不让 Action 自己创建分支 | `claude_args: --disallowed-tools "Bash(git checkout -b *),Bash(git branch *)"` |
| 限制 review 关注点(如只看安全) | `prompt: "Only review for security issues..."` |
| Action 跑挂自动告警 | `if: failure()` 后续 step 调用 Slack/邮件 webhook |

---

## G. 常见组合配方

### G.1 最小成本 review

```yaml
claude_args: |
  --max-turns 3
  --model claude-sonnet-4-6
permissions:
  contents: read
  pull-requests: write
timeout-minutes: 8
```

### G.2 只看变更涉及的代码,跳过文档

```yaml
on:
  pull_request:
    paths-ignore:
      - "**.md"
      - "**/CHANGELOG*"
      - "docs/**"
```

### G.3 让 @claude 能修代码 + commit

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

### G.4 给安全敏感仓库的最严配置

```yaml
permissions:
  contents: read
  pull-requests: write
allowed_bots: ""              # 不允许任何 bot 触发
allowed_non_write_users: ""   # 只允许有写权限的人触发
claude_args: |
  --max-turns 5
  --disallowed-tools "WebFetch,WebSearch,Bash(curl *),Bash(wget *)"
```

---

## H. 配置生效顺序速查

请求到达时,Claude Code Action 按这个顺序解析配置:

1. workflow YAML 顶部 `on:` 决定能否触发
2. `if:` 条件决定 job 跑不跑
3. `permissions:` 决定 GITHUB_TOKEN 的 scope
4. action 的 `with:` 参数注入 → 触发词、过滤、认证
5. `actions/checkout` 拉代码到 runner
6. `claude_args` 传到底层 CLI(`--model` / `--max-turns` / `--allowed-tools`)
7. Claude 启动后读 `CLAUDE.md` + `.claude/` 目录配置
8. `prompt:` 作为 user message 注入
9. agentic loop 跑(每轮 = 思考 + 工具调用 + 观察),受 `--max-turns` 限制
10. 结束 → outputs 写到 `$GITHUB_OUTPUT`,可被后续 step 消费

理解这个顺序,debug 时就知道往哪一层查。
