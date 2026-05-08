# Babysit 事件处理决策表

> step 8 的中枢。Monitor 每 emit 一行就触发这张表的查询。

## 完整事件 → 动作映射

每行格式:`PR#<N> HH:MM:SS | state=X merge=Y checks=A:F,B:S,... reviewers=A,B,...`

### 1. state 字段

| state | 动作 |
|---|---|
| `OPEN` | 继续观察其他字段 |
| `MERGED` | 退出 ✅,给用户贴成功消息 |
| `CLOSED`(未 merge) | 调 `gh pr view <N> --json closedAt,closedReason` 查原因,告诉用户,退出 |
| `ERR` | 单次 ERR 忽略;连续 3 次 ERR → 告诉用户 gh CLI 出问题,退出 |

### 2. mergeStateStatus 字段

| merge | 含义 | 动作 |
|---|---|---|
| `CLEAN` | 无冲突,所有条件满足 | 静默等 auto-merge 接管 |
| `UNSTABLE` | 至少一个 non-required check 失败 | 静默(不阻止 merge) |
| `BLOCKED` | required check 未过 / approval 缺 | 静默等 |
| `BEHIND` | base 分支有新 commit,**无冲突** | **必须手动追**(见下方 BEHIND 处理) |
| `DIRTY` | 有冲突 | **必须解冲突**(见下方 DIRTY 处理) |
| `UNKNOWN` | GitHub 还没算完 | 静默,下个 tick 会更新 |

⚠️ **如果项目 repo 开了 "Require branches up-to-date before merging",auto-merge 看到 BEHIND 不会自动追**——必须 babysit 推 update。可用 `gh repo view --json branchProtectionRules` 确认。

#### BEHIND 处理(无冲突)

直接执行,不询问用户(`<BASE_BRANCH>` 替换为项目实际 base 分支):

```bash
git fetch origin <BASE_BRANCH>
git merge origin/<BASE_BRANCH> --no-edit
git push
```

push 后 Monitor 会捕获 `merge=CLEAN` 或下一轮 review 的 `reviewers=` 变化,继续走。

#### DIRTY 处理(有冲突)

默认**告诉用户准备解冲突,等确认**。但满足下面任一条件可以直接处理:

- 冲突文件全是新增的(双方都 add 了同名文件,明显是 rebase 噪声 + 自己改动应该胜出)
- 冲突全是 lockfile(`pnpm-lock.yaml` / `package-lock.json` / `yarn.lock` / `Cargo.lock` / `poetry.lock` 等)→ 重跑安装命令重新生成

其他情况(业务代码冲突)→ 不要乱合,给用户:

```
⚠️ PR #<N> 出现 DIRTY 冲突
冲突文件:
- src/foo.ts
- src/bar.tsx
我准备 git fetch origin <BASE_BRANCH> && git merge origin/<BASE_BRANCH>,会需要手动解决业务冲突。是否继续?
```

### 3. statusCheckRollup 字段

格式:`name1:conclusion1,name2:conclusion2,...`,例如 `test:success,claude-review:success,build:failure`

| 出现 | 动作 |
|---|---|
| 任一 `:failure` | **不自动 retry**。退出 babysit,告诉用户失败 check 名 + 给出查日志命令 |
| 任一 `:cancelled` | 类似 failure,告诉用户 |
| 全部 `:success` 或 `:skipped` | 静默等 |
| `:pending` / `:in_progress` 在跑 | 静默等 |

failure 时给用户的消息:

```
❌ PR #<N> CI 失败:
- <check name>: failure
查日志:gh run view --log-failed --job=<job_id>
(job_id 可从 gh pr checks <N> 拿到)
我已退出 babysit,等你修了重新 push 后再 arm Monitor 继续。
```

**为什么不自动 retry**:CI failure 通常 ≠ flaky(如果项目 CI 稳定),更多是真 bug。retry 不解决根因,只是浪费时间。如果你项目的 CI 真很 flaky,在告诉用户失败时主动建议"如果是 flaky 试 `gh run rerun <id>`",不要自动重试。

### 4. reviewers 字段

格式:`name1,name2,name3`,按字典序

