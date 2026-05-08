---
name: worktree-pr-flow
description: |
  在 worktree 内完整跑通 feature 开发 → 提 PR → 多 cloud agent review → 改反馈 → enable auto-merge → babysit 到 state=MERGED 的 Path B 流程。Trigger 关键词:走 Path B、Path B 流程、worktree 提 PR、开 PR 然后 babysit、做完整 PR、worktree → PR → 合入、提 PR 让 cloud agent review、PR auto-merge 流程、cloud agent review 流程、submit PR with review gate、PR babysit flow、worktree PR auto-merge、feature dev to merge、复现 PR 提交流程。也用于:被分配在 worktree 内开发任务时(任务 prompt 提示当前在 worktree、要求开 PR 合到 base 分支时)。Definition of Done = PR state=MERGED(不是"enable auto-merge",不是"代码写完",不是"CI 过了")。
---

# Worktree → PR → Auto-merge Path B 流程

> 这个 skill 把 Path B 8 步流程 + Monitor 6 条铁律 + 多 agent quality gate 编码成可稳定复现的执行序列。任何在 worktree 内开发并需要把 feature 合入项目 base 分支(dev/main/master 等)的任务都按这个走。
>
> **项目适配**:本流程默认假设 PR 由 cloud review agent(claude-review / Codex / Copilot 等)自动评审。命令示例使用通用占位符,实际跑时按本文末「项目适配」一节替换为你项目的具体值。

## ⚠️ 一开始就要内化的 8 条反模式(违反任意一条 = 工作未完成)

下列状态**全部不算完成**,只是中间步骤:
- ✅ 代码写完了 → 继续
- ✅ typecheck / lint / test 都过了 → 继续
- ✅ commit 创建了 → 继续
- ✅ push 上去了 → 继续
- ✅ PR 开了但没等 review agent 评论 → 继续
- ✅ review agent 评论看过了但还没决定改不改 → 继续
- ✅ 改完 review 反馈但没 enable auto-merge → 继续
- ✅ enable 了 auto-merge 但 PR 还没 MERGED → 继续 babysit 直到 MERGED 或 60min cap

**典型反模式(如果你正想说这种话,停下来直接干完再说话):**
- ❌ "代码改完了,要不要 push?" → 用户授权已经在 worktree 入口给过了,直接 push
- ❌ "PR 开好了,要不要 enable auto-merge?" → 直接 enable,--auto 自己会等 CI
- ❌ "测试都过了,等你 review 一下" → 用户的 review 在 PR 页面做,不在 chat 里做
- ❌ "改完了,给你 diff 看一下" → 直接走完所有步骤再贴 PR 链接,不要在 chat 里 mock review
- ❌ "先停下让你确认方向" → 方向确认应该在动手前;动手后只在遇到真正的 blocker 时停(脚本拒绝执行、CI 配置缺失、测试发现产品级 bug 需要决策)

**唯一允许停下来的边界**:见 [references/blockers.md](references/blockers.md)。

---

## 0. Pre-flight 检查(必跑)

执行前**必须**先验证 4 件事,任意一项不满足就停下来报告,不要硬上。

```bash
# 1) 当前目录是 worktree(不是主 checkout,也不是 worktree 之外的随便目录)
pwd && git worktree list | grep -F "$(pwd)"
# 期望:当前路径出现在 worktree 列表中。如果没有 → 停。

# 2) 当前分支不是受保护分支(main/master/dev/staging 之类),且名字像 feature/* fix/* chore/* review/*
git branch --show-current
# 期望:feature/xxx 或类似。如果是受保护分支 → 停。

# 3) 工作树相对干净(已知的"刚 worktree add 出来"或"已经写了部分代码"两种状态都 OK)
git status --short
# 不期望:未 staged 的 *删除* 历史文件 + lock 文件混改 + 数百行无关 diff

# 4) 用户已给出关联 issue 编号(GH issue 或项目管理工具 ID);没有就问一次
```

**如果 #4 缺失**:可以问用户一次"这个 PR 关联哪个 issue 编号?需要写进 PR body 的 `Closes` 句子让 issue 自动关闭"。这是允许的提问之一。

