#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="手机视窗"
EXECUTABLE_NAME="LikeWeiXin"
APP_PATH="$PROJECT_ROOT/dist/$APP_NAME.app"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
ARCHITECTURE="$(uname -m)"
BUILD_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/likeweixin-build.XXXXXX")"
trap '/bin/rm -rf "$BUILD_STAGE"' EXIT

STAGED_APP="$BUILD_STAGE/$APP_NAME.app"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"

SOURCES=("$PROJECT_ROOT"/Sources/*.swift)
if [[ ! -f "${SOURCES[0]}" ]]; then
  printf '未找到 Sources/*.swift\n' >&2
  exit 1
fi

xcrun swiftc \
  -O -whole-module-optimization \
  -module-name "$EXECUTABLE_NAME" \
  -target "$ARCHITECTURE-apple-macosx13.0" \
  -sdk "$SDK_PATH" \
  -framework AppKit \
  -framework AVFoundation \
  -framework CoreMediaIO \
  -framework QuartzCore \
  "${SOURCES[@]}" \
  -o "$STAGED_APP/Contents/MacOS/$EXECUTABLE_NAME"

cp "$PROJECT_ROOT/Resources/Info.plist" "$STAGED_APP/Contents/Info.plist"
cp "$PROJECT_ROOT/Resources/AppIcon.icns" "$STAGED_APP/Contents/Resources/AppIcon.icns"
plutil -lint "$STAGED_APP/Contents/Info.plist"

# 本机使用版本采用 ad-hoc 签名，摄像头权限由系统 TCC 管理。
codesign --force --sign - --identifier local.will.LikeWeiXin "$STAGED_APP"
codesign --verify --strict "$STAGED_APP"

mkdir -p "$PROJECT_ROOT/dist"
ditto "$STAGED_APP" "$APP_PATH"
printf '已生成：%s\n' "$APP_PATH"
