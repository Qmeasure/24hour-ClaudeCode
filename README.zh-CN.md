[English](README.md) | **中文**

# 24hour-ClaudeCode

**一个帮你"发车"的小助手:你写代码,它替你做剩下的全部事情。**

你在一个项目里用 Claude Code。让它修个 bug 或加个功能,代码改完之后,通常还得自己:

- 跑测试
- 写一条像样的 commit 消息提交
- push 到 GitHub
- 发起 Pull Request
- 等审核机器人看一遍
- 根据反馈再改(然后大概率还要再改一轮)
- CI 全绿了点"merge"按钮

这个 plugin 帮你**全部自动搞定**。**你只管写代码,它帮你把 PR 合进去。**

---

## 用起来是什么感觉

一个完整功能的开发,大概长这样:

> **你:** "在报表页加个 CSV 导出功能。"
>
> *(Claude 改了 3 个文件。你说"看着不错"。)*
>
> **Claude:** "✅ 我已经把改动 commit 了,开了 PR #142,CI 正在跑。等一下我看下结果。"
>
> *(两分钟后)*
>
> **Claude:** "✅ PR #142 已合入:github.com/your-org/your-repo/pull/142"

万一出了问题,闭环也会自动处理:

> **Claude:** "审核发现一个 bug —— 新的 `/export` 接口没处理空数据集的情况(48 行)。我来修一下。"
>
> *(Claude 修好了。CI 重跑。通过。)*
>
> **Claude:** "✅ PR #142 已合入。"

整个过程你**没敲过** `git commit`、`gh pr create`,**没点过**"merge"按钮。Plugin 全帮你做了。

---

## 什么时候用这个 plugin

✅ **适合的场景:**
- 你在一个真实的 GitHub 项目上工作
- 你希望 Claude Code 把整个 feature 开发到上线一气呵成,不用每一步都催它
- 你能接受让自动化进程帮你 commit + push(每次 push 前会问你确认,不会偷偷干事)

❌ **暂时不适合的场景:**
- 你在做探索性工作,还不想 commit
- 你的项目不在 GitHub 上
- 你在改高敏感代码(密码、生产配置)—— plugin 默认就拒绝碰这些路径,但你可能更想完全手动

---

## 快速开始

整个流程**就 3 步**,每台机器一次 + 每个 repo 一次。配好以后,你每开发一个 feature,只要 `git worktree add` 一下,后面 PR 全自动跑完。

```
第 1 步(每台机器一次)→ 安装 plugin            ─┐
                                                 │
第 2 步(每个 repo 一次)→ 在 main 分支 onboard │ ← 配置必须先落到 main
                                                 │    workflow YAML 必须
第 3 步(每个 feature) → 开 worktree            │    在默认分支才有效
                          改代码 → 自动 PR     ─┘
```

### 第 1 步 —— 安装 plugin(一次性,全局)

```bash
# 确保 gh CLI 有 workflow scope(后面要 push .github/workflows/*.yml 才能过)
gh auth login --scopes workflow

# Plugin 装一次,自动对这台机器上所有 repo 生效
claude plugin marketplace add Qmeasure/24hour-ClaudeCode
claude plugin install 24hour-ClaudeCode@24hour-ClaudeCode
```

确认:`claude plugin list` 看到 `24hour-ClaudeCode@24hour-ClaudeCode` 是 `enabled`。

装完**重启 Claude Code**(`/exit` 退出再 `claude` 进来),让 plugin 的 hook 加载进来。

> **为什么是"全局"?** Plugin 代码装在 `~/.claude/plugins/...`,但激活是按项目自动判断的。你不需要每个 repo 都装一次。

### 第 2 步 —— Onboard 你的 repo(每个 repo 一次,**在 main 分支跑**)

> ⚠️ **必须在 main 主 checkout 跑 setup,不能在 worktree 里跑。** setup 会把 workflow YAML(`.github/workflows/claude*.yml`)commit 到默认分支 —— GitHub Actions 只有在 workflow 已经在默认分支上时才能给它授信,所以必须先落到 main。如果你在 worktree 里跑 setup,plugin 会提示你切回 main。

```bash
cd ~/your-repo
git checkout main            # 确保在 main,不要在 feature 分支
claude                       # 开 Claude Code session
```

Session 打开后,plugin 会自动检测到"onboarding 没完成"并提示你。然后跑:

```
/24hour-ClaudeCode:setup
```

向导帮你搞定剩下的一切,每一步都问你确认,**没你点头不会动手**:

1. 验证 `git`、`gh`、`claude` CLI 都装好且已登录(且 `workflow` scope 已有)
2. 浏览器打开 GitHub → 你把 Claude 审核机器人装到这个 repo
3. 用你的 Claude 订阅生成 OAuth token → 写入 GitHub 的 `CLAUDE_CODE_OAUTH_TOKEN` secret
4. 读你的项目,自动识别 test / lint / build 命令
5. 问你:"用哪个 AI 来审 PR?Claude / OpenAI Codex / 两个都要?"
6. 按你项目的特点生成 workflow YAML → **commit 并 push 到 main**
7. 写入 `.claude/24hour-ClaudeCode.config.json`(你的本地可调参数)
8. 跑健康检查,确认一切就绪

**然后在 GitHub 上手动开一项配置**:Settings → General → ☑️ **Allow auto-merge**(没开的话,PR 永远不会在 CI 通过后自动合)。

✅ 这个 repo 从此**不再需要重新 setup**。后续你开的每个 worktree 都会自动继承这套配置。

### 第 3 步 —— 开一个 feature(每个 feature 一次,在 worktree 里干)

```bash
git worktree add ../my-feature -b feat/my-feature
cd ../my-feature
claude
```

