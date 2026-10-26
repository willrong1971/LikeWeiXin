#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIRECTORY="${1:-/Applications}"
APP_NAME="手机视窗.app"

if pgrep -x LikeWeiXin >/dev/null; then
  printf '请先退出“手机视窗”，再运行安装脚本。\n' >&2
  exit 1
fi

"$PROJECT_ROOT/build.sh"
mkdir -p "$INSTALL_DIRECTORY"
if [[ -d "$INSTALL_DIRECTORY/$APP_NAME" ]]; then
  BACKUP_DIRECTORY="$PROJECT_ROOT/.build/install-backups/$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "$BACKUP_DIRECTORY"
  ditto "$INSTALL_DIRECTORY/$APP_NAME" "$BACKUP_DIRECTORY/$APP_NAME"
fi
ditto "$PROJECT_ROOT/dist/$APP_NAME" "$INSTALL_DIRECTORY/$APP_NAME"
codesign --verify --strict "$INSTALL_DIRECTORY/$APP_NAME"
printf '已安装：%s/%s\n' "$INSTALL_DIRECTORY" "$APP_NAME"
