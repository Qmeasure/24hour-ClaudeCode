#!/usr/bin/env bash
# 把默认 .superset/config.json 注入到当前项目根目录。
# 如果已有 .superset/config.json,默认 merge(保留已有 setup/teardown 命令,追加我们的);
# --force 整个覆盖(谨慎)。
#
# Usage:
#   bash scripts/install-superset-config.sh
#   bash scripts/install-superset-config.sh --force
#   bash scripts/install-superset-config.sh --local        # 写到 .superset/config.local.json(自动 gitignore)

set -euo pipefail

FORCE=0
LOCAL=0
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    --local) LOCAL=1 ;;
    -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown: $arg" >&2; exit 1 ;;
  esac
done

say()  { printf "\033[1;36m▸\033[0m %s\n" "$*"; }
ok()   { printf "\033[1;32m✓\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m⚠\033[0m %s\n" "$*" >&2; }
err()  { printf "\033[1;31m✗\033[0m %s\n" "$*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$SCRIPT_DIR/../templates/superset-config.json"
[[ -f "$TEMPLATE" ]] || err "找不到模板:$TEMPLATE"

if (( LOCAL == 1 )); then
  TARGET=".superset/config.local.json"
else
  TARGET=".superset/config.json"
fi

mkdir -p .superset

if [[ ! -f "$TARGET" ]]; then
  cp "$TEMPLATE" "$TARGET"
  ok "已创建 $TARGET"
else
  if (( FORCE == 1 )); then
    cp "$TEMPLATE" "$TARGET"
    ok "已覆盖 $TARGET (--force)"
  else
    warn "$TARGET 已存在。用 --force 覆盖,或手动 merge:"
    echo "    cat $TEMPLATE   # 看模板内容,把 setup 数组追加到你现有的 config"
    exit 0
  fi
fi

# 提示加 .gitignore(local 版本)
if (( LOCAL == 1 )); then
  if [[ -f .gitignore ]] && ! grep -qE '^\.superset/config\.local\.json' .gitignore; then
    echo ".superset/config.local.json" >> .gitignore
    ok ".gitignore 已加 .superset/config.local.json"
  fi
fi

ok "下次 Superset 创建 workspace 会自动跑 check-actions.sh"