| 变化 | 动作 |
|---|---|
| 多了新名字(如从 `claude[bot]` 变 `claude[bot],Codex`) | **回 step 6 多轮 gate**:调 `gh pr view <N> --json reviews` 看新 review 内容,按 [quality-gate.md](quality-gate.md) 评估 |
| 出现 `claude[bot]` | Claude Code Action 已 review,正常评估流程 |
| 用户在 PR 评论 `@claude 修 XXX` 后 reviewers 暂时不变 | Action 在 runner 里跑,**等 30s–3min**;30s 后查 `gh run list -w claude.yml --limit 1` 确认 workflow 在跑(参 [quality-gate.md §2.5](quality-gate.md)) |
| `@claude` 委托后 5min 还没新 commit | Action 跑挂了:看 `gh run view <run-id> --log-failed`,常见 401(token)/ timeout / quota 用尽 → [blockers.md #8](blockers.md) |
| 名字没变但有新 review event | 同上(agent 可能在第二次 review 推翻第一次结论) |
| 没变 | 静默 |

获取最新 review 内容:

```bash
# 最近一条 review by author
gh pr view <N> --json reviews --jq '.reviews[-1]'

# 特定 agent 的所有 review
gh pr view <N> --json reviews --jq '.reviews[] | select(.author.login=="<agent-login>")'

# Claude Code Action 这条 review
gh pr view <N> --json reviews --jq '.reviews[] | select(.author.login=="claude[bot]")'
```

### 5. 时间维度

| 时间 | 动作 |
|---|---|
| t < 5 min | 不进 step 7,无论 reviewer 状态如何 |
| 5 min ≤ t < 15 min | 收到反馈进 6b,没收到继续等 |
| t = 15 min | 强制进 6b(有几条算几条) |
| t = 60 min | **强制 cap**:告诉用户当前 state 和已发生事件,退出 |

## 沉默处理

每个 tick **没有变化**时 Monitor 不 emit。这不是 bug:

- 用户看不到任何输出 = PR 状态稳定
- agent 应该理解 "无消息 = 一切正常",**不要**主动去 `gh pr view` 复查

如果 30 分钟完全无 emit(PR 一直 OPEN + CLEAN + 等 auto-merge):
- 检查 `autoMergeRequest`:`gh pr view <N> --json autoMergeRequest --jq '.autoMergeRequest.mergeMethod // "off"'`
- 如果是 `off` → step 7 没执行成功,重跑 `gh pr merge --auto --merge <N>`
- 如果是 `merge`(或 squash)→ 真在等 required check,继续静默

⚠️ **档位 A(Action 主导)的额外沉默检查**:

如果 PR 开 5 分钟以上 `reviewers=` 字段一直空(连 `claude[bot]` 都没出现),**workflow 没跑**:

```bash
# 看 review workflow 有没有触发过
gh run list -w claude-code-review.yml --limit 5

# 没看到任何 run → workflow 配置 / App / secret 出问题
# 看到 run 但 status=failure → 看日志
gh run view <run-id> --log-failed
```

**这是 [blockers.md #7](blockers.md) 的"Actions 没触发"场景**,停下来给用户(workflow 没跑就没人 review,继续 babysit 也没用)。

## "完成"消息模板

state=MERGED 后退出,给用户:

```
✅ PR #<N> merged: <PR URL>
- review 轮次:<N> 轮
- 采纳反馈:<X> 条(来自 <agent A>, <agent B>)
- 跳过反馈:<Y> 条(reason: ...)
- 总耗时:<HH:MM>(从开 PR 到 MERGED)
- 关联 issue:#<X>(已自动关闭)
```

不需要"接下来呢"、"是否还有其他事"。end of turn。

## 60 分钟 cap 消息模板

```
⚠️ PR #<N> babysit 60 分钟 cap 触达
当前 state: <state>
当前 merge: <merge>
最近 events:
  - HH:MM:SS state=X merge=Y ...
  - HH:MM:SS state=X merge=Y ...
PR 链接:<PR URL>
你来接管:通常是 <BLOCKED 等 review> / <DIRTY 解冲突> / <CI failure 修>
```

## CLOSED 未 merge 消息模板

```
❌ PR #<N> 被关闭但未合并
关闭原因:<closedReason 字段>
关闭时间:<closedAt>
PR 链接:<PR URL>
我已退出 babysit。
```
