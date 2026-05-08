# Monitor 模板与 6 条铁律

> Monitor 是这个 skill 能稳定复现的核心。每个 tick 输出**可比较的标量**，状态变了 emit，状态没变保持沉默。一旦标量解析失败（jq 炸 / 管道吞控制字符 / 嵌套引号），状态机退化成"沉默 = 一切正常"——典型故障表现是用户盯着 chat 等了十几分钟没任何输出，以为 PR 早合上了，实际 Monitor 早就静默崩溃了。
>
> 下面 6 条铁律每一条都来自实际踩坑。**verbatim 复制使用，不要自己改写**。

## 标准 Monitor 模板（PR babysit 唯一规范写法）

```
Monitor({
  description: "PR #<N> state (gh --jq only, no shell pipes)",
  persistent: true,
  timeout_ms: 3600000,
  command: `
PR=<N>
prev=""
while true; do
  state=$(gh pr view $PR --json state            --jq '.state'                                                                                  2>/dev/null || echo ERR)
  merge=$(gh pr view $PR --json mergeStateStatus --jq '.mergeStateStatus'                                                                       2>/dev/null || echo ERR)
  checks=$(gh pr view $PR --json statusCheckRollup --jq '[.statusCheckRollup[]? | select(.conclusion!="" and .conclusion!=null) | .name + ":" + .conclusion] | sort | join(",")' 2>/dev/null || echo ERR)
  revs=$(gh pr view $PR --json reviews             --jq '[.reviews[]?.author.login]  | unique | join(",")'                                       2>/dev/null || echo ERR)

  cur="state=$state merge=$merge checks=$checks reviewers=$revs"
  if [ "$cur" != "$prev" ]; then
    echo "PR#$PR $(date +%H:%M:%S) | $cur"
    prev="$cur"
  fi
  case "$state" in
    MERGED) echo "PR#$PR MERGED -- monitor exiting"; break;;
    CLOSED) echo "PR#$PR CLOSED -- monitor exiting"; break;;
  esac
  sleep 60
done`
})
```

把 `<N>` 替换成实际 PR 编号即可。`timeout_ms: 3600000` = 60 分钟，覆盖 step 6 + step 8 全过程。

## 6 条铁律（每条都来自实际踩坑）

### 1. 只用 `gh --jq`，不用 `gh ... | jq`

PR body 里的中文/换行/控制字符会让外层 jq 报：

```
jq: error (at <stdin>:1): Invalid string: control characters from U+0000 through U+001F must be escaped
```

**正确**：`gh pr view $PR --json state --jq '.state'`
**错误**：`gh pr view $PR --json state | jq -r '.state'`

### 2. jq 表达式禁用嵌套字符串模板 `"\(.x):\(.y)"`

转义层级在 shell + jq 之间撕裂，bash 会吃掉某层引号，最后 jq 拿到的表达式不合法。

**正确**：`.name + ":" + .conclusion`
**错误**：`"\(.name):\(.conclusion)"`

### 3. 拼接用 `+`，不用字符串模板

同 #2 原因。`+` 在 jq 里是字符串拼接，最朴素也最稳。

### 4. 每个标量字段一次独立 `gh --jq`

一次 `--json reviews,comments,timelineItems` 拉回大 JSON 反而是炸弹——字段越多控制字符越多，外层处理稍微复杂就会炸。

**正确**：4 次独立 `gh pr view`，每次只拉一个字段
**错误**：`gh pr view --json state,merge,checks,reviews` 然后用一个大 jq 表达式拆

代价：4 次 API 调用 / tick；收益：稳定性。GitHub rate limit 5000/h，60s 一个 tick × 4 字段 = 240/h，远低于 limit。

### 5. 首次必须 emit baseline

`prev=""` 与任何 gh 输出都不可能相等 → 第一个 tick 必然 emit 当前状态，给用户/agent 一个"现在的起点"。

**禁用**：`prev="ERR"` 或 hardcoded 初值（首次状态恰好等于初值时静默 = 用户以为没启动）。

### 6. terminal state 用 `case "$state" in MERGED) ...` 显式 break

**正确**：`case "$state" in MERGED) ...; break;; CLOSED) ...; break;; esac`
**错误**：`case "$cur" in *MERGED*) ...; esac`（在 `state=NOTMERGED`、`state=AUTO_MERGED`、或字段值含 `MERGED` 子串的边角值上误命中）

只对最终 state 字段做精确匹配，别对拼接字符串做模糊匹配。

## 字段速查（手动查也用这套）

| `gh pr view <N> --json X` | jq | 用途 |
|---|---|---|
| `state` | `.state` | OPEN / MERGED / CLOSED → 退出条件 |
| `mergeStateStatus` | `.mergeStateStatus` | CLEAN / DIRTY / BEHIND / BLOCKED / UNSTABLE / UNKNOWN |
| `statusCheckRollup` | `[.statusCheckRollup[]? \| select(.conclusion!="" and .conclusion!=null) \| .name + ":" + .conclusion] \| sort \| join(",")` | 通过 / 失败 / 跳过的 check 名单 |
| `reviews` | `[.reviews[]?.author.login] \| unique \| join(",")` | 哪些 review agent 出过声 |
| `reviewDecision` | `.reviewDecision` | APPROVED / CHANGES_REQUESTED / REVIEW_REQUIRED / null |
| `autoMergeRequest` | `.autoMergeRequest.mergeMethod // "off"` | auto-merge 是否在等 |
| `comments` | `.comments \| length` | 评论数（注意：单条评论字段不要直接 `--jq` 拉 body，控制字符炸） |

读单条 review/comment body：

```bash
# 用 gh api 而不是 gh pr view，body 字段 raw 文本走纯 stdout，不进 jq
gh pr view <N> --json reviews --jq '.reviews[] | select(.author.login=="<agent>") | .body'
```

## 收到事件怎么处理

见 [decision-table.md](decision-table.md)。

## Monitor 本质（为什么这套规则存在）

Monitor 不是"定时检查"，是**事件流状态机**。

- 输入：`gh pr view` 的 4 个标量字段
- 状态变量：`prev`（上一 tick 的拼接串）
- 输出条件：`cur != prev` 时 emit
- 终止条件：state ∈ {MERGED, CLOSED}

6 条铁律全是为了让"标量解析"永远不失败：每字段独立查、不嵌套模板、空字符串 sentinel、显式终止匹配。**每一条都对应至少一次真实的"沉默十几分钟、用户以为 PR 合上了实际还在 OPEN"事故**。

## 没有 Monitor tool 的兜底

| 工具可用性 | 兜底 |
|---|---|
| 有 Monitor | 用上面模板（首选） |
| 没 Monitor，有 ScheduleWakeup | `ScheduleWakeup({delaySeconds: 60, prompt: "/loop babysit PR #<N>"})` 定时唤醒。每分钟一次全量查询，效率低但能跑 |
| 都没有 | 明确告诉用户："我没有 Monitor / scheduling 工具，无法持续 babysit。请确保 always-on session 接管，或者在浏览器上盯着 PR" |
| **禁止** | Bash 长 sleep（系统拦截 + turn 结束 = 进程消失） |

## arm Monitor 的时机

- step 6a 开始 → arm
- 一直跑到 step 8 退出（state=MERGED 或 60 min cap）
- 中间不要 kill 重 arm，事件流连续才能正确驱动决策
- 如果 review 期间 push 了新 commit，Monitor 会自然捕获 `checks=` 变化，不需要重 arm
