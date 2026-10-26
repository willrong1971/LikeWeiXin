#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/likeweixin-check.XXXXXX")"
trap '/bin/rm -rf "$CHECK_DIRECTORY"' EXIT

for script in "$PROJECT_ROOT/build.sh" "$PROJECT_ROOT/install.sh" "$PROJECT_ROOT/scripts/check.sh"; do
  bash -n "$script"
done
plutil -lint "$PROJECT_ROOT/Resources/Info.plist"
xcrun swiftc \
  "$PROJECT_ROOT/Sources/ViewerGeometry.swift" \
  "$PROJECT_ROOT/Tests/ViewerGeometryTests.swift" \
  -o "$CHECK_DIRECTORY/geometry-tests"
"$CHECK_DIRECTORY/geometry-tests"
iconutil -c iconset "$PROJECT_ROOT/Resources/AppIcon.icns" -o "$CHECK_DIRECTORY/AppIcon.iconset"
for icon in icon_16x16.png icon_16x16@2x.png icon_32x32.png icon_32x32@2x.png \
            icon_128x128.png icon_128x128@2x.png icon_256x256.png icon_256x256@2x.png \
            icon_512x512.png icon_512x512@2x.png; do
  test -s "$CHECK_DIRECTORY/AppIcon.iconset/$icon"
done
printf '构建脚本、配置、图标资源及几何检查通过。\n'
