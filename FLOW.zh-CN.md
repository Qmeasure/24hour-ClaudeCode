[English](FLOW.md) | **中文**

# 24hour-ClaudeCode — 完整运行时流程

本文档是 plugin 运行时行为的唯一权威说明。详细列出**每一个 hook**、其**触发条件**,以及从项目安装到 PR 合入的**完整事件闭环**。

---

## Hook 总览

| Hook | 触发条件 | 脚本 | 超时 | 职责 |
|---|---|---|---|---|
| `SessionStart` | 会话启动、`/clear`、自动压缩(matcher: `startup\|clear\|compact`) | `hooks/bootstrap.sh` | 10 秒 | 探测环境;注入运行时契约或 onboarding 指令 |
| `PostToolUse` | 每次 `Edit` / `Write` / `MultiEdit` 工具调用之后(matcher: `Edit\|Write\|MultiEdit`) | `hooks/post-tool-use.sh` | 5 秒 | 轻量标记 —— `touch <runtime>/dirty`,不做实质工作 |
| `Stop` | 回合边界 —— 主 agent 结束响应时 | `hooks/stop.sh` | 900 秒 | 主工作者 —— 拥有完整的 commit/push/PR/poll/decide 闭环 |

**为什么这样切分:** `PostToolUse` 在每次工具调用后触发(粒度太细,不是"做完一批工作再 commit");`Stop` 每个回合触发一次 —— 正是"Claude 完成一组连贯编辑"应该产生 commit 的时机。marker 模式让 `Stop` 在纯聊天回合可以快速跳过。

Hook 输出格式(参 Claude Code 官方规范):

```jsonc
// 信息性 —— Claude 可以正常停止
{"hookSpecificOutput": {"hookEventName": "Stop", "additionalContext": "<text>"}}

// 阻断停止 —— `reason` 作为下一回合的上下文喂回 Claude
{"decision": "block", "reason": "<text>"}
```

---

## Phase 0 — 安装 & Onboard(每个 repo 一次性)

由用户手动触发,不是 hook 驱动。

```
┌─ 用户在任意项目里运行 ───────────────────────────────────────────────┐
│  /plugin marketplace add Qmeasure/24hour-ClaudeCode                 │
│  /plugin install 24hour-ClaudeCode@24hour-ClaudeCode                 │
└─────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
              Plugin 落地到 <project>/.claude/plugins/24hour-ClaudeCode/
                              │
                              ▼
┌─ 用户运行 ──────────────────────────────────────────────────────────┐
│  /24hour-ClaudeCode:setup                                           │
└─────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
   scripts/configure-actions.sh:
     1. 验证 gh / claude / git 已装且已登录(workflow scope)
     2. 通过 `scripts/check-claude-app.sh` 自动检测 Claude App 是否装在该 repo
        (check_suites 侧信道:`gh api repos/.../commits/.../check-suites` 用
        user-PAT 可调,返回的列表包含每个装在 repo 且有 checks:write 权限的 App。
        若 App.slug == "claude" && App.owner == "anthropics",即已安装。)
        没检测到才打开 https://github.com/apps/claude 让用户装,等待回来重检。
     3. 通过 `scripts/check-secret.sh` 精准探针验证 `CLAUDE_CODE_OAUTH_TOKEN`
        (`gh api repos/.../actions/secrets/<NAME>` 返回 200 = 已设,404 = 未设)。
        未设时,脚本**不会**自动跑 `claude setup-token` 或 `gh secret set` —
        这两个命令都是交互式的(浏览器 OAuth + 终端粘贴),脚本驱动不了。改为
        在 box 框里打印精确的 2 条 CLI 命令让用户在自己终端跑,跑完按 Enter
        回脚本自动重新验证。
     4. 跑 scripts/detect-project.sh:
          • 项目类型(node/python/go/rust/...)
          • base 分支
          • test/lint/typecheck/build 命令
          • monorepo 标志、仓库体量
          • 风格指南(CLAUDE.md、AGENTS.md、...)
          • 敏感路径(migrations/、infra/、.env.production、...)
     5. 询问 provider:claude | codex | both
        • 若选 codex/both:确保 OPENAI_API_KEY secret
     6. 探测 .github/workflows/ 是否已有 CI workflow
        • 若没有:询问是否生成 ci.yml
     7. scripts/render-workflows.sh --provider <choice> [--include-ci]:
          • 渲染 1–3 个 workflow YML(claude-code-review.yml、claude.yml、
            codex-review.yml、ci.yml —— 组合按选择决定)
          • 渲染 .claude/24hour-ClaudeCode/review-prompt.md(外置 prompt)
     8. git add → commit → push(每次 push 前等用户确认)
     9. 按模板生成 .claude/24hour-ClaudeCode.config.json
    10. scripts/runtime-state.sh init → state.json,mode="idle"
    11. scripts/check-actions.sh -v(最后健康检查)
                              │
                              ▼
              ✅ 仓库准备好。自动闭环已启用。
```

