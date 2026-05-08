# Quality Gate:多 agent review 评估细则

> step 6 的核心。目标是**所有有效反馈都修**(包括 Minor/Nit),但**不被 noise/误读 卷进死循环**。

## 0. 时序硬规则(不能跳)

时序分两档,看你仓库装的是哪种 review agent:

### 档位 A:Claude Code Action 主导(自建 `.github/workflows/claude-code-review.yml`)

| 时间点 | 动作 |
|---|---|
| t = 0 | gh pr create 完成 |
| t = 0 | 立刻 arm Monitor(`reviewers=` 字段会驱动新事件) |
| t < 2 min | **不进 6b**。Action 冷启动(runner 排队 + bun 安装 + checkout)需要 30–60s,后面才是 Claude 真正在看 |
| 2 min ≤ t < 8 min | 收到反馈 → 立刻进 6b;没反馈 → 继续等 |
| t = 8 min | 强制进 6b(有几条算几条);全部沉默 → 直接 step 7 |
| 整个 gate ≤ 60 min | 超时直接 step 7(强制 cap) |

**为什么是 2 分钟**:Claude Code Action 通常 30s–2min 内出第一条 review。但等够 2 分钟才进 6b 是为了:
- 大型 PR 让 Claude 看完需要时间
- 如果你**还有第三方 agent 共存**(下面档位 B 的情况),给它们留点出声窗口

### 档位 B:多 cloud agent 共存(Action + Codex / Copilot 等第三方 App)

| 时间点 | 动作 |
|---|---|
| t = 0 | gh pr create 完成 + arm Monitor |
| t < 5 min | **不进 6b**。即使 Action 已经 "no concerns" / "looks good",也必须等第三方 agent 出声 |
| 5 min ≤ t < 15 min | 收到反馈 → 立刻进 6b;都没响应 → 继续等 |
| t = 15 min | 有几条算几条进 6b;全部沉默 → 直接 step 7 |
| 整个 gate ≤ 60 min | 超时直接 step 7(强制 cap) |

**为什么是 5 分钟**:第三方 GitHub App 通过 webhook 触发,平均 3–5 分钟出第一条反馈。如果在 90 秒就因为 Action 说 OK 而进 step 7,等于完全跳过其他 agent。

### 怎么判断走 A 还是 B

```bash
# 查仓库 .github/workflows/ 里有哪些 review agent
ls .github/workflows/ | grep -E '(claude|codex|copilot|review)'

# 查 PR 的 reviewers 字段历史范围(只 claude[bot] 单独出现 → A 档;还有其他 → B 档)
gh pr view <N> --json reviews --jq '[.reviews[]?.author.login] | unique'
```

**默认按档位 A**(本 skill 的标准假设)。如果仓库实际是 B 档,本文档其余规则照样适用,只是时序窗口换成 5/15min。

## 1. 反馈优先级矩阵

> **项目适配**:下面的 Reject 列表是**通用模板**,实际 Reject 边界以你项目根的 `CLAUDE.md` / `AGENTS.md` / `STYLE_GUIDE.md` 顶部红线为准。安装 skill 到新项目时把项目特有的红线追加到本节末尾。

### Reject(必须打回)

任何一条触发就**不该提这个 PR**,应该回 step 1 重写。**通用红线**:

1. 改了项目签名密钥 / 证书 / keystore 等凭证文件(绝对禁区)
2. 把任何 secret 写进了客户端打包变量(会泄漏到客户端 bundle;典型危险前缀如 `EXPO_PUBLIC_*` / `NEXT_PUBLIC_*` / `VITE_*` / `REACT_APP_*` / `PUBLIC_*` 等)
3. 改了 `.env.production` / `.env.staging` / 第三方平台 secrets 相关代码(生产配置变更必须人工 review)
4. 直接 push 到受保护分支(main / master / dev / staging 等),绕过 PR 流程
5. 生产数据库 schema 变更没加幂等保护(无 `IF NOT EXISTS` / 无回滚脚本 / 无 expand-contract 拆分)
6. 在 LLM prompt / 第三方 API 调用里硬编码用户 PII

**项目特有红线**(由该项目维护者填补):

```
- <红线 1,例如:某些目录禁止改、某些命令禁止跑、某些 lib 禁止引入>
- <红线 2>
```

