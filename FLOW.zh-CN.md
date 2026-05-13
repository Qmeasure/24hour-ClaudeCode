# 24hour-ClaudeCode Flow

这是 skill-first review loop 的架构事实来源。

## 摘要

```text
SessionStart hook = 注入正确 skill context
Stop prompt hook = 把当前 session 路由回 review-loop
review-loop skill = 完整 PR/review/fix/merge workflow
github-actions-onboarding skill = 完整 repo onboarding workflow
当前 Claude Code session = fixer
GitHub Claude Code Action = reviewer
script = 只做确定性机械工具
```

Stop hook 不是 workflow engine。它是 prompt-based router: Claude 看起来准备在实现后停止时,它阻止停止并给出很短的 `review-loop` skill trigger。

## 借鉴 Superpowers 的原则

1. **Hook 负责路由,skill 执行 workflow。** Hook 可以注入上下文或用 skill trigger 阻止停止;Hook 不承载长事务。
2. **Skill 承载行为和判断。** PR review、rework、CI triage、停止、merge、onboarding 都属于 `review-loop` 或 `github-actions-onboarding`。
3. **Script 只做机械确定性任务。** Script 必须输入输出明确、可重复、可用 exit code 表达失败;不能 commit、push、wait review、解析 loop 状态或 merge。
4. **Goal mode 用官方能力。** Claude Code `/goal` 本身就是内置的 session-scoped prompt-based Stop hook。不要用项目脚本二次实现 Goal state。
5. **当前 session 修复。** 同一个 Claude Code session、同一个 WorkTree 负责处理 feedback;不要启动另一个 Claude CLI、daemon 或后台修复者。
6. **GitHub Action 只做 reviewer。** GitHub Claude Code Action 是审核者,不是修复者。
7. **description 写触发条件,正文写流程。** Skill frontmatter 的 `description` 只说明什么时候用;详细 workflow 写在 skill body。

## Hook 表

| Hook | Handler | 作用 |
|---|---|---|
| `SessionStart` | `command: hooks/bootstrap.sh` | 探测环境,注入 `github-actions-onboarding` 或 `using-24hour-ClaudeCode` context。官方 `SessionStart` 不支持 prompt hook。 |
| `Stop` | `hooks/hooks.json` 里的 `prompt` | 判断 Claude 是否可以停止;或阻止停止并输出 `REVIEW_LOOP_CONTINUE`,让当前 session 使用 `review-loop`。 |
| `review-loop` skill active 时的 `Stop` | `skills/review-loop/SKILL.md` 里的 `prompt` | 防止 active review loop 在 PR 已合并、auto-merge 已开启、存在明确 blocker 或用户明确停止之前中途停止。 |

没有 `UserPromptSubmit` Goal hook,没有 `PostToolUse` dirty marker,没有 async monitor,也没有 Stop-hook shell workflow。

## Runtime 文件

每个用户 repo 里:

```text
.claude/24hour-ClaudeCode.config.json
```

Plugin 不再创建本地 loop-state markdown 文件。运行时事实来自当前 Claude session、git、当前 PR 和绑定 current-SHA 的 GitHub review surfaces。

## Goal Mode

使用 Claude Code 原生 `/goal <condition>`。官方 hooks 文档说明 `/goal` 是内置的 session-scoped prompt-based Stop hook。本 plugin 不再创建第二套 Goal guard 或 marker。

当原生 `/goal` 仍未完成时,让内置 Goal Stop hook 继续驱动 Claude。等 `/goal` 允许回合停止后,24hour-ClaudeCode 的 Stop prompt 才可以把 session 路由到 `review-loop`。

## Review Loop Skill

Stop 输出 `REVIEW_LOOP_CONTINUE` 后,Claude 必须使用 `skills/review-loop/SKILL.md`。

Skill 工作流:

1. 确认当前 checkout 是 feature worktree,不是主 checkout 或受保护分支。
2. 运行 `git fetch origin --prune`,确认当前分支包含最新 `origin/<default-branch>`。
3. 检查本地变更和配置的 `danger_paths`。
4. 必要时运行本地 checks。
5. commit 当前变更。
6. push 当前分支。
7. 创建、更新并 ready PR。
8. 在当前上下文绑定 `CURRENT_HEAD_SHA=$(git rev-parse HEAD)`。
9. 等待 `headSha` 等于 `CURRENT_HEAD_SHA` 的 GitHub Claude Code Action review run 完成。
10. 读取真实 GitHub review surfaces。
11. 在同一个 WorkTree 修 blocking/important feedback。
12. 在同一个 skill 内分类 required external CI failure。
13. 重复直到 pass、blocked 或 merged。
14. 可靠 pass 后启用 auto-merge 或 merge。

当前 Claude Code session 是唯一 fixer。GitHub Action 只做 reviewer。

## Review Evidence 规则

不要假设存在自定义 verdict artifact。

有效证据可以来自:

- PR review submissions
- inline review comments
- check run details、annotations、logs
- 只有在明确绑定 accepted current-SHA review run 时才接受 PR comments

硬门槛:

- missing review 不能当 pass。
- stale review 不能当 pass。
- ambiguous review 不能当 pass。
- PR head 不等于当前本地 HEAD SHA 时不能 auto-merge。
- 无法确认 SHA 绑定时停止并向用户报告明确 blocker。

## Scripts

允许的 script 类型:

- version 同步
- Superset config 文件 install/verify

禁止的 script 类型:

- 整个 loop orchestration
- wait/decide/merge controller
- custom verdict artifact gate
- 写代码的后台 daemon

## 官方 Hook 模型

Claude Code hook 不只有 shell command 字符串。官方文档列出的 hook handler 类型包括 `command`、`http`、`mcp_tool`、`prompt`、`agent`;也定义了 `additionalContext`、`systemMessage`、Stop prompt decision 等 JSON 输出模式。Skill frontmatter 也可以定义随 skill 生命周期生效的 hook。

本 plugin 这样使用这个模型:

- `SessionStart` 仍是 command hook,因为官方文档说 `SessionStart` 支持 `command` 和 `mcp_tool`,不支持 `prompt`。
- `Stop` 是 prompt hook,因为把当前 Claude session 路由到 skill 是语义判断。
- `review-loop` 自己也定义 skill-scoped prompt Stop hook,防止闭环流程中途停止。

不要新增执行 PR/review/merge 工作的 prompt hook 或 agent hook。非 command hook 可以路由或 guard;workflow 由 skill 执行。

## Slash Commands

| Command | 作用 |
|---|---|
| `/24hour-ClaudeCode:setup` | 调用 onboarding skill。 |
| `/24hour-ClaudeCode:status` | 读取 config、git sync 和当前 PR 状态。 |
| `/24hour-ClaudeCode:disable` | 停止自动触发 review-loop。 |
| `/24hour-ClaudeCode:enable` | 恢复自动触发 review-loop。 |

## 验收检查

修改 runtime 后运行:

```bash
bash -n hooks/*.sh scripts/*.sh templates/*.sh
jq -e . hooks/hooks.json
jq -e . .claude-plugin/plugin.json
jq -e . templates/24hour-ClaudeCode.config.json
bash scripts/install-superset-config.sh --verify
```

Stop 路由用 Claude Code `/hooks` 检查:

- plugin `Stop` hook 类型是 `prompt`
- `review-loop` skill frontmatter 定义了 `Stop` prompt hook
- 没有 hook 指向 `hooks/stop.sh`、`hooks/goal-submit.sh` 或 `hooks/post-tool-use.sh`
