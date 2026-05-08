# 反模式集合(哪些行为会让流程"看起来在跑但其实断了")

> 这个文件不是教你做什么,是教你**不做什么**。Path B 的失败模式 90% 集中在下面 7 类。

## A. 中途停下问用户(最高频)

LLM 训练里有强烈的"完成阶段性工作就汇报"惯性。Path B 的设计是**一口气从 step 1 跑到 state=MERGED**,中途任何"汇报+确认"都会让用户必须回来一次手动 nudge。

### 错误示例

| 错误说法 | 为什么错 | 正确做法 |
|---|---|---|
| "代码改完了,要不要 push?" | 用户授权已经在 worktree 入口给过 | 直接 push |
| "PR 开好了,是否 enable auto-merge?" | --auto 自己等 CI,立即 enable 零风险 | 直接 enable |
| "测试都过了,等你 review 一下" | 用户的 review 在 PR 页做,不在 chat 里做 | 跑完 step 6–8 后给 PR 链接,让用户去 PR 页看 |
| "改完了,给你 diff 看一下?" | 在 chat 里 mock review = 双重 review = 浪费时间 | 直接 step 4 push,让 review agent 真去看 |
| "先停下让你确认方向再继续" | 方向应该在动手前定,动手后只在 blocker 时停 | 见 [blockers.md](blockers.md) 的允许停下场景 |
| "auto-merge 已 enable,可以了吧?" | DoD = state=MERGED,不是 enable | 继续 babysit |

### 正确示例

```
用户:"修一下 PR #100 review agent 提的 timeout 问题"
你执行:
  1. 看 review 评论(quality-gate 评估)
  2. 改代码
  3. typecheck/test
  4. commit
  5. push
  6. 等下一轮 review (Monitor)
  7. 没新反馈 → auto-merge 已经 enable,babysit 继续
  8. state=MERGED → 给用户成功消息
全程 0 次 chat 提问。
```

## B. Babysit fake / 长 sleep

### 反模式

```bash
# ❌ 这些都不工作
sleep 600 && gh pr view 100         # 系统拦截
echo "等 10 分钟" && sleep 600       # 同上
"6 分钟后我回来看"                   # turn 结束 = 进程死了
"我会持续监控"(实际什么都不做)       # 用户以为在 babysit,其实没人盯
```

### 正确做法

- 优先:Monitor (`mcp__claude_ai_*` 或框架内置)
- 次选:`ScheduleWakeup({delaySeconds: 60, prompt: "/loop babysit PR #N"})`
- 都没有:明确告诉用户"我没工具持续 babysit,请确保 always-on session 接管"

**禁止说"我会回来检查"然后 turn 结束**。

## C. Monitor 自己改 jq 表达式

### 反模式

```bash
# ❌ 这些都炸
gh pr view 100 --json state,merge | jq '...'                  # 管道吞控制字符
gh pr view 100 --json reviews --jq '.reviews[].author.login'  # 输出多行,prev 比较失效
gh pr view 100 --json reviews --jq "\(.author):\(.body)"      # 嵌套字符串模板
```

### 正确

逐字复制 [monitor-template.md](monitor-template.md) 的 6 条铁律对应模板。**任何"小优化"都会踩坑**——因为这些模式都是踩坑后回退到的最稳形式。

## D. Quality gate 时序作弊

### 反模式

| 错误时序 | 为什么错 |
|---|---|
| t=90s 内置 review(claude-review)说 OK → 立刻 step 7 | 第三方 review agent 还没来得及看 → 跳过 multi-agent gate |
| t=10s 立刻 enable auto-merge 没等任何 review | gate 完全失效 |
| 5 分钟到 reviewers 还是 1 个 → 强制等到 30 分钟 | 过度等待,整体超 60 分钟 cap |
| 反馈不喜欢就跳过不 reply | review agent 下次还会重提同一条 → 死循环 |

### 正确时序

```
t=0:        gh pr create
t=0:        arm Monitor
t<5min:     不进 6b(即使内置 review 已 approve)
t=5min:     有反馈 → 6b;没反馈 → 继续
t=15min:    强制 6b(有几条算几条)
t=60min:    强制 step 7
```

## E. Schema / 数据迁移当普通 feature PR 提

### 反模式

把 schema / migration 改动和业务代码塞同一个 PR,期望一次过 review + auto-merge。

### 为什么错

- review agent 看 schema diff 能识别隐藏 rename / 数据破坏的概率低(gate 失效)
- 万一回滚需要 revert schema + 业务代码两层(不可逆复杂度叠加)
- 阻塞别人 PR(schema 锁住 base 分支,其他 PR 全 BEHIND)

### 正确(Expand → Migrate → Contract 通用模式)

1. **PR 1(expand)**:加入新字段(nullable / 带默认值);代码同时读写新旧两份
2. 让 PR 1 在 staging 烤一段时间(典型 1 天),生产烤更久(典型 1 周)
3. **PR 2(contract)**:删旧字段或加 NOT NULL 约束;代码切到只用新

每个 PR 单独走 Path B。具体节奏按你项目的发布节奏和数据量调整。

## F. 反客为主:违反项目级 CLAUDE.md / 风格规则

review agent 偶尔会"建议加 emoji 让 UI 更友好" / "建议引入 lodash" / "建议改成 raw hex" 之类——这些有时是 review agent 自身训练偏差,如果**和项目级 CLAUDE.md / 风格指南顶部的硬规则直接冲突**,就**不是合理建议**。

### 正确反应

PR 上 reply,**引用具体的项目规则**:

```
跳过:与 <项目 CLAUDE.md / STYLE_GUIDE.md 段落名> 冲突。
- <规则 1 引用>
- <规则 2 引用>
```

