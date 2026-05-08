# 自审速查表

> 每 step 完成时扫一遍。任何一条没打勾就是没完成。

## Pre-flight (step 0)

- [ ] `pwd` + `git worktree list` 确认在 worktree 内
- [ ] `git branch --show-current` 不是受保护分支(main/master/dev/staging 等)
- [ ] `git status --short` 无意外内容
- [ ] 已知关联 issue 编号(或用户明确说"无关联 issue")

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
- [ ] 等 ≥5 分钟才进 6b(除非 15 min cap 到了)
- [ ] 所有 agent 的反馈合并按 Reject/Major/Minor/Nit 矩阵评估
- [ ] 真合理的反馈(包括 Nit)已采纳并 push
- [ ] 真不合理的反馈已在 PR 上 reply 解释
- [ ] 单条建议没采纳超过 2 次
- [ ] 整个 gate 没超 60 分钟

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
- [ ] 5 分钟内就 enable auto-merge → step 6 时序作弊
- [ ] 反馈采纳 ≥3 次同一条 → 防死循环失效
- [ ] 总时间 ≥90 分钟 → 应该在 60 min cap 退出但没退
