# Quality Gate:多 agent review 评估细则

> step 6 的核心。目标是**所有有效反馈都修**(包括 Minor/Nit),但**不被 noise/误读 卷进死循环**。

## 0. 时序硬规则(不能跳)

| 时间点 | 动作 |
|---|---|
| t = 0 | gh pr create 完成 |
| t = 0 | 立刻 arm Monitor(`reviewers=` 字段会驱动新事件) |
| t < 5 min | **不进 6b**。即使内置 review(如 claude-review)已经 "no concerns" / "looks good",也必须等其他 agent 出声 |
| 5 min ≤ t < 15 min | 收到反馈 → 立刻进 6b;都没响应 → 继续等 |
| t = 15 min | 有几条算几条进 6b;全部沉默 → 直接 step 7 |
| 整个 gate ≤ 60 min | 超时直接 step 7(强制 cap) |

**为什么是 5 分钟**:内置 review(如 claude-review GitHub Action)是 PR 一开就触发的(30–60s 出 stub),但第三方 GitHub App(Codex / Copilot 等)通过 webhook 触发,平均 3–5 分钟。如果你在 90 秒就因为内置 review 说 OK 而进 step 7,等于完全跳过其他 agent。

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

## 3. 防死循环

| 限制 | 阈值 | 触发后行为 |
|---|---|---|
| 单条建议被采纳次数 | ≤ 2 | 第二次后同 agent 还重复 → reply "已多次评估,决定保留现状",跳过 |
| 整个 gate wall clock | ≤ 60 min | 超时直接 step 7 enable auto-merge |
| 单轮 review 等待 | ≤ 15 min | 到点不管几个 agent 出声都进 6b |

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
- 15 分钟内全部沉默
- 60 分钟 wall clock cap

满足条件 → 立刻 `gh pr merge --auto --merge <N>`,不停下问用户。

## 7. 罕见但合法的"PR 太小被 agent 主动忽略"

不少内置 review agent(如 claude-review)系统 prompt 里有类似规则:

> 如果 PR 是小于 ~30 行的纯文档 / typo / changelog,直接说 "looks good, skipping detailed review"

对应的 PR 类型:typo 修正、README 改一行、依赖小版本 bump。这种 PR 上 agent 集体沉默是**正常**的,不是失败模式。15 分钟到 → 直接 step 7。

不要因为 "agent 都没说话" 而恐慌或来回询问用户。