### Major(标 critical comment 但允许讨论)

按 review agent 反馈处理;不合理可 reply 解释,**但必须回应**。**通用清单**:

1. 缺失 input validation 在 system boundary(route handler / 外部 API 边界)
2. SQL injection 风险(拼字符串 vs ORM/DB 库的 parameterized query)
3. N+1 query(循环里 await db query)
4. 未处理的 Promise rejection / 吞 error 又不上报
5. 队列 / 消息系统 producer/consumer name 不一致(改了 producer 端忘改 consumer 端)
6. 违反项目级硬性风格规则(设计系统 token、命名规则、组件强制使用要求等——以项目 CLAUDE.md 为准)
7. 显著性能退化(算法复杂度从 O(n) 变 O(n²)、引入大量同步阻塞)
8. 破坏 API 兼容(改字段名 / 改返回结构)且没做版本兼容

### Minor(一句话提一下,不阻塞)

1. 测试覆盖能补但没补(重要逻辑缺测试)
2. 命名歧义、可以更具体
3. 重复代码可抽函数

### 忽略(**不要**评审 / 不要被这种反馈带歪)

- 行宽 / 缩进 / 空行(formatter 管)
- 注释多少 / 写法(除非误导)
- 变量名风格(除非违反语言/项目约定)
- 提交信息格式

## 2. 多 agent 反馈的合并规则

收到 ≥2 个 agent 的反馈后,按下表评估:

| 情况 | 处理 |
|---|---|
| 多 agent 同时指出同一问题 | 优先级 +1(弱信号叠加 = 强信号),无论原级别如何都要修 |
| 单 agent 指出、其他沉默 | 按原级别处理(Reject/Major 必修;Minor/Nit 评估合理性后修) |
| **任何级别真合理** | 6c 修,包括 Minor / Nit / 风格 |
| 真不合理 | 在 PR 上 reply 一句说明("已是项目约定"/"违反项目 CLAUDE.md 顶部规则"),跳过 |
| agent 间冲突(A 加缓存 / B 别加) | 默认按项目 CLAUDE.md 现有约束判;没明确约束就**保留现状不改**,PR 上 reply 解释 |

### "真合理" vs "真不合理" 怎么判

合理的信号:
- 引用具体代码行 / 数据 / 文档来源
- 说出后果(运行时 bug / 安全漏洞 / 性能问题)
- 给出可操作的 fix(不是泛泛 "consider XXX")

不合理的信号:
- 笼统建议("consider improving naming")
- 与本 repo 项目级 CLAUDE.md 顶部规则直接冲突(如要求加 emoji icon、要求 raw hex 颜色)
- 看错了上下文(agent 误以为某文件是其他模块的)

### 特殊:merge commit 误读

如果 review agent 把**之前 merge commit 带入的 base 分支改动**误读为本 PR 工作(比如 PR 实际只改了 5 个文件,agent 在评论 base 上的另外 50 行),用:

```bash
gh pr view <N> --json files --jq '[.files[]?.path] | sort | join("\n")'
```

确认实际 diff 范围,然后 PR 上 reply 一句"已确认 PR 实际改动仅涉及 X 文件,agent 提到的 Y 文件来自 base 分支 merge,不在本 PR scope 内",跳过。

## 2.5 Action 自修 path(Claude Code Actions 独有)

如果仓库装了 `claude.yml`(`@claude` 触发的交互 workflow),你有两条修反馈的路径:

### 路径 A:本地修(经典 6c)

```bash
# 本地编辑代码 → commit → push,触发新一轮 CI 和 review
git add <files>
git commit -m "review: address <agent> on PR #<N> — ..."
git push
```

### 路径 B:委托 Action 自己修

在 PR 评论里贴 `@claude <指令>`,例:

```
@claude 把 src/foo.ts 第 47 行的 race condition 修了,加 SELECT FOR UPDATE
```

`claude.yml` workflow 触发,Action 在 runner 里 checkout、改文件、commit、push 到 PR 分支。30s–3min 后你会看到新 commit。

### 怎么选

