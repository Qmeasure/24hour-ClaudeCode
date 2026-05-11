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

整个流程**就 3 步**:每台机器一次、每个 repo 一次、每个 feature 一次。配好以后,你每开发一个新 feature,只要 `git worktree add` 一下,后面 PR 全自动跑完。

```
第 1 步(每台机器一次)→ 安装 plugin            ─┐  任意终端、任意目录
                                                 │
第 2 步(每个 repo 一次)→ Onboard                │  在你项目的「主目录」里
                          ↓                      │  (原始 git checkout)
                          setup wizard           │  在 main 分支上
                                                 │
第 3 步(每个 feature) → 开一个 worktree        │  在你项目「旁边」的新目录
                          改代码 → 自动 PR     ─┘  (同级 sibling dir)
```

### 开工前 —— 确保你有这些东西

| 检查项 | 怎么验证 | 没有的话 |
|---|---|---|
| Claude Code CLI 装好 | `claude --version` | 从 [code.claude.com/docs](https://code.claude.com/docs/) 装 |
| GitHub CLI 装好并登录 | `gh auth status` | `gh auth login --scopes workflow` |
| Git 身份配好 | `git config --global user.name` | `git config --global user.name "..."` + `user.email` |
| **一个项目文件夹** | 你知道它的完整路径,例如 `~/Projects/my-app` | 开工前先建好一个 |
| **要么已有 GitHub repo,要么准备建一个新的** | 在该文件夹里 `gh repo view` 能跑通 | setup 向导会帮你建 |

### 第 1 步 —— 装 plugin(一次性,全局,任意终端跑)

你可以在任何终端、任何目录里跑。Plugin 装到你的 home 目录,对这台机器上**所有项目自动生效**。

```bash
# 任意终端里:
gh auth login --scopes workflow         # 确保 gh 有 workflow scope
claude plugin marketplace add Qmeasure/24hour-ClaudeCode
claude plugin install 24hour-ClaudeCode@24hour-ClaudeCode
```

确认:`claude plugin list` 看到 `24hour-ClaudeCode@24hour-ClaudeCode` 是 `enabled`。

装完**重启 Claude Code**(`/exit` 退出再 `claude` 进来),让 plugin 的 hook 加载进来。

> Plugin 代码存在 `~/.claude/plugins/...`。装一次,不需要每个 repo 都装一次。

### 第 2 步 —— Onboard 你的 repo(每个 repo 一次,**在项目主目录里跑**)

> 📍 **在哪里跑:** 终端 cd 到「你项目的主目录」—— 也就是 `.git` 目录所在的原始 checkout 目录。不是 worktree,不是其他地方。
>
> 例子:
> ```bash
> cd ~/Projects/my-app    # ← 改成你自己的项目路径
> pwd                     # 确认在对的位置
> ls .git                 # 这个目录应该存在(没有的话向导会引导你建)
> ```

> ⚠️ **为什么必须是"主目录":** setup 会把 `.github/workflows/claude*.yml` commit 到你的 repo。GitHub Actions 只有当这些文件存在于**默认分支**上时才能被授信运行,所以必须先落到 main。在 worktree 里跑 setup,plugin 会拒绝并提示你回主目录。

确认你在 main(或你 repo 的默认分支)上:

```bash
git checkout main         # 或者 git checkout master / 你 repo 默认的那个分支
```

然后在这个目录开 Claude Code session 跑 setup:

```bash
claude
```

```
/24hour-ClaudeCode:setup
```

向导帮你做剩下的一切。**每步都问你确认,没你点头不会动手**:

1. **验证前置条件** —— `git`、`gh`、`claude` CLI 已装好,gh 有 `workflow` scope,git 身份已配。
2. **定位你的 repo** —— 三种情况:
   - ✅ 已经连好 GitHub repo → 直接继续。
   - ⚠️ 本地有 git repo 但**没接 GitHub 远端** → 向导帮你跑 `gh repo create`(它会问你 repo 名 / 公开私有 / 是否 push)。选"是"一步到位。
   - ⚠️ 当前目录根本不是 git repo → 向导帮你 `git init -b main` + 创建首个 commit(你得至少有一个文件可 commit,加个 README 就够了)。
3. **验证 Claude 审核机器人已安装** —— 通过 `check_suites` 侧信道自动检测(常见情况:你 GitHub 账号已经"全 repo 装"过,直接跳过)。没检测到才会打开 install 页面让你装。
4. **设置 `CLAUDE_CODE_OAUTH_TOKEN` secret** —— 向导**无法**自动跑这步(`claude setup-token` 是浏览器 OAuth 交互、`gh secret set` 是 paste 提示,都需要你的终端)。向导会**打印精确的 2 条 CLI 命令**让你在终端跑,跑完按 Enter 回向导,自动验证。向导给你的具体命令:
   ```bash
   # 在你的终端里跑 —— 千万不要把 token 粘到聊天框
   claude setup-token                                              # OAuth → 终端打印 sk-ant-oat01-...
   gh secret set CLAUDE_CODE_OAUTH_TOKEN -R <owner>/<repo>          # 在 paste 提示里粘 token
   ```
   然后按 Enter 回向导,它会用 `gh api repos/<repo>/actions/secrets/CLAUDE_CODE_OAUTH_TOKEN` 精确探针验证(200=已设,404=没设)。
5. **自动识别** test / lint / build 命令。
6. **询问** 哪个 AI 来审 PR:Claude / OpenAI Codex / 两个都要。
7. **生成 workflow YAML** —— 按你项目特点定制 → commit + push 到 `main`。
8. **写入** `.claude/24hour-ClaudeCode.config.json`(你的本地可调参数)。
9. **健康检查** —— 确认一切就绪。

向导跑完后,**在 GitHub 网页上做一件事**:打开你的 repo → Settings → General → ☑️ **Allow auto-merge**。没开的话,PR 永远不会在 CI 通过后自动合。

✅ **一次到位。** 这个 repo 配好了。后续你开的每个 worktree 都自动继承这套配置 —— 不需要再跑 setup。

### 第 3 步 —— 开一个 feature(每个 feature 一次,在「项目旁边」的 worktree 里干)

> 📍 **在哪里跑:** `worktree add` 还是在你项目的主目录里跑;新 worktree 会被建成「同级 sibling 目录」,然后你 cd 进去开**新的** Claude session。

```bash
# 还在 ~/Projects/my-app(你的主目录)里:
git worktree add ../my-feature -b feat/my-feature
#                ↑ 创建 ~/Projects/my-feature,新分支

cd ../my-feature      # 进 worktree 目录
claude                # ← 在这里开新 Claude session(不要复用主目录那个)
```

> 🔑 **关键:** 必须在 worktree 目录**重新开** Claude Code session。SessionStart hook 一个会话只跑一次,所以 plugin 的 runtime 只在 Claude 在 worktree 目录"启动时"才会激活。如果你只是把已有 session `cd` 过来,runtime 不会生效。

Claude 在 `../my-feature` 里启动后,plugin 自动检测:
- ✓ 在 worktree 里
- ✓ main 已 onboard(配置自动继承)
- → **当前 worktree 的 runtime 已激活**,不需要重做 setup。

让 Claude 开始干活,plugin 全自动接管:

- 每次代码改动触发自动 commit 流水线(commit → push → draft PR)
- PR 自动进入 review(Claude 或 Codex,看你之前选的)
- 如果 review 或 CI 失败,plugin 把具体反馈喂给 Claude,Claude 自动改 —— 最多重试 5 轮
- 全绿了,plugin 开启 auto-merge,等 PR 合并
- 完事。从「在报表页加个 CSV 导出」到「PR 已合并」,整个过程不用敲 `git`,不用点 "merge"。

PR 合并后,可选清理:

```bash
cd ~/Projects/my-app                  # 回主目录
git pull                              # 拉刚合的 commit 到本地
git worktree remove ../my-feature     # 删 worktree
```

> **为什么用 worktree?** 每个 worktree 是独立目录、独立分支。Plugin **只在 worktree 里激活**,所以你主目录永远干净 —— 你照样可以在主目录用 Claude Code 手动改东西、做探索、做只读工作,主目录里不会触发任何自动 commit。

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
能。review prompt **直接写在 workflow YAML 里**。改 `.github/workflows/claude-code-review.yml`(以及 `codex-review.yml` 如果用 Codex)的 `prompt:` 块,commit、push,下个 PR 自动生效,不需要重 setup。这个 prompt 在 onboarding 时已经按你 repo 的实际结构(top-level 目录、入口文件、敏感路径、repo 简介)定制好了。

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

setup 完成后,你的项目里会多出这几个可调的文件:

```
your-project/
├── .claude/24hour-ClaudeCode.config.json              ← 主配置
└── .github/workflows/claude-code-review.yml           ← review prompt(在 prompt: 块里)
└── .github/workflows/codex-review.yml (如有 codex)    ← codex 的 review prompt
```

最常改的几样:

| 你想要的 | 怎么改 |
|---|---|
| 让审核机器人专注某个方面(比如只审安全) | 改 `.github/workflows/claude-code-review.yml` 的 `prompt:` 块 |
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