Onboard 是幂等的 —— 重复跑 `/24hour-ClaudeCode:setup` 是安全的。

---

## Phase 1 — Session 打开

**触发条件:** 每次 Claude Code 会话启动、每次 `/clear`、每次自动压缩。
**Hook:** `SessionStart`,matcher 为 `startup|clear|compact`。

```
┌─ SessionStart hook 触发 → bootstrap.sh ─────────────────────────────┐
│                                                                     │
│  通过 scripts/resolve-config-path.sh 解析有效的 config 路径:         │
│  ├─ <worktree>/.claude/24hour-ClaudeCode.config.json 存在? 用它    │
│  └─ 否则若在 worktree 内 → 回退到 main checkout 的 config            │
│     (用 `git worktree list --porcelain` 定位 main)。这是新 worktree │
│     自动继承 main onboarding 配置的核心机制,无需重新 onboard。      │
│                                                                     │
│  读取解析后的 config:                                                │
│  ├─ enabled=false → 输出 "disabled" 提示,exit 0                     │
│  └─ enabled=true → 继续                                             │
│                                                                     │
│  探测环境:                                                          │
│  ├─ 是否在 worktree 内?(git rev-parse --git-dir vs --git-common-dir)│
│  ├─ 是否在受保护分支?(main / master / develop / staging / ...)     │
│  ├─ gh 是否已登录?                                                  │
│  ├─ Claude Code Actions 是否已部署?(.github/workflows/claude*.yml) │
│  └─ config 是否存在?(走上面解析路径——main 有就算 TRUE)             │
│                                                                     │
│  按探测结果分支(顺序很关键—— onboarding 检测在 dormant 之前):      │
│  ├─ Onboarding 不完整 → 注入 github-actions-onboarding skill        │
│  │     附带情景化位置提示:                                          │
│  │       • 在 main 上:"在这里跑 /24hour-ClaudeCode:setup"           │
│  │       • 在 worktree 里:"回 main checkout 跑 setup"               │
│  │     用 <EXTREMELY-IMPORTANT> 包裹                                │
│  ├─ 不在 worktree → 输出 "dormant" 提示(一行),exit 0              │
│  ├─ 受保护分支 → 输出 "dormant" 提示(一行),exit 0                 │
│  └─ 健康(在 worktree 内 + 已 onboard)→ 注入                       │
│     using-24hour-ClaudeCode/SKILL.md(运行时契约)                   │
│     用 <EXTREMELY-IMPORTANT> 包裹                                   │
│                                                                     │
│  若 <runtime>/state.json 不存在,初始化为 mode="idle"。              │
│  写 <runtime>/.gitignore 内容为 `*`,确保 runtime 文件永不进入 diff。│
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
                stdout 输出 JSON:
                {"hookSpecificOutput": {
                  "hookEventName": "SessionStart",
                  "additionalContext": "<runtime contract>"
                }}
                              │
                              ▼
              Claude 读到运行时契约,准备就绪。
```

---

## Phase 2 — Claude 改代码

**触发条件:** Claude 调用 `Edit`、`Write` 或 `MultiEdit`。
**Hook:** `PostToolUse`,matcher 为 `Edit|Write|MultiEdit`。

