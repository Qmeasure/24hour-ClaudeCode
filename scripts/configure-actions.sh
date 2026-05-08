#!/usr/bin/env bash
# 交互式一次性配置 Claude Code Actions(repo-level)。
# 用户在新仓库**首次**跑一次。完成后:Claude GitHub App 装好、CLAUDE_CODE_OAUTH_TOKEN
# secret 设好、两个 workflow YAML 推到 .github/workflows/。
#
# 后续在该 repo 不需要再跑;每个 Superset 新 workspace 由 check-actions.sh 校验。
#
# Usage:
#   bash scripts/configure-actions.sh
#   bash scripts/configure-actions.sh --skip-app-install   # 已经手动装过 App
#   bash scripts/configure-actions.sh --dry-run            # 只检查,不写入

set -euo pipefail

# ---- Helpers ----
say()  { printf "\033[1;36m▸\033[0m %s\n" "$*"; }
ok()   { printf "\033[1;32m✓\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m⚠\033[0m %s\n" "$*" >&2; }
err()  { printf "\033[1;31m✗\033[0m %s\n" "$*" >&2; exit 1; }
ask()  { local prompt="$1" default="${2:-}"; local reply
        if [[ -n "$default" ]]; then prompt="$prompt [$default]"; fi
        read -r -p "$(printf '\033[1;35m?\033[0m %s: ' "$prompt")" reply
        echo "${reply:-$default}"; }

DRY=0
SKIP_APP=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY=1 ;;
    --skip-app-install) SKIP_APP=1 ;;
    -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) err "Unknown flag: $arg" ;;
  esac
done

# ---- Step 0: 前置环境检查 ----
say "Step 0: 检查前置工具"
command -v gh >/dev/null   || err "gh CLI 未安装。装:brew install gh(macOS)或 https://cli.github.com"
command -v claude >/dev/null || err "claude CLI 未安装。访问 https://code.claude.com"
command -v git >/dev/null  || err "git 未安装"

if ! gh auth status >/dev/null 2>&1; then
  err "gh CLI 未登录。跑:gh auth login"
fi

# 必须有 workflow scope
if ! gh auth status 2>&1 | grep -qE "scopes:.*workflow"; then
  warn "gh token 缺少 'workflow' scope(推 workflow YAML 需要)"
  if (( DRY == 0 )); then
    if [[ "$(ask 'Run gh auth refresh -s workflow now?' 'y')" =~ ^[Yy] ]]; then
      gh auth refresh -h github.com -s workflow
    else
      err "需要 workflow scope 才能继续"
    fi
  fi
fi
ok "前置工具就绪"

# ---- Step 1: 解析当前 repo ----
say "Step 1: 识别当前仓库"
REPO="$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null)" || err "当前目录不是 GitHub repo,或 gh 无访问权"
ok "目标仓库:$REPO"

# ---- Step 2: 装 GitHub App ----
if (( SKIP_APP == 0 )); then
  say "Step 2: 检查 / 安装 Claude GitHub App"
  echo "  打开浏览器:https://github.com/apps/claude → Install → 选你的账号 → Only select repositories → 勾 $REPO"
  if (( DRY == 0 )); then
    if [[ "$(ask 'Open in browser now?' 'y')" =~ ^[Yy] ]]; then
      open "https://github.com/apps/claude" 2>/dev/null || \
        xdg-open "https://github.com/apps/claude" 2>/dev/null || \
        echo "  (无法自动打开,请手动访问上面 URL)"
    fi
    echo ""
    read -r -p "$(printf '\033[1;35m?\033[0m App 已装到 %s,按回车继续...' "$REPO")"
  fi
  ok "App 安装步骤已通过"
else
  warn "已 --skip-app-install,跳过 App 检查"
fi

# ---- Step 3: 检查 / 生成 OAuth token,设进 secret ----
say "Step 3: 检查 OAuth token secret"
if gh secret list -R "$REPO" 2>/dev/null | grep -q "^CLAUDE_CODE_OAUTH_TOKEN"; then
  EXISTING_TIME=$(gh secret list -R "$REPO" | awk '$1=="CLAUDE_CODE_OAUTH_TOKEN" {print $2}')
  ok "secret 已存在(${EXISTING_TIME})"
  if [[ "$(ask 'Regenerate token anyway?' 'n')" =~ ^[Yy] ]]; then
    NEED_TOKEN=1
  else
    NEED_TOKEN=0
  fi
