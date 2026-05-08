# 自审速查表

> 每 step 完成时扫一遍。任何一条没打勾就是没完成。

## Pre-flight (step 0)

- [ ] `pwd` + `git worktree list` 确认在 worktree 内
- [ ] `git branch --show-current` 不是受保护分支(main/master/dev/staging 等)
- [ ] `git status --short` 无意外内容
- [ ] 已知关联 issue 编号(或用户明确说"无关联 issue")
- [ ] 仓库装了 Claude GitHub App(`https://github.com/apps/claude` → 选 repo → 已勾选)
- [ ] `gh secret list -R <repo>` 含 `CLAUDE_CODE_OAUTH_TOKEN` 或 `ANTHROPIC_API_KEY`
- [ ] `.github/workflows/` 至少有一个 `claude*.yml`(`ls .github/workflows/`)
- [ ] 如果允许 `@claude` 自修代码:对应 workflow 的 `permissions.contents` 是 `write`
- [ ] 上面任一条不满足 → 告诉用户跳到 [SETUP.md](SETUP.md),退出当前 skill

## Local verification (step 2)

- [ ] typecheck 全过(改动涉及的所有 package)
- [ ] lint 全过(含项目自定义钩子,如 `scripts/check-*.sh`)
- [ ] test 全过
- [ ] UI 改动已在模拟器/浏览器手测 golden path

## Commit (step 3)

- [ ] Conventional Commits 前缀正确(feat/fix/chore/refactor/docs/test/perf/build/ci/style)
- [ ] message 写 *why*,不重复 diff 已经显示的 *what*
- [ ] 只 `git add <具体文件>`,不 `git add -A` / `git add .`
- [ ] 没用 `--no-verify`、没 skip pre-commit hook

## PR 创建 (step 5)

- [ ] `gh pr create --base <BASE_BRANCH> --fill` 执行成功
- [ ] PR body 含 `Closes #<N>` 或 项目管理工具对应 ID
- [ ] PR 不是 draft(draft 会跳过部分 review agent)
- [ ] PR 编号已记下(后续命令要用)

## Quality gate (step 6)

- [ ] Monitor 已 arm(一直跑到 step 8 退出,不重 arm)
- [ ] 档位 A(Action 主导):等 ≥2 分钟才进 6b,8 分钟强制 6b
- [ ] 档位 B(多 agent 共存):等 ≥5 分钟才进 6b,15 分钟强制 6b
- [ ] 所有 agent 的反馈合并按 Reject/Major/Minor/Nit 矩阵评估
- [ ] 真合理的反馈(包括 Nit)已采纳并 push(本地修 / `@claude` 委托均可)
- [ ] 真不合理的反馈已在 PR 上 reply 解释
- [ ] 单条建议没采纳超过 2 次
- [ ] 整个 gate 没超 60 分钟
- [ ] `@claude` 委托修复时,Action workflow 5min 内出新 commit(否则查 `gh run list -w claude.yml`)

## Auto-merge (step 7)

- [ ] step 6 反馈静默后立即执行 `gh pr merge --auto --merge <N>`(或项目约定的 merge 方式)
- [ ] 没在 step 6 → step 7 之间停下问用户
- [ ] 用项目约定的 merge 方式(默认 `--merge`,发布分支按项目惯例可能是 `--squash`)

## Babysit (step 8)

- [ ] Monitor 持续运行(step 6 那个,没换)
- [ ] BEHIND 出现立刻 fetch + merge + push(无冲突直接做)
- [ ] DIRTY 出现按白名单判断(白名单内做,业务冲突停下问)
- [ ] CI failure 出现立刻退出,告诉用户失败 check 名
- [ ] reviewers 字段变化触发回 step 6 多轮 gate
- [ ] 60 min cap 到 → 给 cap 消息 → 退出

## Definition of Done

- [ ] PR `state=MERGED`(**不是** auto-merge enabled、**不是** CI 绿、**不是** review approved)
- [ ] 给用户成功消息(PR 链接 + 轮次 + 反馈摘要 + 总耗时 + 关联 issue)
- [ ] 没问"接下来呢"

## Skill 失败模式自检

如果做完发现下面任一项为真,复盘哪步出错:

- [ ] 用户在中途回来过 1 次以上 → step A 反模式(中途停下问用户)
- [ ] PR 合上但 review agent 还有未 reply 的评论 → step 6 跳过了
- [ ] PR 合上但本来该跑 BEHIND fetch+merge+push 没做 → step 8 决策表错
- [ ] 档位 A 下 < 2 分钟、档位 B 下 < 5 分钟就 enable auto-merge → step 6 时序作弊
- [ ] 反馈采纳 ≥3 次同一条 → 防死循环失效
- [ ] 总时间 ≥90 分钟 → 应该在 60 min cap 退出但没退

## Claude Code Actions 配置失败模式自检

跑前 / 跑中如果出现下面任一项,通常是 Actions 配置问题:

- [ ] OAuth token 在对话 / commit message / log 中出现过明文 → H1 反模式(立刻 `claude setup-token` 重生成 + 覆盖 secret)
- [ ] `@claude` 修代码后 PR 没新 commit → 查 `permissions: contents: write` 是否设了(H2)
- [ ] PR 跑两遍 review,token 翻倍 → 检查触发器是否重复(H7)
- [ ] Action 跑到一半被 max-turns 掐断,留半成品 → 调大 `--max-turns`(H6)
- [ ] 没设 `concurrency`,push 风暴跑 N 遍 → 加 `cancel-in-progress: true`(H4)
- [ ] 没设 `timeout-minutes`,卡住烧 6 小时 → 设 10–15(H5)
- [ ] OAuth token 错位填到 `anthropic_api_key` 字段 → 401(H8)
- [ ] 8min(档位 A)/ 15min(档位 B)reviewers 还空 → `gh run list -w claude-code-review.yml` 看是否触发(blockers #7)