不要被 review agent "建议" 卷走。它的反馈级别要按你项目顶部规则**降权**或**反向处理**。

## G. push 完不等下一轮 review,直接 step 7

### 反模式

```
6c push 反馈修复
→ 直接 gh pr merge --auto
→ 没等 CI 跑完 / agent 重审
```

`--auto` 自己等 CI 没问题,但**跳过 6a 等 agent 重审**等于失去 multi-round gate。可能新引入的 commit 又有问题,agent 第二轮发现,但你已经 enable auto-merge → CI 一过就合 → 带 bug 进 base 分支。

### 正确

push → 回 6a 等 Monitor 捕获 reviewers 字段变化 → 重评估 → 直到反馈静默 → 进 step 7。

每个 PR 平均 2–3 轮 6a/6b/6c 是正常的。

## H. Claude Code Actions 配置失误(仓库装了 Action 才会遇到)

### H1. OAuth token 泄漏

#### 反模式

把 `claude_code_oauth_token` 的值贴在:
- chat / 代码评论 / 调试输出
- commit message 或代码注释里
- `.env` 文件 commit 上去
- log 里 `echo $CLAUDE_CODE_OAUTH_TOKEN`

#### 后果

Token 一泄漏,所有看到的人都能用你的 Claude Pro/Max 订阅 quota,直到 quota 烧完或你撤销。

#### 正确

```bash
# 走 stdin 管道,token 不进 shell history、不进任何文件
gh secret set CLAUDE_CODE_OAUTH_TOKEN -R <owner>/<repo>
# 提示 "? Paste your secret" 时粘贴 → 回车

# 或从临时文件读完立刻删:
echo "<token>" > /tmp/.t && gh secret set CLAUDE_CODE_OAUTH_TOKEN -R <owner>/<repo> < /tmp/.t && rm /tmp/.t
```

如果 token 已经泄漏:`claude setup-token` 重新生成,旧 token 会失效。

### H2. `permissions: read-only` 但期望 @claude 改代码

#### 反模式

`/install-github-app` 默认产物 `claude.yml` 的权限是:

```yaml
permissions:
  contents: read
  pull-requests: read
  issues: read
```

用户在 PR 评论 `@claude 修 XXX`,Action 跑了但发现自己没写权限,**silent fail**——只在 PR 留个评论"我没权限改文件",代码完全没动。

#### 正确

```yaml
permissions:
  contents: write       # ← 必须 write,Action 才能 commit
  pull-requests: write
  issues: write
  actions: read         # 让它读 CI 日志
  id-token: write
```

### H3. 撞 workflow 文件名

#### 反模式

本地手写了 `.github/workflows/claude.yml`,跑 `/install-github-app` 又自动生成一份(同名),git push 时 conflict。或者更隐蔽:`/install-github-app` 直接通过 GitHub API 推上去了,你本地不知道,后续 push 自己版本被 reject。

#### 正确

```bash
# 先看远端有什么
gh api repos/<owner>/<repo>/contents/.github/workflows --jq '.[].name'

# 有冲突文件先 pull --rebase 再决定保留哪个
git pull --rebase origin main
```

### H4. 没设 `concurrency`

#### 反模式

用户连续 push 5 次到同一 PR,5 次 workflow 各跑一遍,token 五倍消耗。

#### 正确

```yaml
concurrency:
  group: claude-${{ github.event.pull_request.number || github.run_id }}
  cancel-in-progress: true     # 旧 run 取消,只跑最新的
```

### H5. 没设 `timeout-minutes`

#### 反模式

GitHub Actions job 默认 timeout 是 **6 小时**。Action 跑飞了(死循环、卡 LLM 调用、bun 装失败等)能烧 6 小时 token。

#### 正确

```yaml
jobs:
  review:
    timeout-minutes: 10    # review job
  claude:
    timeout-minutes: 15    # @claude 修代码 job(可能多步)
```

### H6. `--max-turns` 默认 10 但任务复杂

#### 反模式

`@claude 重写整个 src/auth/` 这种大任务,默认 10 turns 不够,Claude 改到第 5 个文件就被掐断,**留下半成品 commit**:有的文件改了、有的没改、import 不一致。

#### 正确

按场景调:

```yaml
# review-only(只评论不改)
claude_args: --max-turns 5

# @claude 修小 bug
claude_args: --max-turns 10

# @claude 跨多文件重构
claude_args: --max-turns 20
```

`--max-turns` 选择参考表见 [workflow-yaml.md §C](workflow-yaml.md#c-claude_args-cli-flags)。

### H7. 触发器配重复

#### 反模式

```yaml
# claude-code-review.yml
on:
  pull_request:
    types: [opened, synchronize]

# claude.yml
on:
  pull_request:                 # ← 也接 pull_request
    types: [opened, synchronize]
  issue_comment: ...
```

每个 PR 跑两遍 review = token 双倍。

#### 正确

按职责分:
- `claude-code-review.yml` 只接 `pull_request`(自动 review)
- `claude.yml` 只接 comment 类事件(`issue_comment` / `pull_request_review_comment` / `pull_request_review` / `issues`)

按 [SETUP.md §4](../SETUP.md) 的模板不会撞。

### H8. 把 OAuth token 当 API Key 用

#### 反模式

```yaml
anthropic_api_key: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}   # ← 字段错位
```

OAuth token 走的是订阅认证流(走 Anthropic 的 OAuth endpoint);API Key 走的是 console 计费流。Action 看 input 字段名决定走哪条;字段错位 → 401。

#### 正确

```yaml
# 用订阅
claude_code_oauth_token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}

# 或用 API Key
anthropic_api_key: ${{ secrets.ANTHROPIC_API_KEY }}

# 二选一,不要两个都填
```
