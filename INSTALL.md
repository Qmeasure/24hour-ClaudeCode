# 安装为 Claude Code skill

这个 skill 当前是一个独立目录(`worktree-pr-flow/`)。要让 Claude Code 自动加载并按 description 触发,需要软链或拷贝到 skills 目录。下面用 `<SKILL_DIR>` 表示当前 skill 目录的实际绝对路径(跑 `pwd` 拿到)。

## 跑这个 skill 之前

> ⚠️ **重要**:本 skill 假设目标仓库已部署 Claude Code Actions(secret + workflow YAML)。
>
> **零基础一键配置**:在目标 repo root 跑 `bash scripts/configure-actions.sh`,15 分钟搞定全部步骤。
>
> 不想用脚本就按 [SETUP.md](SETUP.md) 手动 6 步配。
>
> 已配过的仓库(已有 `.github/workflows/claude*.yml` + `gh secret list` 含 `CLAUDE_CODE_OAUTH_TOKEN`)直接跑 skill,不用重配。

## Superset 用户:推荐安装链路

如果你用 [Superset](https://docs.superset.sh) 客户端管理多 worktree,完整安装步骤是:

```bash
# 1. 装 skill(下面三选一)
ln -s "<SKILL_DIR>" ~/.claude/skills/worktree-pr-flow

# 2. 在主 repo 一次性配置 Claude Code Actions
cd <YOUR_REPO_ROOT>
bash ~/.claude/skills/worktree-pr-flow/scripts/configure-actions.sh

# 3. 注入 Superset 配置(自动每个新 workspace 校验 Actions)
bash ~/.claude/skills/worktree-pr-flow/scripts/install-superset-config.sh
git add .superset/ .github/ && git commit -m "wire up Claude Code Actions" && git push

# 4. 之后每次 Superset 开新 workspace,setup 钩子自动跑 check-actions.sh
#    (失败会提示你回主 repo 跑 configure-actions.sh)
```

详细工作流见 [references/superset-integration.md](references/superset-integration.md)。

## 选项 A:软链(推荐,单点维护)

```bash
ln -s "<SKILL_DIR>" ~/.claude/skills/worktree-pr-flow
```

之后改原目录的文件 = 立刻生效(通常重启 Claude Code session 后下一次新对话会重新扫 skills 目录)。

验证:

```bash
ls -la ~/.claude/skills/ | grep worktree-pr-flow
# 期望:lrwxr-xr-x ... worktree-pr-flow -> <SKILL_DIR>
```

## 选项 B:拷贝(独立副本)

```bash
cp -R "<SKILL_DIR>" ~/.claude/skills/
```

之后两份独立。原目录的改动不会自动同步到 skills 目录。

## 选项 C:放项目级 skills(仅本仓库可用)

```bash
mkdir -p <PROJECT_ROOT>/.claude/skills
cp -R "<SKILL_DIR>" <PROJECT_ROOT>/.claude/skills/
```

只在该项目仓库内可见。其他项目不可用,但好处是这个流程的命令(base 分支、包管理器、review agent 列表等)可以按本项目硬编码进 skill 副本里,语义更精确。

## 触发验证

安装完成后,在新 Claude Code 对话里说:

```
走 Path B 把这个 PR 提了
```

或:

```
我现在在 worktree 内,开 PR 然后 babysit 到 merged
```

应该能看到 Claude 自动加载这个 skill。如果没触发,检查 SKILL.md 顶部 frontmatter 的 description 是否包含用户说的关键词。

## 卸载

```bash
# 选项 A:删软链
rm ~/.claude/skills/worktree-pr-flow

# 选项 B:删拷贝
rm -rf ~/.claude/skills/worktree-pr-flow

# 选项 C:删项目级
rm -rf <PROJECT_ROOT>/.claude/skills/worktree-pr-flow
```

原目录文件不动。