```
┌─ 每次 Edit/Write/MultiEdit 后,PostToolUse hook 触发 ────────────────┐
│                                                                     │
│  post-tool-use.sh(5 行):                                           │
│    mkdir -p <runtime>                                               │
│    touch <runtime>/dirty                                            │
│    exit 0                                                           │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

`PostToolUse` 的全部职责就是这些。无 JSON 输出。无 commit。dirty 标记是给即将触发的 `Stop` hook 一个快速提示("这一回合有工具调用改了文件")。`git diff` 仍是真值来源。

---

## Phase 3 — 回合结束,闭环运行

**触发条件:** Claude 完成响应(回合边界)。
**Hook:** `Stop`(无 matcher;每个回合结束都触发)。

这是主工作者。它是 **mode-aware** —— `state.json.mode` ∈ {`idle`, `waiting_for_preflight_merge`, `waiting_for_checks`, `ready_for_rework`, `merged`}。

```
┌─ Stop hook 触发 → stop.sh ──────────────────────────────────────────┐
│                                                                     │
│  前置检查:                                                          │
│  ├─ enabled=false  → 静默 exit 0                                    │
│  ├─ 不在 worktree → 静默 exit 0                                     │
│  └─ 获取 <runtime>/lock                                             │
│       └─ 若已被前一个 Stop 持有 → 静默 exit 0                       │
│                                                                     │
│  从 <runtime>/state.json 读 mode(默认:idle)                       │
│  读 dirty 标记和 git diff 状态                                      │
│                                                                     │
│  ┌─ 按 mode 分发 ──────────────────────────────────────────────────┐│
│  │                                                                ││
│  │  Case A — mode ∈ {idle, ready_for_rework} 且 diff 非空         ││
│  │           [PRE-PR 分支]                                         ││
│  │  ─────────────────────────────────────────────────────────────  ││
│  │  1. detect-changes.sh —— 文件分类(code / lock / docs /         ││
│  │       secrets / workflow / danger)                              ││
│  │     └─ buckets.workflow 非空 且                                 ││
│  │        repair.allow_workflow_in_pr ≠ true →                     ││
│  │           1a. 若 .github/workflows/* 在 已提交但未 push 的       ││
│  │               历史中 → 返回 decision:block,要求用户手动         ││
│  │               git reset/amend(stop:committed_workflow_changes)。 ││
│  │           1b. 否则调用 split-workflow-pr.sh:                    ││
│  │                 • 保存 workflow 文件内容                         ││
│  │                 • 在用户分支上把 workflow 文件还原到 base 版本   ││
│  │                 • 创建 preflight/<branch>-workflow-<ts>          ││
│  │                   分支(基于 origin/<base>)                     ││
│  │                 • 仅应用 workflow 变更;commit + push           ││
│  │                 • gh pr create + gh pr merge --auto --squash    ││
│  │                 • 切回用户分支                                   ││
│  │           1c. state.mode = waiting_for_preflight_merge          ││
│  │               state.preflight_pr = N                            ││
│  │               输出 "📦 已自动拆分为 preflight PR #N",exit。     ││
│  │     └─ 任一路径命中 danger_paths → 返回 decision:block          ││
│  │        reason = "edit touches sensitive path; need approval"   ││
│  │  2. check-stop-conditions.sh —— 验证 max_iterations、分支      ││
│  │     保护、gh 登录、diff 体积                                    ││
│  │     └─ 返回 stop:* token → 输出 info + 调用                     ││
│  │        failure-escalation,exit 0                               ││
│  │  3. 跑 config.checks.commands(lint/typecheck/test)fail-fast   ││
│  │     └─ 任一失败 → 返回 decision:block,reason 含                 ││
│  │        "local check failed: <最后 50 行>"                       ││
│  │  4. auto-commit.sh —— stage 非 danger 文件,                    ││
│  │       commit "auto: WIP on <branch> [HH:MM:SS]"(占位)         ││
│  │  5. git push -u origin <branch>                                ││
│  │  6. ensure-pr.sh —— gh pr view || gh pr create --draft --fill  ││
│  │  7. iteration 计数:                                             ││
│  │     • mode 原本是 ready_for_rework → iteration += 1             ││
│  │     • mode 原本是 idle → iteration = 1(此 PR 首次 push)        ││
│  │  8. 状态转移:                                                   ││
│  │     • mode = waiting_for_checks                                 ││
│  │     • pr_number = N                                             ││
│  │     • 清除 <runtime>/dirty                                      ││
│  │  9. 一次基线 poll-github.sh(尽力,失败也无所谓)                ││
│  │ 10. 输出 additionalContext:                                    ││
│  │     "Iteration #N。PR #M (draft) 在 <url>。CI starting。"      ││
│  │     exit 0(Claude 可以停止;下一次 Stop 接续)                  ││
│  │                                                                ││
│  ├────────────────────────────────────────────────────────────────┤│
│  │                                                                ││
│  │  Case B — mode = waiting_for_checks                            ││
│  │           [POST-PR 分支 —— POLL & DECIDE]                       ││
│  │  ─────────────────────────────────────────────────────────────  ││
│  │  1. wait-for-checks.sh --pr N --timeout=config.repair.wait_s   ││
│  │     • 返回 0:所有 check 都已到达终态                            ││
│  │     • 返回 1:超时 —— 输出 "still running" 信息,exit 0          ││
│  │  2. poll-github.sh —— 完整快照写到 <runtime>/feedback.json:    ││
│  │     • PR state + mergeStateStatus + isDraft                     ││
│  │     • 所有 checks(含 conclusion)                              ││
│  │     • 所有 reviews(state + body)                              ││
│  │     • 所有 comments(issue + 行内 review 评论)                 ││
│  │     • 失败 job 日志(每个失败 check 最后 50 行)                ││
│  │  3. decide-feedback.sh —— 应用决策矩阵:                        ││
│  │                                                                ││
│  │     ── feedback_good ──                                         ││
│  │     gh pr merge --auto --merge(或 squash/rebase 按配置)       ││
│  │     mode = "merged"                                             ││
│  │     输出 "✅ PR #N merged: <url>",exit 0                       ││
│  │                                                                ││
│  │     ── rework_required ──                                       ││
│  │     mode = "ready_for_rework"                                   ││
│  │     返回 JSON:                                                  ││
│  │       {"decision":"block",                                      ││
│  │        "reason":"PR #N feedback requires rework. Iter N+1/M。 ││
│  │                  <反馈摘要>。                                   ││
│  │                  按 rework-implementation 应用最小修改。"}     ││
│  │     ⚠ 这阻止 Claude 停止。Claude 把 `reason` 当下一回合上下文,  ││
│  │       继续编辑。                                                ││
│  │                                                                ││
│  │     ── inconclusive ──                                          ││
│  │     输出 "Polled, can't decide yet. Will retry next stop."     ││
│  │     exit 0                                                      ││
│  │                                                                ││
│  │     ── stop:max_iterations / stop:repeated_failure ──           ││
│  │     输出 STOP 消息 + 调用 failure-escalation skill              ││
│  │     exit 0                                                      ││
│  │                                                                ││
│  ├────────────────────────────────────────────────────────────────┤│
│  │                                                                ││
│  │  Case C — mode = idle,diff 为空                                ││
│  │           [纯聊天回合]                                          ││
│  │  ─────────────────────────────────────────────────────────────  ││
│  │  无事可做。释放 lock。exit 0。                                  ││
│  │                                                                ││
│  ├────────────────────────────────────────────────────────────────┤│
│  │                                                                ││
│  │  Case D — mode = merged                                         ││
│  │           [合入后清理]                                          ││
│  │  ─────────────────────────────────────────────────────────────  ││
│  │  删除 <runtime>/current-pr.json、feedback.json、dirty           ││
│  │  重置 state.json:mode="idle",iteration=0,pr_number=null      ││
│  │  exit 0                                                         ││
│  │                                                                ││
│  ├────────────────────────────────────────────────────────────────┤│
│  │                                                                ││
│  │  Case E — mode = waiting_for_preflight_merge                    ││
│  │           [Workflow 文件 preflight PR 进行中]                   ││
│  │  ─────────────────────────────────────────────────────────────  ││
│  │  gh pr view <preflight_pr> --json state                        ││
│  │     └─ MERGED → git fetch + git rebase origin/<base>;          ││
│  │       state.mode = idle, state.preflight_pr = null;            ││
│  │       FALL THROUGH 到 Case A(继续提交剩余 diff)。             ││
│  │       Rebase 冲突 → 输出 "请手动解决",exit。                   ││
│  │     └─ OPEN → 输出 "仍在等待",exit 0。                         ││
│  │     └─ CLOSED-not-merged → 输出 stop:preflight_closed,         ││
│  │       重置为 idle,调用 failure-escalation。                    ││
│  │                                                                ││
│  └────────────────────────────────────────────────────────────────┘│
│                                                                     │
│  始终(via trap):退出时释放 <runtime>/lock                         │
│  始终:在 <runtime>/last-run.json 追加事件                          │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Phase 3.5 — Workflow 自动拆分(Case A 1a–1c 详解)

**为什么:** 当 PR 修改了 `.github/workflows/*.yml` 且与 default 分支不同时,GitHub 会以 HTTP 401("Workflow validation failed")拒绝给 Claude App 发 token。这条安全策略防止 PR 通过修改 workflow 文件偷取权限,但也导致**任何混合了 workflow + code 的 PR 自动 review 直接失败**。解决方案:把 workflow 改动拆到一个独立的 "preflight" PR 里,先合入,再让主分支的 PR 继续。

```
┌─ Case A 1b — split-workflow-pr.sh ──────────────────────────────────┐
│                                                                     │
│  输入(stdin 或自动检测):                                          │
│    • workflow 文件路径列表(来自 buckets.workflow)                 │
│                                                                     │
│  1. 通过 gh repo view --json defaultBranchRef 拿到 base 分支        │
│  2. 若 workflow 文件已在已提交但未 push 的历史里 → 拒绝             │
│     (v1 范围外;用户手动 git reset/amend 后重试)                   │
│  3. 把每个 workflow 文件的当前工作区内容保存到 $TMPDIR              │
│  4. 在用户分支上:把每个 workflow 文件还原成 origin/<base> 的版本   │
│     (untracked 的 workflow 文件直接删除);diff 中不再含 workflow   │
│  5. 把剩余的非 workflow 改动 stash 起来                             │
│  6. git checkout -b preflight/<branch>-workflow-<时间戳>            │
│       基于 origin/<base>                                            │
│  7. 把保存的 workflow 内容应用到 preflight 分支;                   │
│       git add .github/workflows/<paths>;commit                      │
│  8. git push -u origin <preflight-branch>                           │
│  9. gh pr create --base <base> --head <preflight-branch>            │
│       (PR 标题:"ci: workflow pre-merge for <branch>")              │
│ 10. gh pr merge --auto --squash <pr_num>                            │
│ 11. git checkout <user-branch>;git stash pop                        │
│       (工作区只剩非 workflow 改动)                                 │
│ 12. stdout 输出 PR number;exit 0                                   │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
                state.mode = waiting_for_preflight_merge
                state.preflight_pr = N
                              │
              (后续 Stop 走上面的 Case E)
```

**分支保护注意事项。** Preflight PR 的 auto-merge 取决于 required check 通过。如果用户把 `claude-code-review` 配成了 *required* 分支保护检查,preflight 会卡住——因为 workflow-only 的 PR 自身的 auto-review 也会撞上 401。**必须**保持 `claude-code-review` 为 advisory(非 required)。文档:`using-24hour-ClaudeCode/SKILL.md`。

**覆盖。** 在 `.claude/24hour-ClaudeCode.config.json` 设 `repair.allow_workflow_in_pr=true` 跳过拆分;workflow + code 一并进同一个 PR;auto-review 失败;需手动 review。

**v1 范围外。** 已提交到历史的 workflow 文件不会自动抽离(需要交互式 rebase / `git filter-branch`)。Hook 返回 `decision:block`,要求用户手动 git reset/amend。

---

## Phase 4 — Claude 响应 `decision:block`

**触发条件:** 上一个 Stop hook 返回了 `{"decision":"block","reason":"..."}`。
**Hook:** 无 —— 这是 Claude 的推理循环。

```
Claude 把 `reason` 作为下一回合上下文读入:
  "PR #N feedback requires rework. Iteration <X>/<MAX>。
   <反馈摘要,含 file:line 引用>
   按 rework-implementation skill 应用最小修改。"
                              │
                              ▼
Claude 调用对应的阶段 skill:
  ├─ ci-feedback-analysis        (CI 失败时)
  ├─ review-feedback-analysis    (CHANGES_REQUESTED 或可执行评论时)
  └─ rework-implementation       (始终 —— 实际改代码)
                              │
                              ▼
Claude 编辑被引用的文件
                              │
                              ▼
PostToolUse hook 触发 → touch <runtime>/dirty
                              │
                              ▼
Claude 结束本回合 → Stop hook 触发
                              │
                              ▼
              回到 Phase 3,Case A(pre-PR 分支)
              mode=ready_for_rework → iteration += 1
```

---

## Phase 5 — Auto-merge 与成功

当 `decide-feedback.sh` 返回 `feedback_good`:

```
Stop hook(mode=waiting_for_checks):
  1. gh pr merge "$PR" --auto --merge(或 --squash / --rebase 按配置)
  2. state.mode = "merged"
  3. record_event "merged"
  4. 输出 additionalContext:"✅ PR #N merged: <url>"
  5. exit 0
                              │
                              ▼
Claude 看到成功消息;用户的任务完成。
                              │
                              ▼
下一次 Stop 触发(任意后续回合):
  Stop hook(mode=merged):
    清除 current-pr.json、feedback.json、dirty
    state.mode = "idle",iteration = 0,pr_number = null
    exit 0
                              │
                              ▼
                  运行时回到 idle —— 准备好接下一个 feature。
```

---

## 状态机汇总

```
            (回合结束,无 diff)            (回合结束,diff 非空)
                  │                                       │
                  ▼                                       ▼
       ┌─────────────────────┐                 ┌──────────────────────┐
       │    idle             │ ─── PHASE 3.A ─→│ waiting_for_checks   │
       │    iteration=0      │                 │  iteration=1         │
       └─────────────────────┘                 └──────────────────────┘
                  ▲                                       │
                  │                                       │ PHASE 3.B
                  │                                       │
        ┌─────────┴─────────┐                       ┌─────┴─────┐
        │   merged          │                       │  decide   │
        │  (清理回合)       │                       └─────┬─────┘
        └─────────▲─────────┘                             │
                  │                                       │
        feedback_good                                rework_required
                  │                                       │
                  │                                       ▼
                  │                          ┌──────────────────────┐
                  └──── (auto-merge) ────────│  ready_for_rework    │
                                             │  Stop 返回           │
                                             │  decision:block       │
                                             └──────────┬───────────┘
                                                        │
                                                        ▼
                                              Claude 编辑 → 下回合
                                                        │
                                                        ▼
                                             回到 PHASE 3.A
                                             (iteration += 1)
```

---

## 停止条件(闭环终止)

由 `scripts/check-stop-conditions.sh`(pre-PR 分支)和 `scripts/decide-feedback.sh`(post-PR 分支)强制执行:

| 条件 | Token | 在哪里捕获 |
|---|---|---|
| `iteration >= max_iterations`(默认 5) | `stop:max_iterations` | decide-feedback.sh |
| 同一失败连续 2 轮 | `stop:repeated_failure` | check-stop-conditions.sh(看 `<runtime>/last-run.json` 的 fail_streak) |
| 当前在受保护分支 | `stop:protected_branch` | check-stop-conditions.sh |
| `gh auth status` 失败 | `stop:gh_auth_lost` | check-stop-conditions.sh |
| `git push` 被拒 | `stop:push_rejected` | stop.sh(push 步骤) |
| diff 超过 `max_diff_lines`(默认 500) | `stop:diff_too_large` | check-stop-conditions.sh |
| 编辑命中 `danger_paths` | `stop:danger_path` | stop.sh(via detect-changes.sh) |

任一触发时:
- Stop hook 输出 `additionalContext` STOP 消息
- 调用 `failure-escalation` skill 格式化用户向消息
- 闭环终止;需要用户介入

---

## 运行时状态文件

```
<project>/.claude/runtime/24hour-ClaudeCode/
├── .gitignore         # 内容 `*` —— runtime 文件永不进入 git diff
├── state.json         # {enabled, repo, branch, pr_number, mode, iteration, max_iterations, last_status}
├── lock/              # 目录;存在 = stop.sh 正在运行
│   └── holder         # {pid, acquired_at}
├── lock.queued        # 存在 = lock 持有期间又有 Stop 触发
├── dirty              # 存在 = 此回合有代码修改工具被调用(post-tool-use.sh 设置)
├── last-run.json      # 每次 stop.sh 调用的 {ts, status, detail, fail_streak}
├── current-pr.json    # 最近一次 PR 快照(number, url, isDraft, head SHA, ...)
└── feedback.json      # 最近一次 poll:pr + checks + reviews + comments + failed_jobs
```

所有写入都是原子的(temp + mv)。直接编辑被禁止 —— 必须通过 `scripts/runtime-state.sh`、`scripts/runtime-lock.sh` 或 `scripts/poll-github.sh`。

---

## 端到端时间线(一个 feature)

```
T+0:00   用户开 worktree,启动 Claude Code
         └─ SessionStart hook → bootstrap.sh → 注入运行时契约

T+0:01   用户:"加 OAuth refresh 逻辑"

T+0:30   Claude 改完 src/auth/handler.ts
         └─ 每次 Edit 后 PostToolUse hook 触发 → touch dirty
         └─ Stop hook 触发(回合结束)
            └─ Case A:pre-PR 分支
               • detect-changes ✓
               • verify (lint/typecheck/test) ✓
               • commit "auto: WIP on feat/oauth-refresh [10:00:30]"
               • push origin feat/oauth-refresh
               • gh pr create --draft → PR #142
               • mode = waiting_for_checks
               • 输出 "Iteration #1. PR #142 draft. CI starting."

T+0:30   Claude 可以停。用户读到消息。
         用户说:"看着不错"

T+0:31   Claude 简单回复(无编辑)
         └─ Stop hook 触发(回合结束)
            └─ Case B:waiting_for_checks 分支
               • wait-for-checks.sh —— CI 还在跑,超时
               • 输出 "CI still running. Will check next stop."

T+3:00   用户:"看下进度"

T+3:01   Claude 回复
         └─ Stop hook 触发
            └─ Case B:wait-for-checks ✓(全绿)
               • poll-github → feedback.json:全部 success,无 review 评论
               • decide-feedback → feedback_good
               • gh pr merge --auto --merge 142
               • mode = merged
               • 输出 "✅ PR #142 merged: <url>"

T+3:01   用户看到成功消息。

T+3:02   用户在同一 worktree 开始下一个 feature
         └─ Stop hook 之后再次触发(mode=merged)
            └─ Case D:清理 → mode=idle,iteration=0
         └─ 闭环准备好接下一个 feature。
```

---

## Slash 命令(只用来 debug —— 永远不是主控制流)

| 命令 | 作用 |
|---|---|
| `/24hour-ClaudeCode:status` | 展示 state.json、last-run.json、current-pr.json 内容 |
| `/24hour-ClaudeCode:retry` | 强制清 lock,手动触发一次 Stop hook |
| `/24hour-ClaudeCode:setup` | 重跑 onboarder(Phase 0) |
| `/24hour-ClaudeCode:enable` | 设 `config.enabled = true` |
| `/24hour-ClaudeCode:disable` | 设 `config.enabled = false`(两个 hook 都静默) |
| `/24hour-ClaudeCode:clear-lock` | 最后手段 —— 诊断后删 `<runtime>/lock` |

主流程靠 hook 驱动。这些命令是逃生通道。

---

## 可选:Superset workspace 集成

上面的 Phase 0–5 是 **Claude Code 驱动**的流程。无论你用不用 [Superset](https://docs.superset.sh)(第三方多 worktree 管理工具),这些都照常运行。

如果你的团队用 Superset 把 worktree 当 "workspace" 管理,plugin 提供一个**可选**集成,把自动 PR 闭环包起来。Superset 的生命周期 hook **和** Claude Code 的 hook 完全独立 —— 触发时机不同,职责不同。

### 对比

| 层 | 触发条件 | 作用域 | 做什么 |
|---|---|---|---|
| **Claude Code hook**(本 plugin) | session 启动 / 工具调用边界 / 回合边界 | 单次会话 | 驱动自动 PR 闭环(Phase 1–5) |
| **Superset hook**(可选,第三方) | workspace 打开 / Run 按钮 / workspace 关闭 | worktree 生命周期 | 准备 worktree(依赖、环境)、启动 dev server、清理 |

只在**打开 workspace** 时有交集 —— Superset 的 `setup.sh` 调用 `check-actions.sh` 验证自动 PR 闭环是否健康,然后用户才开始写代码。

### Superset 的三个生命周期脚本

通过 `bash scripts/install-superset-config.sh` 装好(每个 repo 一次)。位于 `<repo>/.superset/`:

```
用户打开 workspace ────────→ .superset/setup.sh
                              ├─ 验证 worktree(git worktree list)
                              ├─ 验证 plugin 装在 .claude/plugins/24hour-ClaudeCode/
                              ├─ 验证 gh 已登录 + 有 workflow scope
                              ├─ 验证 Claude Code Actions 已部署(调用 scripts/check-actions.sh)
                              ├─ 初始化 <runtime>/ 目录(调用 runtime-state.sh init)
                              ├─ 安装项目依赖(npm/pnpm/yarn/bun/pip/poetry/cargo/...)
                              └─ 打印一屏命令小抄
                              ⚠ 这里禁止:commit、push、开 PR、等 CI、auto-merge

用户点 Run ─────────────────→ .superset/run.sh
                              └─ 启动项目 dev server(项目特定;用户自定义)
                              ⚠ 这里禁止:触发 PR 流程、读 CI、auto-merge

用户关 workspace ─────────→ .superset/teardown.sh
                              ├─ 清理 runtime lock + 临时决策文件
                              └─ 提示用户:"PR 合入后,在 MAIN checkout 清理 worktree"
                              ⚠ 这里禁止:关 PR、删远端分支、merge PR
```

### Superset 与自动 PR 闭环的交集

```
T+0       用户打开 Superset workspace
          └─ Superset 跑 .superset/setup.sh(不是 Claude Code hook)
             • check-actions.sh 验证 workflow YAML + secret
             • runtime-state.sh init 创建 <runtime>/state.json(mode=idle)
             • 打印命令小抄

T+0:01    用户在该 workspace 起 Claude Code
          └─ Claude Code 的 SessionStart hook 触发 bootstrap.sh(Phase 1)
             • 读取 Superset setup.sh 刚刚初始化的同一个 <runtime>/
             • 注入运行时契约;Claude 准备就绪

          从这里开始,Phase 2–5 正常运行。Superset 不再介入,
          除非用户点 Run(调 run.sh —— 与闭环独立)。

T+稍后    用户关掉 workspace
          └─ Superset 跑 .superset/teardown.sh(不是 Claude Code hook)
             • 清 runtime lock,确保下次新建 workspace 起点干净
```

### 不用 Superset 怎么办

完全一样。把上面 T+0 那一步换成:

```
T+0       用户跑: git worktree add ../my-feature -b feat/my-feature
          用户跑: cd ../my-feature && claude
          (依赖安装由用户自己负责。)
```

Claude Code 的 hook(Phase 1–5)运行方式完全相同。**Superset 集成只是给已经用 Superset 管理 worktree 的团队提供的便利层**,不是必需的。

### 启用方式

```bash
# 在主 checkout 一次性运行:
bash .claude/plugins/24hour-ClaudeCode/scripts/install-superset-config.sh
git add .superset/ && git commit -m "Add Superset config" && git push
```

之后,你的团队每次开 Superset workspace 都会自动跑上面三个脚本。验证:

```bash
bash .claude/plugins/24hour-ClaudeCode/scripts/install-superset-config.sh --verify
```

完整说明、定制、排错见 `references/superset-integration.md`。
