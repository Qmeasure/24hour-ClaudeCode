# Superset 集成:多 worktree 流水线无缝接入

> 这个文件解释 worktree-pr-flow skill 怎么和 [Superset](https://docs.superset.sh) 客户端协作。
>
> 适用场景:你用 Superset 管理一个 repo 下的多个 worktree(每个 worktree 是一个 feature / fix / chore),希望开 workspace 时**自动校验** Claude Code Actions 配置健康。

---

## 1. Superset 三个钩子时机

| 钩子 | 何时跑 | 用来干嘛 |
|---|---|---|
| `setup` | **新 workspace 创建后**(worktree 已 git checkout 完毕) | 校验环境、装依赖、复制 .env |
| `teardown` | **workspace 删除前**(确认完才真删) | 关闭 docker、清缓存;**失败不阻塞**,可 force-delete |
| `run` | 用户点 Run 按钮 | 起 dev server、跑测试,在专用 pane 里运行 |

每个钩子是字符串数组,顺序执行。任一非 0 退出 = 钩子失败。

## 2. Superset 提供的 3 个环境变量

跑 setup/teardown/run 命令时:

| 变量 | 含义 |
|---|---|
| `SUPERSET_ROOT_PATH` | 主 repo 的绝对路径(用来定位 skill 安装位置 / 模板) |
| `SUPERSET_WORKSPACE_NAME` | 当前 workspace 名(通常 = branch 名) |
| `SUPERSET_WORKSPACE_PATH` | 当前 worktree 的绝对路径(命令执行时 cwd 就是这里) |

## 3. 配置文件查找优先级

Superset 读配置按这个顺序(找到第一个就用):

1. `~/.superset/projects/<project-id>/config.json` — **个人覆盖**(不进版本库)
2. `<worktree>/.superset/config.json` — **本 worktree 专用**(很少用)
3. `<repo-root>/.superset/config.json` — **项目默认**(进版本库,团队共享)

另外:`<repo-root>/.superset/config.local.json` 是**自动 gitignored** 的私人覆盖。

---

## 4. 推荐配置(本 skill 自带模板)

仓库根目录的 `.superset/config.json`(通过 `bash scripts/install-superset-config.sh` 安装):

```json
{
  "setup": [
    "echo '▸ Verifying Claude Code Actions config in $SUPERSET_ROOT_PATH'",
    "if [ -f \"$SUPERSET_ROOT_PATH/scripts/check-actions.sh\" ]; then bash \"$SUPERSET_ROOT_PATH/scripts/check-actions.sh\" || echo '⚠ Action 配置不全。在 root repo 跑 bash scripts/configure-actions.sh 一次性修。'; else echo 'ℹ scripts/check-actions.sh 不存在(skill 没装到本 repo?跳过校验)'; fi"
  ],
  "teardown": [
    "echo '▸ Workspace teardown for $SUPERSET_WORKSPACE_NAME'",
    "echo '提醒:本 worktree 对应的 PR 是否已 MERGED?如果是,在主 checkout 上跑:git worktree remove $SUPERSET_WORKSPACE_PATH && git branch -d <branch-name>'"
  ],
  "run": []
}
```

**为什么 setup 只校验不重做配置**:

- 装 GitHub App、生成 OAuth token、设 secret、推 workflow YAML 是 **repo-level 一次性**操作
- 每开新 workspace 重做这些会:浪费时间、token 重复生成、secret 反复覆盖
- 正确做法:首次手动 `bash scripts/configure-actions.sh` 跑一遍;之后 setup 只 `check-actions.sh` 校验

**为什么 teardown 不自动删 worktree**:

- 你在 worktree 里执行 teardown,删自己等于自杀(Superset force-delete 就是绕过这个失败)
- worktree 清理必须在主 checkout 上做(详见 SKILL.md "用户合并后的清理"段)

---

## 5. 团队共享 vs 个人覆盖

**团队共享部分**(进版本库):
- `.superset/config.json` — 默认 setup/teardown
- `.github/workflows/claude*.yml` — workflow 配置
- `templates/` — workflow 模板

**个人不进版本库**:
- `.superset/config.local.json` — 个人加的 setup 命令(如 `cp ~/private.env .env`)
- `~/.superset/projects/<id>/config.json` — 完全覆盖项目默认

---

## 6. 多 worktree 工作流的典型路径

零基础新仓库 → 第一次接入 Claude Code Actions + Superset:

```
┌─────────────────────────────────────────────┐
│ 主 checkout(repo root)                     │
│ $ cd ~/code/myrepo                          │
│ $ ln -s /path/to/worktree-pr-flow .claude/skills/  ← 装 skill │
│ $ bash scripts/configure-actions.sh         ← 一次性配 Actions │
│ $ bash scripts/install-superset-config.sh   ← 注入 Superset config │
│ $ git add .superset/ .github/ && git commit -m 'wire up Claude Code Actions' │
│ $ git push                                  │
└─────────────────────────────────────────────┘
                    │
                    │ Superset 用户开新 workspace
                    ▼
┌─────────────────────────────────────────────┐
│ Superset workspace #1(自动创建 worktree)   │
│ → 自动跑 setup → check-actions.sh → ✓        │
│ → 用户在终端写代码、按 SKILL.md 9 步流程     │
│ → PR open → Claude Code Action 自动 review   │
│ → @claude 修反馈 → auto-merge → MERGED       │
└─────────────────────────────────────────────┘
                    │
                    │ 同时再开 workspace #2 #3 ...
                    ▼
┌─────────────────────────────────────────────┐
│ workspace #2/#3 各自独立 worktree           │
│ 互不干扰、共享同一 repo 的 Actions 配置     │
└─────────────────────────────────────────────┘
```

后续仓库:重复主 checkout 那 4 行命令,每个 repo 配一次。

---

## 7. 调试 Superset 钩子

钩子失败时:

```bash
# 看 setup 输出(Superset 启动 workspace 时显示在终端 pane)
# 找到 "✗ ERROR" 或 "⚠ WARN" 行 → 对应 check-actions.sh 的检查项

# 手动跑校验(在 worktree 里)
bash "$SUPERSET_ROOT_PATH/scripts/check-actions.sh" -v

# 一次性修
cd "$SUPERSET_ROOT_PATH" && bash scripts/configure-actions.sh
```

如果 teardown 失败导致 workspace 删不掉:Superset 提供 **Force Delete**,跳过 teardown 直接删。**只在确认 teardown 命令本身错(而不是真有 docker volume / lock 没清)时用**。

---

## 8. 与 SKILL.md 9 步流程的关系

Superset setup 钩子**不参与** 9 步流程的执行,它只是**准备阶段**:

| Superset 阶段 | 对应 skill 流程 |
|---|---|
| Setup(workspace 创建) | **Pre-flight 之前**;校验通过 = skill 能跑;不通过 = 跑 configure-actions.sh 修 |
| 用户在终端跑 skill | 9 步流程(Pre-flight → 写代码 → 验证 → commit → push → PR → quality gate → auto-merge → babysit) |
| Teardown(workspace 删除) | **DoD 之后**;skill 已经把 PR merge 完了;teardown 提示用户在主 checkout 删 worktree |

---

## 9. 故障排查速查

| 现象 | 排查 |
|---|---|
| 新 workspace setup 报 `✗ scripts/check-actions.sh: No such file` | skill 没装到 repo,或 `.superset/config.json` 路径错。在 repo root 跑 `ls scripts/check-actions.sh` 确认 |
| setup 报 `gh CLI 未登录` | workspace 终端继承当前 user 的 ~/.config/gh,但若 Superset 跑在容器里可能没继承。在 workspace 终端跑 `gh auth login` |
| teardown 卡住 | 钩子里某条命令 hang。Force Delete 跳过 |
| Superset 找不到 `.superset/config.json` | 在 `<repo-root>` 而不是 worktree 里;或被 `~/.superset/projects/<id>/config.json` 覆盖了(去 ~/.superset/projects/ 看) |
| 想给本人加额外 setup 命令(如设私人 env) | 写到 `.superset/config.local.json`(自动 gitignore) |