---

## 1. 写代码

skill 不替你决定写什么。但提交前确认下面几条质量 baseline:

- 单一职责:一个 PR 只做一件事;schema / 数据迁移类改动**单独 PR**(参考 [references/anti-patterns.md](references/anti-patterns.md) 的 "Schema PR" 段)
- 复用已有 helper / service,不重复造
- 注释只在 *why* 非显然时加
- 不在 system boundary 之外加多余 validation
- **遵守项目级 CLAUDE.md / 风格指南**:如果项目 root 有 `CLAUDE.md` / `AGENTS.md` / `STYLE_GUIDE.md` 等,顶部规则视同硬约束;违反会被 quality gate 直接 Reject(详见 [references/quality-gate.md](references/quality-gate.md))

---

## 2. Local verification(push 前必跑)

按改动面执行。**全过才进 step 3**。失败就在本地修,不要带着错误 push 让 CI 替你失败。

```bash
# 通用模板(按你项目的包管理器和命令替换):
<typecheck command>     # e.g. pnpm typecheck / npm run typecheck / tsc --noEmit / mypy / cargo check
<lint command>          # e.g. pnpm lint / eslint / ruff / golangci-lint
<test command>          # e.g. pnpm test / jest / pytest / go test ./...

# Monorepo 项目:只跑改动所在 package 的命令,以及它的下游消费方
# Shared/lib 改动 → 双向 typecheck(自身 + 所有消费方都要过)

# UI 改动 → 真在模拟器/浏览器里点一遍 golden path + edge case
# (type check 只验代码合法,不验 feature 合不合理)
```

**红线**:禁用 `--no-verify`、禁用 `git commit -n`、禁止跳过 pre-commit hook。hook 失败 → 修,不绕。

---

## 3. Commit

Conventional Commits 格式。message 写 *why*,不重复 *what*(diff 自己会说)。

```bash
git add <具体文件,不用 -A>
git commit -m "$(cat <<'EOF'
feat(scope): 一句话说做了什么

可选的 body:解释为什么这样做、跟其他模块的关系、未来要扩什么。

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

允许 prefix:`feat / fix / chore / refactor / docs / test / perf / build / ci / style`。**review 反馈修复**专用 prefix:`review:`(在 step 6c 用)。

---

## 4. Push

```bash
git push -u origin "$(git branch --show-current)"
```

`-u` 让本地 branch 跟踪 remote,后续 `git push` 不带参数即可。

---

## 5. PR 创建

```bash
# 默认非 draft(draft 会跳过部分 review agent,gate 失效)
gh pr create --base <BASE_BRANCH> --fill
# <BASE_BRANCH> 替换为项目实际 base 分支:dev / main / master / develop 等
```

**PR body 必须包含的内容**:

```markdown
## What
<一段话讲改了什么、为什么>

## How tested
- [x] typecheck/lint/test
- [x] 真机/模拟器/浏览器手测 <feature>