else
  warn "CLAUDE_CODE_OAUTH_TOKEN secret 不存在,需要生成"
  NEED_TOKEN=1
fi

if (( NEED_TOKEN == 1 )) && (( DRY == 0 )); then
  echo "  即将跑 'claude setup-token'。会弹浏览器走 OAuth(用你 Claude Pro/Max 订阅账号登录)。"
  echo "  完成后终端会打印一串 sk-ant-oat01-... 的 token。"
  echo "  请**复制下来**,下一步会让你粘贴。"
  read -r -p "$(printf '\033[1;35m?\033[0m 按回车开始,或 Ctrl+C 取消...')"
  claude setup-token || err "claude setup-token 失败"
  echo ""
  echo "  现在把刚才的 token 粘贴给 gh secret set:"
  gh secret set CLAUDE_CODE_OAUTH_TOKEN -R "$REPO" || err "gh secret set 失败"
  ok "secret 已写入 $REPO"
fi

# ---- Step 4: 推 workflow 模板 ----
say "Step 4: 检查 / 安装 workflow YAML"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="$SCRIPT_DIR/../templates"

if [[ ! -d "$TEMPLATE_DIR" ]]; then
  err "找不到 templates 目录:$TEMPLATE_DIR(skill 安装可能不完整)"
fi

mkdir -p .github/workflows

for f in claude.yml claude-code-review.yml; do
  TARGET=".github/workflows/$f"
  SRC="$TEMPLATE_DIR/$f"
  if [[ -f "$TARGET" ]]; then
    if cmp -s "$SRC" "$TARGET"; then
      ok "$TARGET 已存在(内容相同)"
    else
      warn "$TARGET 已存在但内容不同"
      if (( DRY == 0 )); then
        case "$(ask 'overwrite? (y) / skip (n) / show diff (d)' 'n')" in
          y|Y) cp "$SRC" "$TARGET"; ok "覆盖" ;;
          d|D) diff -u "$TARGET" "$SRC" || true; warn "请手动决定" ;;
          *)   warn "跳过" ;;
        esac
      fi
    fi
  else
    if (( DRY == 0 )); then
      cp "$SRC" "$TARGET"
      ok "已创建 $TARGET"
    else
      echo "  [dry-run] 会创建 $TARGET"
    fi
  fi
done

# ---- Step 5: 提示 commit + push ----
say "Step 5: 提交 workflow 文件"
if git status --porcelain .github/workflows | grep -q '.'; then
  if (( DRY == 0 )); then
    echo "  本地有未提交的 workflow 改动。建议:"
    echo ""
    echo "    git add .github/workflows/claude.yml .github/workflows/claude-code-review.yml"
    echo "    git commit -m 'Add Claude Code Actions workflows'"
    echo "    git push"
    echo ""
    if [[ "$(ask 'Run these now?' 'y')" =~ ^[Yy] ]]; then
      git add .github/workflows/claude.yml .github/workflows/claude-code-review.yml
      git commit -m "Add Claude Code Actions workflows"
      git push
      ok "已 push"
    else
      warn "请记得手动 push"
    fi
  fi
else
  ok "workflow 文件已 push 到 remote"
fi

# ---- Step 6: 最终验证 ----
say "Step 6: 健康检查"
bash "$SCRIPT_DIR/check-actions.sh" -R "$REPO" || warn "check-actions.sh 报告问题(见上)"

echo ""
ok "🎉 配置完成。按 SKILL.md 的 9 步流程开 PR 看 Action 自动 review。"
echo ""
echo "  开测试 PR(可选):"
echo "    git checkout -b test-claude-actions"
echo "    echo '<!-- test -->' >> README.md && git add README.md && git commit -m 'test: trigger review'"
echo "    git push -u origin test-claude-actions && gh pr create --fill"
