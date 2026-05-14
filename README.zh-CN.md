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

推荐用 `/goal` 开始一个完整功能:

> **你:** `/goal 在报表页加个 CSV 导出功能。`
>
> *(Claude 修改、验证,并一直工作到 goal 达成为止。)*
>
> **Claude:** "Goal 已完成。我已打开 PR #142,正在等待 Claude Code Action review。"
>
> *(两分钟后)*
>
> **Claude:** "✅ PR #142 已合入:github.com/your-org/your-repo/pull/142"

万一出了问题,闭环也会自动处理:

> **Claude:** "审核发现一个 bug —— 新的 `/export` 接口没处理空数据集的情况(48 行)。我来修一下。"
>
> *(Claude 修好了。review 重跑。通过。)*
>
> **Claude:** "✅ PR #142 已合入。"

整个过程你**没敲过** `git commit`、`gh pr create`,**没点过**"merge"按钮。Plugin 全帮你做了。

---

## 设计原则

Runtime 遵循一组 skill-first 原则:

- Hook 只负责触发或注入上下文。
- `review-loop` skill 承担 PR 主流程。
- Script 只用于 version 同步和确定性的 Superset 文件安装。
- 同一个 Claude Code session 在同一个 worktree 里修 review feedback。
- GitHub Claude Code Action 只负责 review,不负责修复。
- missing、stale、ambiguous 的 review 输出绝不能当作 pass。

---

## 什么时候用这个 plugin

✅ **适合的场景:**
- 你在一个真实的 GitHub 项目上工作
- 你希望 Claude Code 把整个 feature 开发到上线一气呵成,不用每一步都催它
- 你能接受 review-loop skill 在 Goal 准备好后帮你 commit、push、开 PR、开启 auto-merge

