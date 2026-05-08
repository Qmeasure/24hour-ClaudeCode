---
name: worktree-pr-flow
description: |
  在 worktree 内完整跑通 feature 开发 → 提 PR → Claude Code Action 自动 review → 改反馈(本地修 / @claude 委托)→ enable auto-merge → babysit 到 state=MERGED 的 Path B 流程。Trigger 关键词:走 Path B、Path B 流程、worktree 提 PR、开 PR 然后 babysit、做完整 PR、worktree → PR → 合入、提 PR 让 cloud agent review、PR auto-merge 流程、cloud agent review 流程、submit PR with review gate、PR babysit flow、worktree PR auto-merge、feature dev to merge、复现 PR 提交流程、Claude Code Actions PR flow、@claude review fix PR、GitHub Actions Claude review babysit、claude-code-action workflow PR、CCA PR loop。也用于:被分配在 worktree 内开发任务时(任务 prompt 提示当前在 worktree、要求开 PR 合到 base 分支时)。Definition of Done = PR state=MERGED(不是"enable auto-merge",不是"代码写完",不是"CI 过了")。**首次在新仓库跑前**:确认仓库已配 Claude Code Actions(secret + workflow YAML)。未配 → 跳到 [SETUP.md](SETUP.md)。
---

# Worktree → PR → Claude Code Action review → Auto-merge Path B 流程

> 这个 skill 把 9 步流程 + Monitor 6 条铁律 + multi-agent quality gate 编码成可稳定复现的执行序列。任何在 worktree 内开发并需要把 feature 合入项目 base 分支(dev/main/master 等)的任务都按这个走。
>
> **review producer 默认是仓库部署的 Claude Code Action**(自建 `.github/workflows/claude-code-review.yml`,走你的 Pro/Max 订阅 token)。如果仓库还有第三方 review agent(Codex / Copilot 等)共存,流程同样适用——只是 quality gate 的等待窗口拉长(详见 [references/quality-gate.md](references/quality-gate.md) 的"档位 B")。

## Claude Code Actions 改变了什么(对比传统第三方 review 流程)

| 维度 | 传统(第三方 cloud agent) | Claude Code Action 主导 |
|---|---|---|
| review 来源 | Codex / Copilot 等第三方 GitHub App | 仓库自建 workflow,跑你订阅的 Claude |
| 出反馈时延 | 3–5 分钟(webhook + 第三方排队) | 30s–2 分钟(Action runner 冷启动 + Claude 看代码) |
| Quality gate 窗口 | t<5min 不进 6b、t=15min 强制 6b | t<2min 不进 6b、t=8min 强制 6b |
| 修反馈路径 | 只能本地编辑 + commit + push | 双路径:**A) 本地修**,**B) PR 评论 `@claude 修 XXX` 委托 Action 自己 commit** |
| 成本 | 第三方平台账单 | 走你的 Claude Pro/Max 订阅 quota(或 API Key) |
| 触发策略 | 由第三方 App 决定 | 你的 `.github/workflows/claude*.yml` 的 `on:` 字段决定 |

如果你看到的反馈来源是 `claude[bot]`(reviewers 字段里出现) → 走档位 A 时序。

## ⚠️ 一开始就要内化的 8 条反模式(违反任意一条 = 工作未完成)

下列状态**全部不算完成**,只是中间步骤:
- ✅ 代码写完了 → 继续
- ✅ typecheck / lint / test 都过了 → 继续
- ✅ commit 创建了 → 继续
- ✅ push 上去了 → 继续
- ✅ PR 开了但没等 Action review → 继续
- ✅ Action review 评论看过了但还没决定改不改 → 继续
- ✅ 改完反馈但没 enable auto-merge → 继续
- ✅ enable 了 auto-merge 但 PR 还没 MERGED → 继续 babysit 直到 MERGED 或 60min cap

**典型反模式(如果你正想说这种话,停下来直接干完再说话):**
- ❌ "代码改完了,要不要 push?" → 用户授权已经在 worktree 入口给过了,直接 push
- ❌ "PR 开好了,要不要 enable auto-merge?" → 直接 enable,--auto 自己会等 CI
- ❌ "测试都过了,等你 review 一下" → 用户的 review 在 PR 页面做,不在 chat 里做
- ❌ "改完了,给你 diff 看一下" → 直接走完所有步骤再贴 PR 链接,不要在 chat 里 mock review
- ❌ "先停下让你确认方向" → 方向确认应该在动手前;动手后只在遇到真正的 blocker 时停