## Linked issue
Closes #<issue_number>
# 或对应项目管理工具的 ID(如 Closes XXX-123)
```

**`Closes` 句子是硬要求**:没写 → PR merge 后 issue 不会自动关闭 → inbox 会堆。

PR 创建成功后立即记下 PR 编号(输出会显示 PR URL),后面所有命令都要用。

---

## 6. Quality gate(多轮 review,直到 review agents 没意见)

### 6a. Arm Monitor 等 review

PR 一开就立刻 arm Monitor,**这一个 Monitor 从 step 6 一直跑到 step 8 MERGED**,不要中途换。

完整模板见 [references/monitor-template.md](references/monitor-template.md)(必须 verbatim 复制 6 条铁律,自己改一定踩坑)。

⚠️ **关键时序**(基于常见 review agent 的实际响应窗口):
- 内置 review(如 claude-review)通常 30–60s 出第一条反馈 → **不是**整轮 review 完成的信号
- 第三方 GitHub App(Codex / Copilot 等)平均 3–5 分钟
- **≥5 分钟**才能进 6b
- 15 分钟 cap:不管几个 agent 出声,到点直接进 6b
- 如果 15 分钟全部沉默(PR 太小被各 agent 主动忽略)→ 直接 step 7

**这段空窗(5–15 分钟)不要去顺手加东西**:push 新 commit = CI 重跑 + agent 重审 = gate 时序乱掉。要么静默轮询 Monitor,要么开新 worktree 干别的 issue。

### 6b. 评估反馈

合并所有 agent 的反馈,按 **Reject / Major / Minor / Nit** 矩阵评估。详见 [references/quality-gate.md](references/quality-gate.md)。

简版规则:
- 多 agent 同时指出同一问题 → 优先级 +1(弱信号叠加 = 强信号)
- 单 agent 指出、其他沉默 → 按原级别处理
- **任何级别(包括 Nit)真合理** → 6c 修
- 真不合理(agent 看错 / 已是项目约定 / 与项目级 CLAUDE.md 顶部规则冲突)→ 在 PR 上 reply 一句说明,跳过
- agent 之间冲突(A 说加缓存 / B 说别加)→ 默认按项目 CLAUDE.md,没明确约束就保留现状 + reply

**防死循环**:单条建议最多采纳 2 次(第二次后同 agent 还重复 → reply "已多次评估,决定保留现状",跳过)。整个 gate ≤ 60 分钟 wall clock,超时直接 step 7。

### 6c. 修反馈 → commit → push → 回 6a

```bash
git add <文件>
git commit -m "review: address <agent> on PR #<N> — <一句话>"
git push
```

**commit body 列举**:采纳了哪个 agent 的哪条建议、哪些没采纳和原因。

push 完后 CI 重跑 + review agents 重审 → **回 6a 等下一轮**。Monitor 会自动捕获 reviewers 字段变化触发新事件。

---

## 7. Enable auto-merge(紧跟 step 6 结束,不要停下来问用户)

```bash
gh pr merge --auto --merge <PR#>
```

- `--auto` 自己会等 required checks 全过 + ready 状态
- `--merge`(保留 commits),除非项目约定用 `--squash` / `--rebase`
- 如果 PR 是合到受保护的发布分支(通常是 main)且 branch protection 要求 1 个人工 approval → 加 `--approve`(需要你账户有该权限);并按项目约定调整 merge 方式(常见做法:发布分支用 `--squash`)

**这一步必须立即执行**。auto-merge 本身就是 deferred—它自己等条件,所以你立即 enable 它没有任何风险。如果你之后还想再 push 改动,正常 push 就行,CI 重跑过了照样合。

**留着 PR 不 enable auto-merge = 你必须最后再回来一次手动启用 = 把工作流断开 = 这个 skill 的失败模式之一**。

---

## 8. Babysit loop(直到 state=MERGED 才退出,最多 60 分钟)

step 6 已经 arm 的 Monitor 继续跑。每个 tick 收一行状态字符串,状态变了 emit 一行,agent 接事件后按 [references/decision-table.md](references/decision-table.md) 处理。

⚠️ **不要嘴上"6 分钟后回来"** = turn 结束 = 进程死亡。**必须用 Monitor 真醒来**。

### 退出条件

| 事件 | 处理 |
|---|---|
| `state=MERGED` | 退出 ✅,向用户贴 PR 链接 + 一句"已合入 <base 分支>" |
| `state=CLOSED`(未 merge) | 告诉用户原因,退出 |
| 60 分钟 cap | 告诉用户当前 state + 已发生事件,退出 |

### 中途事件处理(详细决策表见 references/decision-table.md)

- `merge=BEHIND`(base 有新 commit,无冲突)→ 直接 fetch + merge + push,auto-merge 接管
- `merge=DIRTY`(有冲突)→ 默认告诉用户准备 fetch+merge+push,等确认;纯文件增量 / 完全独立改动可直接处理
- `checks=*:failure` → 不自动 retry,告诉用户失败 check 名 + 退出
- `reviewers=` 出现新名字 → 回 step 6 多轮 gate(Monitor 不需要重 arm,事件流自然驱动)
- 其他变化(CLEAN / BLOCKED / UNSTABLE)→ 静默等下一行

⚠️ 如果项目 repo 开了 "Require branches up-to-date before merging",auto-merge 看到 BEHIND **不会自动追**——必须 babysit 推 update。`gh repo view --json defaultBranchRef,branchProtectionRules` 可查 branch protection 状态。

### 没 Monitor 工具的兜底

- 有 `ScheduleWakeup` → 用它(无事件区分,每分钟全量查一次,效率低但能跑)
- 都没有 → 不要 fake。明确告诉用户:"我没有 Monitor / scheduling 工具,babysit 由 always-on session 接管",退出
- **禁止** Bash long sleep(系统拦截 + turn 结束进程消失)

---

## Definition of Done(DoD)

PR `state=MERGED`。任何在此之前的状态(auto-merge enabled、CI 绿、review agent OK、reviewers approved)都不是完成。

完成时回复用户的格式:

```
✅ PR #<N> merged: <PR URL>
- review 轮次:<N> 轮
- 采纳反馈:<X> 条(来自 <agent A>, <agent B>)
- 跳过反馈:<Y> 条(reason: ...)
- 总耗时:<wall clock>
```

不需要"接下来呢"、"是否还有其他事"——end of turn。

---

## 用户合并后的清理(**Claude 不做**)

清理 worktree 是用户在主 checkout 上执行的,**skill 不要碰**:

```bash
# 用户在主 checkout 上(通用):
git worktree remove <worktree-path>
git branch -d <branch-name>