❌ **暂时不适合的场景:**
- 你在做探索性工作,还不想启动 review loop
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
                          onboarding skill       │  在默认分支上
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
| **要么已有 GitHub repo,要么准备建一个新的** | 在该文件夹里 `gh repo view` 能跑通 | onboarding skill 会帮你确认 repo 路径 |

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
> ls .git                 # 这个目录应该存在(没有的话 onboarding skill 会先停下来让你确认)
> ```

> ⚠️ **为什么必须是"主目录":** setup 会把 `.github/workflows/claude*.yml` commit 到你的 repo。GitHub Actions 只有当这些文件存在于**默认分支**上时才能被授信运行,所以必须先落到默认分支。在 worktree 里跑 setup,plugin 会拒绝并提示你回主目录。

确认你在 repo 的默认分支上:

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

`github-actions-onboarding` skill 会做剩下的流程。工作流由 skill 负责,直接运行 `gh`/`git` 命令;不再使用 onboarding helper script:

1. **验证前置条件** —— `git`、`gh`、`claude` CLI 已装好,gh 有 `workflow` scope,git 身份已配。
2. **定位你的 repo** —— 三种情况:
   - ✅ 已经连好 GitHub repo → 直接继续。
   - ⚠️ 本地有 git repo 但**没接 GitHub 远端** → skill 会和你确认最短安全路径,你选择后可以运行 `gh repo create`。
   - ⚠️ 当前目录根本不是 git repo → skill 先停下来,让你确认 repo 初始化路径。
3. **验证 Claude 审核机器人已安装** —— 通过 `check_suites` 侧信道检测(常见情况:你 GitHub 账号已经"全 repo 装"过,直接跳过)。没检测到才会给你 install 页面。
4. **设置 `CLAUDE_CODE_OAUTH_TOKEN` secret** —— skill **无法**自动跑这步(`claude setup-token` 是浏览器 OAuth 交互、`gh secret set` 是 paste 提示,都需要你的终端)。它会检测 repo secret,也会检测对当前 repo 可见的 org secret。缺失时,skill 会同时打印两种配置方式:
   ```bash
   # 在你的终端里跑 —— 千万不要把 token 粘到聊天框
   claude setup-token

   # 推荐:Organization 级 secret,一次覆盖整个 org
   gh secret set CLAUDE_CODE_OAUTH_TOKEN --org <org> --visibility all

   # 可选:Organization 级 selected repos
   gh secret set CLAUDE_CODE_OAUTH_TOKEN --org <org> --repos <repo>

   # 备选:没有 Organization 权限/方案时,只给当前 repo 设置
   gh secret set CLAUDE_CODE_OAUTH_TOKEN -R <owner>/<repo>
   ```
   然后 skill 会用 `gh api` / `gh secret list` 直接验证 secret。
5. **安装 Claude review workflow YAML** —— 从 plugin templates 复制。只有当你明确要求 Codex 或两者都要时,才会额外安装 Codex review。
6. **提交并推送 onboarding 文件** 到 repo 默认分支。
7. **写入** `.claude/24hour-ClaudeCode.config.json`(你的本地可调参数)。
8. **健康检查** —— 确认一切就绪。

Onboarding 完成后,**在 GitHub 网页上做一件事**:打开你的 repo → Settings → General → ☑️ **Allow auto-merge**。没开的话,PR 永远不会在 review 通过后自动合。

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

让 Claude 开始干活。**推荐方式:** 用 Claude Code `/goal` 模式,这样 plugin 会等到目标真正完成后才发 PR:

```text
/goal 在报表页加个 CSV 导出功能。
```

非 Goal 普通 prompt 也支持,适合很小、单回合的修改。但完整 feature 推荐用 Goal 模式,因为它会阻止中间状态提前创建 PR。

Plugin 会接管后续流程:

- 原生 `/goal` 达成后,或非 Goal 回合在实现后准备停止时,Stop prompt 会让同一个 Claude 会话继续,并要求它使用 `review-loop` skill
- `review-loop` skill 负责 commit、push、创建或更新 PR,并等待 GitHub Claude Code Action review
- PR 自动进入 review(Claude 或 Codex,看你之前选的)
- 如果 Claude Code Action review 失败,plugin 把具体反馈喂给 Claude,Claude 在同一个 session 里继续改。外部 CI 默认不生成、不要求,除非你显式设置 `github.require_external_ci=true`。
- 全绿了,plugin 开启 auto-merge,等 PR 合并
- 完事。从「在报表页加个 CSV 导出」到「PR 已合并」,整个过程不用敲 `git`,不用点 "merge"。

PR 合并后,可选清理:

```bash
cd ~/Projects/my-app                  # 回主目录
git pull                              # 拉刚合的 commit 到本地
git worktree remove ../my-feature     # 删 worktree
```

> **为什么用 worktree?** 每个 worktree 是独立目录、独立分支。Plugin **只在 worktree 里激活**,所以你主目录永远干净 —— 你照样可以在主目录用 Claude Code 手动改东西、做探索、做只读工作,主目录里不会启动 review loop。

---

## 常见疑问 FAQ

**它会不会帮我 commit 不该 commit 的东西?**
不会。`review-loop` skill 只 commit 当前任务需要的文件。`migrations/`、`.env.production`、`infra/`、`**/secrets/**` 这些敏感路径默认在 `danger_paths` 里,提交前必须格外小心并确认有明确授权。

**审核要是一直失败怎么办?**
当 review 证据缺失、过期、含糊,或需要人判断时,它会报告明确 blocker,然后你接手处理。

**我想手改一下文件,但不想启动 review loop,怎么办?**
两个选项:
- 跑 `/24hour-ClaudeCode:disable` 暂停 plugin → 改完文件 → `/24hour-ClaudeCode:enable` 重新启用
- 或者在主目录(不是 worktree)里改。plugin 只在 worktree 里激活

**它会不会污染我的主分支?**
不会。它拒绝 push 到 `main` / `master` / `develop` / `staging` 这种受保护的分支。必须切到 feature 分支才会动。

**怎么看它现在在干啥?**
跑 `/24hour-ClaudeCode:status`,会展示 config 状态、git status,以及当前分支的 PR。

**自动审核太严 / 太松,能调吗?**
能。review prompt **直接写在 workflow YAML 里**。改 `.github/workflows/claude-code-review.yml`(以及 `codex-review.yml` 如果用 Codex)的 `prompt:` 块,commit、push,下个 PR 自动生效,不需要重 setup。

**怎么更新到最新版本?**
```bash
claude plugin marketplace update 24hour-ClaudeCode        # 从 GitHub 刷新 marketplace 元数据
claude plugin update 24hour-ClaudeCode@24hour-ClaudeCode  # 安装最新版本
```
更新完**重启 Claude Code**(`/exit` 退出再 `claude` 进来),让新的 hook 加载进来。`claude plugin list` 可以查看当前已装版本。注意 plugin 更新**不会**改你项目 `.github/workflows/` 下的 workflow YAML —— 想重新安装当前模板,跑 `/24hour-ClaudeCode:setup` 即可。

**怎么卸载?**
```
/plugin uninstall 24hour-ClaudeCode
```
这会卸 plugin。`.github/workflows/` 里的 workflow 文件和 GitHub Secrets 里的 API token 不会动 —— 想彻底清干净,你手动删那两处即可。

---

## 排查问题

| 现象 | 怎么办 |
|---|---|
| "它好像卡住了" | 跑 `/24hour-ClaudeCode:status`,看 config、git status 和当前 PR |
| "它推不上代码" | 检查 `gh auth status`,需要的话重新登录 |
| "它报告 blocker" | 看 blocker,修根因,然后在同一个 worktree 继续 |
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
| 调整 review 等待时间 | 配置文件里调 `repair.review_loop_timeout` |
| 加一个路径"提交前必须格外小心" | 配置文件 `danger_paths` 数组里加上 glob |
| commit 前不跑测试(更快但风险大) | 配置文件 `checks.run_local_tests` 改成 `false` |

---

## Slash 命令

都是逃生通道,正常用不到。

| 命令 | 作用 |
|---|---|
| `/24hour-ClaudeCode:setup` | 调用 onboarding skill |
| `/24hour-ClaudeCode:status` | 看现在在干什么 |
| `/24hour-ClaudeCode:disable` | 暂停 plugin |
| `/24hour-ClaudeCode:enable` | 暂停后恢复 |

---

## 安装前要准备的东西

- Claude Pro 或 Max 订阅
- 一个 GitHub 账号
- 装好 GitHub CLI(`gh`)并已登录
- Git 版本 ≥ 2.20(支持 worktree)

就这些。不需要 Node.js、Python 或其他运行时。

---

## 想了解它具体怎么工作?

这个 plugin 用的是 Claude Code 的 **hook** 机制。SessionStart 仍是 command hook,因为 Claude Code 官方不支持在 SessionStart 用 prompt hook;Stop 路由是 prompt hook,而 `review-loop` skill 自己也有 skill-scoped Stop prompt hook。

如果你好奇底层架构 —— 哪些 hook 在什么时候触发、为什么 Stop 改成 prompt-based、为什么主流程放在 skill 里 —— 看 **[FLOW.zh-CN.md](FLOW.zh-CN.md)**([English version](FLOW.md))。

---

## License

MIT