**唯一允许停下来的边界**:见 [references/blockers.md](references/blockers.md)(共 8 类,其中 #7 / #8 是 Actions 专属)。

---

## 0. Pre-flight 检查(必跑)

执行前**必须**先验证 5 件事,任意一项不满足就停下来报告,不要硬上。

```bash
# 1) 当前目录是 worktree(不是主 checkout,也不是 worktree 之外的随便目录)
pwd && git worktree list | grep -F "$(pwd)"
# 期望:当前路径出现在 worktree 列表中。如果没有 → 停。

# 2) 当前分支不是受保护分支(main/master/dev/staging 之类),且名字像 feature/* fix/* chore/* review/*
git branch --show-current
# 期望:feature/xxx 或类似。如果是受保护分支 → 停。

# 3) 工作树相对干净
git status --short
# 不期望:未 staged 的 *删除* 历史文件 + lock 文件混改 + 数百行无关 diff

# 4) 用户已给出关联 issue 编号(GH issue 或项目管理工具 ID);没有就问一次

# 5) 仓库已配 Claude Code Actions(本 skill 的核心依赖)
# 推荐用 skill 自带的检查脚本:
bash "${SUPERSET_ROOT_PATH:-$(git rev-parse --show-toplevel)}/scripts/check-actions.sh" -v
# 退出码 0 = 全部 OK;1 = ERROR(必须修);2 = WARN(能跑但建议修)

# 或手动检查:
gh secret list -R <owner>/<repo> | grep -E '^CLAUDE_CODE_OAUTH_TOKEN|^ANTHROPIC_API_KEY'
# 期望:看到 CLAUDE_CODE_OAUTH_TOKEN 或 ANTHROPIC_API_KEY 至少一个

ls .github/workflows/ 2>/dev/null | grep -E 'claude.*\.ya?ml'
# 期望:至少一个 claude*.yml 文件

# 如果仓库没配 → **不要硬上**,告诉用户在主 checkout 跑:
#   bash scripts/configure-actions.sh
# 一键配完(10–15 分钟,见 SETUP.md),然后回来跑这个 skill。
```

### Superset 用户额外检查

如果环境里有 `$SUPERSET_WORKSPACE_PATH`(说明在 Superset workspace 里):

- workspace 创建时 setup 钩子已自动跑了 `check-actions.sh`,理论上 #5 已通过
- 如果 setup 当时报了 ERROR,你应该已经看到红色提示了 → 在主 checkout 跑 `bash scripts/configure-actions.sh` 修
- 详见 [references/superset-integration.md](references/superset-integration.md)

**如果 #4 缺失**:可以问用户一次"这个 PR 关联哪个 issue 编号?需要写进 PR body 的 `Closes` 句子让 issue 自动关闭"。这是允许的提问之一。

**如果 #5 缺失**:告诉用户"仓库还没配 Claude Code Actions,review 流程没人跑。请先按 [SETUP.md](SETUP.md) 配置(10–15 分钟),完成后再跑这个 skill。" 然后退出,不进 step 1。

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
# 默认非 draft(draft 可能跳过部分 review agent,gate 失效)
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

PR 创建成功立即记下 PR 编号(输出会显示 PR URL),后面所有命令都要用。

**PR 一开,`pull_request: opened` 触发 → `claude-code-review.yml` workflow 自动跑**。30s–2min 后会看到 Claude 的 review 评论。

---

## 6. Quality gate(多轮 review,直到反馈静默)

### 6a. Arm Monitor 等 review

PR 一开就立刻 arm Monitor,**这一个 Monitor 从 step 6 一直跑到 step 8 MERGED**,不要中途换。

完整模板见 [references/monitor-template.md](references/monitor-template.md)(必须 verbatim 复制 6 条铁律,自己改一定踩坑)。

⚠️ **关键时序(档位 A:Claude Code Action 主导)**:
- Action runner 冷启动 30–60s,再加 Claude 看代码 → **30s–2min** 出第一条 review
- **t < 2min 不进 6b**,即使本地已经看到 review 评论(给大型 PR 让 Claude 看完的时间)
- t = 8min:强制进 6b(有几条算几条);全部沉默 → 进 step 7
- 整个 gate ≤ 60min wall-clock cap

⚠️ **如果仓库还有第三方 agent 共存(档位 B)**:窗口拉宽到 t<5min / t=15min。详见 [references/quality-gate.md §0](references/quality-gate.md) 的档位判断。

⚠️ **如果 8min 到 reviewers 还是空**:先 `gh run list -w claude-code-review.yml --limit 3` 确认 workflow 有跑。完全没跑 / 全失败 = [blockers.md #7](references/blockers.md) Actions 没触发。

**这段空窗(2–8 分钟)不要去顺手加东西**:push 新 commit = CI 重跑 + Action 重审 = gate 时序乱掉。要么静默轮询 Monitor,要么开新 worktree 干别的 issue。

### 6b. 评估反馈

合并所有 agent 的反馈(`claude[bot]` + 任何第三方 agent),按 **Reject / Major / Minor / Nit** 矩阵评估。详见 [references/quality-gate.md](references/quality-gate.md)。

简版规则:
- 多 agent 同时指出同一问题 → 优先级 +1(弱信号叠加 = 强信号)
- 单 agent 指出、其他沉默 → 按原级别处理
- **任何级别(包括 Nit)真合理** → 6c 修
- 真不合理 → 在 PR 上 reply 一句说明,跳过
- agent 之间冲突 → 默认按项目 CLAUDE.md,没明确约束就保留现状 + reply

**防死循环**:单条建议最多采纳 2 次,整 gate ≤ 60 分钟。

### 6c. 修反馈 → commit → push → 回 6a

有两条路径,看反馈类型选:

#### 路径 A:本地修(经典)

```bash
git add <文件>
git commit -m "review: address <agent> on PR #<N> — <一句话>"
git push
```

#### 路径 B:委托 `@claude` 自己修

在 PR 评论里贴:

```
@claude 把 src/foo.ts 第 47 行的 race condition 修了
```

`claude.yml` workflow 触发 → Action 在 runner 里 checkout、改、commit、push。30s–3min 后 PR 出现新 commit。

**怎么选**:

| 反馈情况 | 推荐路径 |
|---|---|
| 复杂 / 跨多文件 / 涉及项目级约束 | A,你比 Action 更懂全貌 |
| 单点明确修改、agent 已经指了具体行 | B,省时间 |
| 涉及生产敏感文件 | A 且按 [blockers.md #6](references/blockers.md) 必须人工 review |

详见 [references/quality-gate.md §2.5](references/quality-gate.md)。

#### push 完后回 6a

CI 重跑 + Action 重审 → **回 6a 等下一轮**。Monitor 会自动捕获 reviewers 字段变化触发新事件。

⚠️ **路径 B 的额外检查**:`@claude` 委托后 5min 还没新 commit → 查 `gh run list -w claude.yml --limit 1` 是否在跑 / 是否失败。失败 = [blockers.md #8](references/blockers.md)。

---

## 7. Enable auto-merge(紧跟 step 6 结束,不要停下来问用户)

```bash
gh pr merge --auto --merge <PR#>
```

- `--auto` 自己会等 required checks 全过 + ready 状态
- `--merge`(保留 commits),除非项目约定用 `--squash` / `--rebase`
- 如果 PR 是合到受保护的发布分支(通常是 main)且 branch protection 要求 1 个人工 approval → 加 `--approve`(需要你账户有该权限);并按项目约定调整 merge 方式

**这一步必须立即执行**。auto-merge 本身就是 deferred—它自己等条件,所以你立即 enable 它没有任何风险。

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
- `reviewers=` 出现新名字(包括 `claude[bot]`)→ 回 step 6 多轮 gate
- 5min 还没 reviewers + workflow 没 run → [blockers.md #7](references/blockers.md)
- 其他变化(CLEAN / BLOCKED / UNSTABLE)→ 静默等下一行

⚠️ 如果项目 repo 开了 "Require branches up-to-date before merging",auto-merge 看到 BEHIND **不会自动追**——必须 babysit 推 update。`gh repo view --json defaultBranchRef,branchProtectionRules` 可查 branch protection 状态。

### 没 Monitor 工具的兜底

- 有 `ScheduleWakeup` → 用它(无事件区分,每分钟全量查一次,效率低但能跑)
- 都没有 → 不要 fake。明确告诉用户:"我没有 Monitor / scheduling 工具,babysit 由 always-on session 接管",退出
- **禁止** Bash long sleep(系统拦截 + turn 结束进程消失)

---

## Definition of Done(DoD)

PR `state=MERGED`。任何在此之前的状态(auto-merge enabled、CI 绿、Action review OK、reviewers approved)都不是完成。

完成时回复用户的格式:

```
✅ PR #<N> merged: <PR URL>
- review 轮次:<N> 轮(包括 claude[bot] + <第三方 agents>)
- 采纳反馈:<X> 条(本地修 <a> 条 / @claude 委托 <b> 条)
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

### 首次配置
- [SETUP.md](SETUP.md) — **零基础**首次在仓库配置 Claude Code Actions(必读,如果仓库还没配)
- `scripts/configure-actions.sh` — **一键交互式**配置脚本(SETUP.md Quick path)
- `scripts/check-actions.sh` — 健康检查(Superset setup 自动跑;人工排查也用)
- `scripts/install-superset-config.sh` — 注入 `.superset/config.json`

### 流程参考
- [references/workflow-yaml.md](references/workflow-yaml.md) — 30+ Actions 参数 + GitHub Actions 字段 + claude_args CLI flag 全参考
- [references/monitor-template.md](references/monitor-template.md) — Monitor verbatim 模板 + 6 条铁律 + 字段速查
- [references/quality-gate.md](references/quality-gate.md) — 多 agent review 评估决策细则(含 Action 自修 path)
- [references/decision-table.md](references/decision-table.md) — babysit 事件处理矩阵
- [references/anti-patterns.md](references/anti-patterns.md) — 失败模式集合(A–H 共 8 类,H 是 Actions 专属)
- [references/blockers.md](references/blockers.md) — 唯一允许停下来问用户的 8 个场景
- [references/superset-integration.md](references/superset-integration.md) — Superset 多 worktree 流水线接入(钩子时机 / env / 团队共享 vs 个人覆盖)
- [references/official-docs-cheatsheet.md](references/official-docs-cheatsheet.md) — 官方 docs 关键 10 条(OIDC / 嵌套 workflow / 不能改 .github/workflows / Bash 默认禁 / MCP / settings 等)
- [CHECKLIST.md](CHECKLIST.md) — 自审速查表(每 step 一条)
- [INSTALL.md](INSTALL.md) — skill 自身的安装方法

### 模板(`templates/`)
- `templates/claude.yml` — `@claude` 交互 workflow 模板
- `templates/claude-code-review.yml` — 自动 PR review workflow 模板
- `templates/superset-config.json` — Superset 配置模板

---

## 项目适配

这个 skill 的核心流程通用,但具体命令需要按项目替换。第一次在新项目使用时,确认下面 7 个变量的值并写进项目的 `.claude/CLAUDE.md` 或 README 里:

| 变量 | 通用占位符 | 替换为项目的具体值 |
|---|---|---|
| 包管理器 + workspace 命令 | `<typecheck/lint/test command>` | 例如 `pnpm --filter @scope/pkg typecheck` / `npm run lint` / `pytest tests/` |
| 默认 base 分支 | `<BASE_BRANCH>` | 看仓库 default branch:`dev` / `main` / `master` / `develop` |
| Lint / pre-commit 自定义钩子 | `<lint command>` 内 | 项目特有的 `scripts/check-*.sh` 等 |
| Review agent 列表 | `claude[bot]` 默认;可加 Codex / Copilot 等 | 看 `.github/workflows/` + 看历史 PR 的 reviewers 字段 |
| Repo URL(`Closes` 句子和 PR URL) | `<PR URL>` | `https://github.com/<org>/<repo>/pull/<N>` |
| Merge 方式(step 7) | `--merge`(默认) | 项目约定:`--squash` / `--rebase` 等 |
| Quality gate 档位 | A(Action 主导) | 看仓库装的 review agents:只有 Action = A;还有第三方 = B |

**核心流程不要改**:
- 9 步顺序(Pre-flight → 写码 → 验证 → commit → push → PR → quality gate → auto-merge → babysit)
- Monitor 6 条铁律(verbatim)
- Quality gate 时序(档位 A:t<2min 不进 6b、t=8min cap;档位 B:t<5min 不进 6b、t=15min cap;wall clock 60min)
- DoD = `state=MERGED`