| 场景 | 推荐路径 |
|---|---|
| 反馈很复杂、需要看上下文跨多文件、有项目级约束 | A(本地)——你比 Action 更懂全貌 |
| 反馈很明确、单点修改、agent 已经指了具体行 | B(委托)——省时间 |
| 涉及生产敏感文件(`.env.production` 等) | A,且按 [blockers.md #6](blockers.md) 必须人工 review |
| review 反馈本身有歧义 / 你想拒绝 | 都不用,直接在 PR 上 reply 解释 |

### 路径 B 的注意事项

- Action commit 完会触发新一轮 `pull_request: synchronize`,Monitor 会在 `reviewers=` 字段看到新事件 → 回 6a 重审,**不要**跳过这一步
- 如果 `claude.yml` 配的 `permissions: contents: read`(只读),Action 改不了代码,会留个评论说"我没权限"——回头改 YAML 加 `contents: write`
- Action 跑挂(quota / 401 / timeout)时**不会**自己重试;你需要查 `gh run list -w claude.yml --limit 1` 找日志,要么本地修(回路径 A),要么修好 YAML / token 后重发 `@claude` 指令

## 3. 防死循环

| 限制 | 阈值 | 触发后行为 |
|---|---|---|
| 单条建议被采纳次数 | ≤ 2 | 第二次后同 agent 还重复 → reply "已多次评估,决定保留现状",跳过 |
| 整个 gate wall clock | ≤ 60 min | 超时直接 step 7 enable auto-merge |
| 单轮 review 等待(档位 A,Action 主导) | ≤ 8 min | 到点不管几个 agent 出声都进 6b |
| 单轮 review 等待(档位 B,多 agent 共存) | ≤ 15 min | 到点不管几个 agent 出声都进 6b |
| `@claude` 委托修复后等 Action 跑完 | ≤ 5 min | 超过 5min 还没新 commit → 查 `gh run list -w claude.yml`,跑挂就走路径 A 本地修 |

## 4. 修反馈的 commit 模板

```
review: address <agent> on PR #<N> — <一句话>

- 采纳 <agent A> 的 <X> 建议(reason: 合理 + 多 agent 同条)
- 采纳 <agent B> 的 <Y> 建议(reason: Major 级别)
- 跳过 <agent C> 的 <Z> 建议(reason: 与项目 CLAUDE.md 顶部"忽略"清单冲突,已在 PR 上 reply)

Co-Authored-By: Claude <noreply@anthropic.com>
```

## 5. push 后回 6a

push 触发:
- CI 重跑(typecheck / lint / test)
- 所有 review agent 重审(GitHub Action 类的 review 在 PR sync 触发;GitHub App 类似)

**不要**在这里跳过等待直接 step 7——重审可能发现新问题,跳过 = gate 失效。

回 6a 继续 Monitor 等事件,单个 PR 可能轮 2–3 次直到所有反馈静默。

## 6. 全部沉默 / 都说 OK 的判定

进 step 7 的条件(满足任一):

- 所有出声的 agent 都 review-approved(`reviewDecision=APPROVED`)
- 所有出声的 agent 评论都已 reply 处理过(采纳或解释跳过)
- 档位 A:8 分钟内全部沉默 / 档位 B:15 分钟内全部沉默
- 60 分钟 wall clock cap

满足条件 → 立刻 `gh pr merge --auto --merge <N>`,不停下问用户。

⚠️ **档位 A(Action 主导)的特殊沉默情况**:如果 8min 到了 `reviewers=` 字段还是空,先 `gh run list -w claude-code-review.yml --limit 3` 确认 workflow 真跑过且 success。如果 workflow 完全没触发或失败,这是 [blockers.md #7](blockers.md) 的情况(Actions 没触发),停下来给用户。

## 7. 罕见但合法的"PR 太小被 agent 主动忽略"

不少内置 review agent(如 claude-review、官方 `code-review` plugin)系统 prompt 里有类似规则:

> 如果 PR 是小于 ~30 行的纯文档 / typo / changelog,直接说 "looks good, skipping detailed review"

对应的 PR 类型:typo 修正、README 改一行、依赖小版本 bump。这种 PR 上 agent 集体沉默是**正常**的,不是失败模式。档位 A 到 8min / 档位 B 到 15min → 直接 step 7。

不要因为 "agent 都没说话" 而恐慌或来回询问用户。**前提**:已用上面的 `gh run list` 确认 workflow 真跑过、不是配置问题。