Plugin 自动检测:✓ 在 worktree 里、✓ main 已 onboard → **当前 worktree 的运行时已激活**。不需要重跑 setup。

接下来,让 Claude 干活,plugin 全自动接管:

- 每次代码改动触发自动 commit 流水线(commit → push → draft PR)
- PR 自动进入 review(Claude 或 Codex,看你之前选的)
- 如果 review 或 CI 失败,plugin 把具体反馈喂给 Claude,Claude 自动改 —— 最多重试 5 轮
- 全绿了,plugin 开启 auto-merge,等 PR 合并
- 完事。从你的"在报表页加个 CSV 导出"到"PR 已合并",整个过程不用敲 `git`,不用点 "merge"。

> **为什么用 worktree?** 它给每个分支一个独立目录,所以 plugin 只在专门的 feature 目录里自动 commit —— 你的主目录始终保持干净、完全手动。Plugin **只在 worktree 里激活**,在主目录里完全静默。

---

## 常见疑问 FAQ

**它会不会帮我 commit 不该 commit 的东西?**
不会。它只 commit 你这次会话里实际改过的文件。`migrations/`、`.env.production`、`infra/`、`**/secrets/**` 这些敏感路径是默认禁止的 —— plugin 拒绝自动 commit 这些,会先问你要授权。

**审核要是一直失败怎么办?**
最多自动改 5 轮。还过不去就会自动停下来告诉你哪里有问题,你接手处理。

**我想手改一下文件,但不想被自动 commit,怎么办?**
两个选项:
- 跑 `/24hour-ClaudeCode:disable` 暂停 plugin → 改完文件 → `/24hour-ClaudeCode:enable` 重新启用
- 或者在主目录(不是 worktree)里改。plugin 只在 worktree 里激活

**它会不会污染我的主分支?**
不会。它拒绝 push 到 `main` / `master` / `develop` / `staging` 这种受保护的分支。必须切到 feature 分支才会动。

**怎么看它现在在干啥?**
跑 `/24hour-ClaudeCode:status`,会展示当前的 PR、改了几轮、有没有警告。

**自动审核太严 / 太松,能调吗?**
能。改 `.claude/24hour-ClaudeCode/review-prompt.md` 文件 —— 那是个大白话写的文件,告诉审核机器人重点看什么。改完下个 PR 自动生效,不需要重新 setup。

**怎么卸载?**
```
/plugin uninstall 24hour-ClaudeCode
```
这会卸 plugin。`.github/workflows/` 里的 workflow 文件和 GitHub Secrets 里的 API token 不会动 —— 想彻底清干净,你手动删那两处即可。

---

## 排查问题

| 现象 | 怎么办 |
|---|---|
| "它好像卡住了" | 跑 `/24hour-ClaudeCode:status`。如果卡了超过 2 分钟,试试 `/24hour-ClaudeCode:clear-lock` |
| "它推不上代码" | 检查 `gh auth status`,需要的话重新登录 |
| "它说闭环达到上限了" | plugin 试了 5 次都没让 CI/review 通过。看它的提示信息,自己接手修 |
| "审核没跑起来" | 确认 GitHub 上的 "Claude" App 装到了你的 repo,且 `CLAUDE_CODE_OAUTH_TOKEN` 这个 secret 存在。重跑 `/24hour-ClaudeCode:setup` 即可 |
| "我想从头来过" | `/24hour-ClaudeCode:setup` 重跑是安全的 —— 不会破坏已有配置 |

---

## 个性化(可选)

setup 完成后,你的项目里会多出这两个可调的文件:

```
your-project/
├── .claude/24hour-ClaudeCode.config.json     ← 主配置
└── .claude/24hour-ClaudeCode/review-prompt.md ← 审核机器人的关注点
```

最常改的几样:

| 你想要的 | 怎么改 |
|---|---|
| 让审核机器人专注某个方面(比如只审安全) | 改 `.claude/24hour-ClaudeCode/review-prompt.md` |
| 多给几次重试机会再放弃 | 配置文件里调 `repair.max_iterations`(默认 5) |
| 加一个路径"永远不要自动 commit" | 配置文件 `danger_paths` 数组里加上 glob |
| commit 前不跑测试(更快但风险大) | 配置文件 `checks.run_local_tests` 改成 `false` |

---

## Slash 命令

都是逃生通道,正常用不到。

| 命令 | 作用 |
|---|---|
| `/24hour-ClaudeCode:setup` | (重)跑 setup 向导 |
| `/24hour-ClaudeCode:status` | 看现在在干什么 |
| `/24hour-ClaudeCode:retry` | 卡了之后强制重启自动闭环 |
| `/24hour-ClaudeCode:disable` | 暂停 plugin |
| `/24hour-ClaudeCode:enable` | 暂停后恢复 |
| `/24hour-ClaudeCode:clear-lock` | 最后手段:清掉卡死的 lock |

---

## 安装前要准备的东西

- Claude Pro 或 Max 订阅
- 一个 GitHub 账号
- 装好 GitHub CLI(`gh`)并已登录
- Git 版本 ≥ 2.20(支持 worktree)

就这些。不需要 Node.js、Python 或其他运行时。

---

## 想了解它具体怎么工作?

这个 plugin 用的是 Claude Code 的 **hook** 机制 —— 在特定时刻自动运行的小脚本(会话开始时、Claude 编辑文件后、Claude 结束一回合时)。

如果你好奇底层架构 —— 哪些 hook 在什么时候触发、闭环怎么迭代、运行时状态机怎么走 —— 看 **[FLOW.zh-CN.md](FLOW.zh-CN.md)**([English version](FLOW.md))。

---

## License

MIT
