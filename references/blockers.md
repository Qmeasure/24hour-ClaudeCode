# 唯一允许停下来问用户的场景

> Path B 的设计是中途**不停**。但有少数真 blocker 必须停下来——下面列出**全部允许停的情况**,不在列表里的都不允许停。

## 允许停的 6 种场景

### 1. Pre-flight 检查 #4:缺少关联 issue 编号

PR body 必须含 `Closes #<N>`(或项目管理工具对应 ID)。如果用户启动任务时没给编号,问一次:

```
这个 PR 关联哪个 issue 编号?需要写进 PR body 的 Closes 句子让 issue 自动关闭(或者明确说 "无关联 issue" 我就不写)。
```

得到答复继续。

### 2. Local verification 失败但需要决策

跑 typecheck / lint / test 出现的失败如果是:

- **明显代码 bug** → 自己修,不停
- **测试发现产品级问题**(功能本来就不对,不只是新代码 bug)→ **停下来**:

```
跑测试发现 <test name> 失败,看起来不是新代码问题——
<具体观察:旧测试也会挂 / fixture 数据已过期 / 业务逻辑本身错>
我建议 <plan>,但这影响范围超过本 PR scope,需要你确认。
```

### 3. Monitor 工具不可用

```
我没有 Monitor / ScheduleWakeup 工具,无法持续 babysit PR #<N>。
- 可选 A:你保持 always-on session 接管 babysit
- 可选 B:你手动盯 PR 页面,CI 过了 + review 静默后我帮你重新 enable auto-merge
```

### 4. DIRTY 冲突且不在白名单

冲突白名单(可直接处理):
- 全是新增文件
- 全是 lockfile(`pnpm-lock.yaml` / `package-lock.json` / `yarn.lock` / `Cargo.lock` / `poetry.lock` 等)→ 重跑安装命令重新生成

业务代码冲突 → 停:

```
PR #<N> DIRTY 冲突
冲突文件:
- src/foo.ts
- src/bar.tsx
我准备 git fetch origin <BASE_BRANCH> && git merge origin/<BASE_BRANCH>,需要手动解决业务冲突。是否继续?
```

### 5. CI 失败需要诊断方向

CI failure 多数是真 bug,但偶尔是:
- 第三方依赖临时挂掉(包仓库 / 后端服务)
- runner 资源问题
- flaky test(应该修而不是 retry)

如果失败现象不像本 PR 引起 → 停:

```
PR #<N> CI 失败:<check name>
log 显示 <现象>,看起来不是本 PR 引起。可能原因:
- <推测 1>
- <推测 2>
我建议 <plan>,需要你确认方向。
```

### 6. review agent 反馈触及生产敏感区

review agent 评论让你改下面这类**生产敏感文件 / 操作**时,**必须停**(不依赖 review agent 的判断,以你项目根的 CLAUDE.md 红线列表为准。常见红线举例):

- 生产环境配置(`.env.production` 等)、第三方平台 secrets
- 生产数据库迁移命令(直接 push schema 类操作)
- 签名密钥、证书、credential 文件
- CI/CD 凭证、deploy key

→ 必须停:

```
review agent 建议改 <生产敏感文件>,按项目 CLAUDE.md 红线必须人工 review。
agent 原话:<quote>
你怎么处理?(接受 / 拒绝 / 拆 PR 走特殊流程)
```

### 7. Claude Code Actions workflow 没触发 / 跑挂

PR 开了 5 分钟后,**reviewers 字段一直为空**,且:

```bash
gh run list -w claude-code-review.yml --limit 3
```

显示 0 条 run,或所有 run 都是 `failure` / `cancelled`。

可能原因:

| 现象 | 原因 | 修复 |
|---|---|---|
| 无任何 run 记录 | workflow YAML 语法错 | `gh workflow view claude-code-review.yml` 看 invalid 提示 |
| run 都是 `failure`,日志 401 | secret `CLAUDE_CODE_OAUTH_TOKEN` 不存在 / 过期 | `claude setup-token` 重生成 + `gh secret set CLAUDE_CODE_OAUTH_TOKEN` 覆盖 |
| 无任何 run 记录,workflow 在 disabled 状态 | App 没装 / 没勾选当前 repo | <https://github.com/apps/claude> → Configure → 加上 repo |
| run 跑出 `usage limit exceeded` | runner quota 用尽(免费每月 2000 min) | 等下个月或升 plan |
| run 跑出 `rate_limit_exceeded` | Claude 订阅日 quota 用尽 | 等 5 小时重置,或换 API Key 路径 |

→ 必须停:

```
⚠️ PR #<N> 的 Claude Code Actions 没正常工作

当前状态:
<gh run list 输出>

推测原因:<上表对应那条>
建议修复:<对应命令>

我没法继续 babysit(没人 review),你来修一下再让我接管。
```

### 8. OAuth token 失效 / 订阅 quota 用尽

Workflow 跑了但 step `Run Claude Code` 失败,日志含:

- `401 Unauthorized` / `Authentication failed`
- `rate_limit_exceeded` / `quota exceeded` / `usage limit reached`

→ 必须停:

```
⚠️ PR #<N> Claude Code Action step 认证 / quota 失败

run: <run-id> 日志:
<关键错误行 quote>

可能原因:
- OAuth token 过期 → claude setup-token 重新生成 + gh secret set 覆盖
- 订阅日 quota 用尽 → 等 5 小时重置(GitHub-actions 按 UTC 跨天)
- 触发了 Anthropic 风控 → 间隔 10–30 分钟再试

修好后,在 PR 评论里贴 `@claude resume` 让我接着之前的进度跑(或者本地修后 push,触发新一轮 review)。
```

---

## 不允许停的场景(容易混淆但必须继续)

| 看似要停的情况 | 为什么不要停 | 正确做法 |
|---|---|---|
| 代码改完想让用户先看一眼 | 在 chat 里 mock review = 双重 review = 浪费 | 直接 step 4 push,让 review agent 真去看 |
| auto-merge enable 完想确认 | DoD = state=MERGED,enable 不算 | 继续 babysit |
| review 反馈很多想问优先级 | 优先级矩阵在 quality-gate.md,自己能判 | 按矩阵处理,不合理的反馈 reply 跳过 |
| 60 分钟快到了想问要不要继续 | cap 是 hard cutoff,到点直接退出 | 60 min 到 → 给 cap 消息 → 退出 |
| BEHIND 想问要不要追 | base 有更新 + 无冲突 = 必须追 | 直接 fetch + merge + push |
| step 7 enable 完想问 babysit 要不要继续 | step 8 是 step 7 的紧接续 | 立即 babysit |
| 5 分钟到了 review 还没全到齐想问怎么办 | 5 分钟到 + 有反馈进 6b;没反馈继续等到 15 min | 静默等 |
| 改第 3 轮反馈想问"是不是改太多了" | 单条 ≤2 次、整 gate ≤60 min 是硬限 | 按规则继续,到限就停规则 |

---

## 停下来时的格式

任何停下来的消息都按下面三段式:

```
⚠️ <一句话总结为什么停>

<具体观察 / 数据 / 引用>

<需要你的决策 / 选项>
```

短、直接、给选项。**不写废话**("麻烦您"、"如果方便的话")。
