# worktree-pr-flow

> A Claude Code Skill that drives a worktree-based feature → PR → multi-agent review → auto-merge → babysit-to-MERGED loop, with first-class Claude Code Actions integration.

把"在 worktree 里写代码 → 提 PR → 等 cloud agent review → 改反馈 → auto-merge → babysit 到 `state=MERGED`"这套 9 步流程编码成可稳定复现的 Skill。任何在 worktree 内开发并需要把 feature 合入项目 base 分支(dev/main/master 等)的任务都按这个走。

## 这个 skill 解决什么问题

LLM 默认习惯是"做完阶段性工作就停下来汇报"——但完整 PR 流程要求**一气从 step 1 跑到 `state=MERGED`**,中途任何"我做完 X 了,要继续吗?"都让用户必须手动 nudge。

这个 skill 把全流程编码成:

1. **Pre-flight 5 项检查**(worktree / 分支 / 工作树 / issue 编号 / Actions 配置)
2. **写代码 → 本地验证 → commit → push → 开 PR**(标准开发)
3. **Quality gate**:多 agent review 评估(Reject / Major / Minor / Nit 矩阵 + 时序硬规则)
4. **Auto-merge enable**(紧跟 review 静默,不停下问)
5. **Babysit loop**(用 Monitor 跑 6 条铁律的状态机,一直到 `state=MERGED` 或 60min cap)

**Definition of Done = `state=MERGED`**——auto-merge enabled / CI 绿 / review approved 都不算。

## 谁该用

- 在 worktree 里开发 feature / fix 的 Claude Code 用户
- 仓库装了 [Claude Code Actions](https://github.com/anthropics/claude-code-action)(本 skill 主要假设)
- 用 [Superset](https://docs.superset.sh) 客户端管理多 worktree 的(可选,有专门集成)

## 快速开始

### 一键配置(推荐)

```bash
# 1) 装 skill 到全局(symlink,改文件即生效)
ln -s "$(pwd)" ~/.claude/skills/worktree-pr-flow

# 2) 在你的目标 repo 一次性配 Claude Code Actions(交互 ~15 分钟)
cd ~/code/your-repo
bash ~/.claude/skills/worktree-pr-flow/scripts/configure-actions.sh

# 3) (可选)Superset 用户:注入 .superset/config.json
bash ~/.claude/skills/worktree-pr-flow/scripts/install-superset-config.sh
```

完成后,在新 Claude Code 对话里说:

```
走 Path B 把这个 PR 提了
```

或:

```
我在 worktree 内,开 PR 然后 babysit 到 merged
```

skill 会自动加载。

### 手动 / 详细配置

→ [SETUP.md](SETUP.md) — 6 步零基础配置
→ [INSTALL.md](INSTALL.md) — skill 自身的 3 种安装方式

## 文件地图

```
worktree-pr-flow/
├── README.md                           ← 你正在看这个
├── SKILL.md                            ← 主入口:9 步流程 + DoD
├── SETUP.md                            ← 零基础首次配置 Claude Code Actions
├── INSTALL.md                          ← 把 skill 装到 ~/.claude/skills/
├── CHECKLIST.md                        ← 每 step 一条的自审速查
├── scripts/
│   ├── configure-actions.sh            ← 一键交互式配置(SETUP.md 的 Quick path)
│   ├── check-actions.sh                ← 非交互式校验(Superset setup 调用)
│   └── install-superset-config.sh      ← 注入 .superset/config.json
├── templates/
│   ├── claude.yml                      ← @claude 交互 workflow 模板
│   ├── claude-code-review.yml          ← 自动 PR review workflow 模板
│   └── superset-config.json            ← Superset 配置模板
└── references/
    ├── workflow-yaml.md                ← 30+ Action 参数 + claude_args + GH Actions 字段全参考
    ├── monitor-template.md             ← Monitor verbatim 模板 + 6 条铁律
    ├── quality-gate.md                 ← 多 agent review 评估细则(档位 A / B 时序)
    ├── decision-table.md               ← Babysit 事件处理矩阵
    ├── anti-patterns.md                ← 失败模式 A–H 共 8 类
    ├── blockers.md                     ← 唯一允许停下来问用户的 8 个场景
    ├── superset-integration.md         ← Superset 多 worktree 接入
    └── official-docs-cheatsheet.md     ← claude-code-action 官方 docs 关键 10 条
```

## 设计哲学

这个 skill **刻意**采用以下风格,违反"通用 Anthropic skill"惯例,因为它们解决具体踩坑:

| 选择 | 通用 skill 做法 | 本 skill 做法 | 原因 |
|---|---|---|---|
| description 语言 | 纯英文 | 中英混合,大量 trigger 关键词 | 中文用户的实际触发词("走 Path B")必须命中 |
| Anti-pattern | 隐式(假设用户专业) | 显式(8 类 A–H,每条带真实事故) | LLM 容易复现历史失败模式,**显式列出**才有约束力 |
| Verbatim 标记 | 较少 | 较多("铁律"、"verbatim",尤其是 Monitor 模板) | Monitor 6 铁律每条对应一次"沉默十几分钟用户以为合上了"事故 |
| References 数量 | 很少(0–1 个) | 8 个 | 9 步流程 × 多种边界 = 单文件塞不下,且需要按主题查 |
| 项目适配显式列表 | 不写 | 7 个变量表(包管理器 / base 分支 / 等) | 跨语言 / 跨包管理器复用必须显式参数化 |

如果你在改这个 skill,**先看 references/anti-patterns.md** 理解失败模式,再动笔。

## 配套使用

- **GitHub Actions**:[anthropics/claude-code-action](https://github.com/anthropics/claude-code-action)(本 skill 假设你的仓库装了这个)
- **客户端**:[Superset](https://docs.superset.sh)(可选;每开新 workspace 自动校验配置)
- **Skill 框架**:[Claude Code](https://code.claude.com)(本 skill 跑在 Claude Code 客户端里)

## 开发 / 贡献

本仓库自身用本 skill 描述的 9 步流程开发——meta dogfood:

- 任何改动开 PR 到 `main`
- `.github/workflows/claude-code-review.yml` 自动以**专业 Skill Creator** 视角 review(prompt 在 workflow 文件里)
- `@claude` 在 PR / issue / review comment 里也以 Skill Creator 视角响应
- 9 个 Skill-Creator 维度自动评估(详见 workflow 文件 prompt):discoverability / anti-pattern explicitness / verbatim 安全 / cross-doc 一致 / reference 正交 / 项目适配 / DoD 可测量 / 触发词保留 / 内部链接

## License

(Per Anthropic terms of use; see official documentation.)

## Links

- [Anthropic Claude Code](https://code.claude.com)
- [Claude Code Action repo](https://github.com/anthropics/claude-code-action)
- [Superset docs](https://docs.superset.sh)
