#!/usr/bin/env bash
set -euo pipefail

# 将 build/dmg-stage/SwiftFlash.app 安装到 /Applications 并启动，供本地直接使用与验收。

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

SOURCE_APP="$PROJECT_DIR/build/dmg-stage/SwiftFlash.app"
TARGET_APP="/Applications/SwiftFlash.app"

if [ ! -d "$SOURCE_APP" ]; then
  echo "错误：找不到 $SOURCE_APP，请先运行 bash scripts/build.sh" >&2
  exit 1
fi

echo "=== 1. 校验构建产物签名 ==="
codesign --verify --strict "$SOURCE_APP"
authority="$(codesign -dvv "$SOURCE_APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
if [ -n "$authority" ]; then
  echo "签名有效：$authority"
else
  echo "签名有效"
fi

echo "=== 2. 退出正在运行的 SwiftFlash ==="
pkill -f "$TARGET_APP/Contents/MacOS/SwiftFlash" 2>/dev/null || true
for _ in {1..20}; do
  if ! pgrep -f "$TARGET_APP/Contents/MacOS/SwiftFlash" >/dev/null; then
    break
  fi
  sleep 0.1
done

echo "=== 3. 覆盖安装到 $TARGET_APP ==="
rm -rf "$TARGET_APP"
cp -R "$SOURCE_APP" "$TARGET_APP"
codesign --verify --strict "$TARGET_APP"

echo "=== 4. 启动 ==="
open "$TARGET_APP"

echo ""
echo "=== 安装完成 ==="
echo "版本：$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$TARGET_APP/Contents/Info.plist")（构建号 $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$TARGET_APP/Contents/Info.plist")）"
echo "位置：$TARGET_APP"
