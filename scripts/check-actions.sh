#!/usr/bin/env bash
# 非交互式校验仓库的 Claude Code Actions 配置状态。
# 用于 Superset workspace setup 钩子或人工排查。
#
# 检查项:
#   1. gh CLI 装了且登录了
#   2. CLAUDE_CODE_OAUTH_TOKEN(或 ANTHROPIC_API_KEY)secret 存在
#   3. .github/workflows/ 有 claude*.yml
#   4. 关键 workflow 字段:permissions、claude_code_oauth_token 引用、id-token: write
#
# Exit codes:
#   0 = 全部 OK
#   1 = 有 ERROR(配置缺失,流程会跑不通)
#   2 = 有 WARNING(能跑但不优,建议修)
#
# Usage:
#   bash scripts/check-actions.sh                  # 自动识别当前 repo
#   bash scripts/check-actions.sh -R owner/repo    # 指定 repo

set -euo pipefail

REPO=""
VERBOSE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -R|--repo) REPO="$2"; shift 2 ;;
    -v|--verbose) VERBOSE=1; shift ;;
    -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown: $1" >&2; exit 1 ;;
  esac
done

err()  { printf "\033[1;31m✗ ERROR\033[0m %s\n" "$*" >&2; ERR_COUNT=$((ERR_COUNT+1)); }
warn() { printf "\033[1;33m⚠ WARN\033[0m  %s\n" "$*" >&2; WARN_COUNT=$((WARN_COUNT+1)); }
ok()   { (( VERBOSE == 1 )) && printf "\033[1;32m✓ OK\033[0m    %s\n" "$*" || true; }
info() { (( VERBOSE == 1 )) && printf "\033[1;36mℹ\033[0m     %s\n" "$*" || true; }

ERR_COUNT=0
WARN_COUNT=0

# ---- 1. gh CLI ----
if ! command -v gh >/dev/null; then
  err "gh CLI 未装(brew install gh / https://cli.github.com)"
elif ! gh auth status >/dev/null 2>&1; then
  err "gh 未登录(跑:gh auth login)"
else
  ok "gh CLI 装好且登录"
fi

# ---- 2. 解析当前 repo(若没传 -R)----
if [[ -z "$REPO" ]]; then
  if ! REPO="$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null)"; then
    err "当前目录不是 GitHub repo,且没传 -R <owner/repo>"
    REPO=""
  fi
fi
[[ -n "$REPO" ]] && info "目标 repo:$REPO"

# ---- 3. Secret ----
if [[ -n "$REPO" ]]; then
  HAS_OAUTH=0
  HAS_API_KEY=0
  if gh secret list -R "$REPO" 2>/dev/null | grep -q "^CLAUDE_CODE_OAUTH_TOKEN"; then
    HAS_OAUTH=1
  fi
  if gh secret list -R "$REPO" 2>/dev/null | grep -q "^ANTHROPIC_API_KEY"; then
    HAS_API_KEY=1
  fi
  if (( HAS_OAUTH == 0 && HAS_API_KEY == 0 )); then
    err "$REPO 缺 CLAUDE_CODE_OAUTH_TOKEN 或 ANTHROPIC_API_KEY secret(跑 scripts/configure-actions.sh)"
  elif (( HAS_OAUTH == 1 && HAS_API_KEY == 1 )); then
    warn "同时有 OAuth token 和 API key,Action 会用 OAuth(确认这是你想要的)"
  else
    ok "认证 secret 已配置"
  fi
fi

# ---- 4. Workflow 文件 ----
if [[ -d .github/workflows ]]; then
  if ls .github/workflows/claude*.yml >/dev/null 2>&1; then
    ok "找到 .github/workflows/claude*.yml"
  else
    err ".github/workflows/ 没有 claude*.yml(跑 scripts/configure-actions.sh)"
  fi
else
  err "当前目录没有 .github/workflows/(可能不在 repo 根目录,或 workflow 还没写)"
fi

# ---- 5. Workflow 内容关键字段 ----
if [[ -f .github/workflows/claude.yml ]]; then
  CONTENT="$(cat .github/workflows/claude.yml)"

  # 5.1 secret 引用
  if echo "$CONTENT" | grep -qE 'claude_code_oauth_token|anthropic_api_key'; then
    ok "claude.yml 引用了认证 secret"
  else
    err "claude.yml 没引用 claude_code_oauth_token 或 anthropic_api_key"
  fi

  # 5.2 id-token: write(OIDC 必需)
  if echo "$CONTENT" | grep -qE 'id-token:\s*write'; then
    ok "claude.yml 有 id-token: write(OIDC OK)"
  else
    warn "claude.yml 缺 id-token: write,可能触发 OIDC 错误(参 official-docs-cheatsheet.md)"
  fi

  # 5.3 contents: write(允许 @claude 改代码所必需)
  if echo "$CONTENT" | grep -qE 'contents:\s*write'; then
    ok "claude.yml 有 contents: write(@claude 能 commit 修复)"
  else
    warn "claude.yml 是 contents: read。@claude 能评论但不能 commit 修复(SETUP.md §4.3)"
  fi

  # 5.4 timeout-minutes(防跑飞烧 quota)
  if echo "$CONTENT" | grep -qE 'timeout-minutes:'; then
    ok "claude.yml 有 timeout-minutes"
  else
    warn "claude.yml 没设 timeout-minutes,默认 6 小时(anti-patterns H5)"
  fi

  # 5.5 concurrency(防 push 风暴)
  if echo "$CONTENT" | grep -qE '^concurrency:'; then
    ok "claude.yml 有 concurrency 控制"
  else
    warn "claude.yml 没设 concurrency,push 多次会重复跑(anti-patterns H4)"
  fi
fi

# ---- 6. Superset 环境变量(信息性,不算 ERROR/WARN)----
if [[ -n "${SUPERSET_WORKSPACE_PATH:-}" ]]; then
  info "Superset workspace:${SUPERSET_WORKSPACE_NAME:-<未命名>} @ $SUPERSET_WORKSPACE_PATH"
fi

# ---- 总结 ----
echo ""
if (( ERR_COUNT > 0 )); then
  printf "\033[1;31m✗ %d ERROR\033[0m, \033[1;33m%d WARN\033[0m — 跑 \033[1;36mbash scripts/configure-actions.sh\033[0m 一键修\n" "$ERR_COUNT" "$WARN_COUNT"
  exit 1
elif (( WARN_COUNT > 0 )); then
  printf "\033[1;33m⚠ %d WARN\033[0m — 能跑,但建议优化(参 SETUP.md / references/anti-patterns.md)\n" "$WARN_COUNT"
  exit 2
else
  printf "\033[1;32m✓ All checks passed\033[0m — Claude Code Actions 配置 OK\n"
  exit 0
fi