# 如果项目有自定义 worktree 脚本(如 ./scripts/wt rm <name>),用项目的
```

如果用户问 "我现在该怎么清理",告诉他这一行,不要替他执行(你在 worktree 内,没法 rm 自己所在的 worktree)。

---

## 索引

- [references/monitor-template.md](references/monitor-template.md) — Monitor verbatim 模板 + 6 条铁律 + 字段速查
- [references/quality-gate.md](references/quality-gate.md) — 多 agent review 评估决策细则
- [references/decision-table.md](references/decision-table.md) — babysit 事件处理矩阵
- [references/anti-patterns.md](references/anti-patterns.md) — 失败模式集合
- [references/blockers.md](references/blockers.md) — 唯一允许停下来问用户的场景
- [CHECKLIST.md](CHECKLIST.md) — 自审速查表(每 step 一条)
- [INSTALL.md](INSTALL.md) — 安装为 Claude Code skill 的方法

---

## 项目适配

这个 skill 的核心流程通用,但具体命令需要按项目替换。第一次在新项目使用时,确认下面 6 个变量的值并写进项目的 `.claude/CLAUDE.md` 或 README 里:

| 变量 | 通用占位符 | 替换为项目的具体值 |
|---|---|---|
| 包管理器 + workspace 命令 | `<typecheck/lint/test command>` | 例如 `pnpm --filter @scope/pkg typecheck` / `npm run lint` / `pytest tests/` |
| 默认 base 分支 | `<BASE_BRANCH>` | 看仓库 default branch:`dev` / `main` / `master` / `develop` |
| Lint / pre-commit 自定义钩子 | `<lint command>` 内 | 项目特有的 `scripts/check-*.sh` 等 |
| Review agent 列表 | claude-review / Codex / Copilot(常见组合) | 看 `.github/workflows/` 里实际触发的是哪些 |
| Repo URL(`Closes` 句子和 PR URL) | `<PR URL>` | `https://github.com/<org>/<repo>/pull/<N>` |
| Merge 方式(step 7) | `--merge`(默认) | 项目约定:`--squash` / `--rebase` 等 |

**核心流程不要改**:
- 8 步顺序(Pre-flight → 写码 → 验证 → commit → push → PR → quality gate → auto-merge → babysit)
- Monitor 6 条铁律(verbatim)
- Quality gate 时序(<5 min 不进 6b、15 min 强进 6b、60 min cap)
- DoD = `state=MERGED`
