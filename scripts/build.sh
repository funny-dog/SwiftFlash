#!/usr/bin/env bash
set -euo pipefail

# 构建、签名并打包 SwiftFlash 到 build/（仅支持 Apple Silicon arm64，macOS 14+）。
# 默认不改动仓库根目录的发布产物，也不自动覆盖安装 /Applications/SwiftFlash.app。
# 如需生成可直接上传的发布件，传入环境变量：RELEASE=1 bash scripts/build.sh

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

PLIST_PATH="$PROJECT_DIR/Resources/Info.plist"
ENTITLEMENTS_PATH="$PROJECT_DIR/Resources/SwiftFlash.entitlements"
[ -f "$PLIST_PATH" ] || { echo "错误：找不到 $PLIST_PATH" >&2; exit 1; }
[ -f "$ENTITLEMENTS_PATH" ] || { echo "错误：找不到 $ENTITLEMENTS_PATH" >&2; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST_PATH")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST_PATH")"
STAGE_DIR="$PROJECT_DIR/build/dmg-stage"
APP_DIR="$STAGE_DIR/SwiftFlash.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

echo "=== 1. 编译 SwiftFlash v${VERSION} (${BUILD_NUMBER}) (Release) ==="
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
[ -x "$BIN_DIR/SwiftFlash" ] || { echo "错误：未找到可执行文件 $BIN_DIR/SwiftFlash" >&2; exit 1; }

echo "=== 2. 组装 App Bundle ==="
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BIN_DIR/SwiftFlash" "$MACOS_DIR/SwiftFlash"
cp "$PLIST_PATH" "$CONTENTS_DIR/Info.plist"
echo -n "APPL????" > "$CONTENTS_DIR/PkgInfo"

if [ -d "$BIN_DIR/SwiftFlash_SwiftFlash.bundle" ]; then
  cp -R "$BIN_DIR/SwiftFlash_SwiftFlash.bundle" "$RESOURCES_DIR/"
fi

if command -v xcrun >/dev/null 2>&1 && xcrun --find actool >/dev/null 2>&1; then
  echo "编译 AppIcon.icon (Light/Dark AppIcon)..."
  ACTOOL_PLIST="$(mktemp)"
  xcrun actool "$PROJECT_DIR/Resources/AppIcon.icon" \
    --compile "$RESOURCES_DIR" \
    --platform macosx \
    --minimum-deployment-target 14.0 \
    --app-icon AppIcon \
    --output-partial-info-plist "$ACTOOL_PLIST" >/dev/null
  rm -f "$ACTOOL_PLIST"
fi

# 硬校验：应用图标资源必须打进 SwiftFlash_SwiftFlash.bundle（避免在 Contents/Resources 下重复打包两份）
BUNDLE_RES_DIR="$RESOURCES_DIR/SwiftFlash_SwiftFlash.bundle/Contents/Resources"
if [ ! -d "$BUNDLE_RES_DIR" ]; then
  BUNDLE_RES_DIR="$RESOURCES_DIR/SwiftFlash_SwiftFlash.bundle"
fi
if [ ! -f "$BUNDLE_RES_DIR/AppIcon-Light.png" ] || [ ! -f "$BUNDLE_RES_DIR/AppIcon-Dark.png" ]; then
  echo "错误：SwiftFlash_SwiftFlash.bundle 缺少 AppIcon-Light.png 或 AppIcon-Dark.png" >&2
  exit 1
fi
if command -v xcrun >/dev/null 2>&1 && xcrun --find actool >/dev/null 2>&1; then
  if [ ! -f "$RESOURCES_DIR/Assets.car" ] && [ ! -f "$RESOURCES_DIR/AppIcon.icns" ]; then
    echo "错误：actool 未生成 Assets.car 或 AppIcon.icns" >&2
    exit 1
  fi
fi

echo "=== 3. 代码签名 ==="
SIGN_IDENTITY_NAME="${SWIFTFLASH_SIGN_IDENTITY:-SwiftFlash Self-Signed}"
identities="$(security find-identity -p codesigning ${SWIFTFLASH_KEYCHAIN:+"$SWIFTFLASH_KEYCHAIN"} 2>/dev/null || true)"
if [[ "$identities" == *"\"$SIGN_IDENTITY_NAME\""* ]]; then
  SIGN_IDENTITY="$SIGN_IDENTITY_NAME"
  echo "使用证书签名：$SIGN_IDENTITY"
elif [ "${RELEASE:-0}" = "1" ]; then
  echo "错误：未找到签名证书「${SIGN_IDENTITY_NAME}」。发版严禁使用 ad-hoc 签名！请先执行 bash scripts/setup-signing.sh" >&2
  exit 1
else
  SIGN_IDENTITY="-"
  echo "警告：未找到签名证书「${SIGN_IDENTITY_NAME}」，退回 ad-hoc 签名（仅限本地调试）。发布前请先运行 bash scripts/setup-signing.sh" >&2
fi

if [ -n "${SWIFTFLASH_KEYCHAIN:-}" ]; then
  codesign -s "$SIGN_IDENTITY" --keychain "$SWIFTFLASH_KEYCHAIN" --force -o runtime --entitlements "$ENTITLEMENTS_PATH" "$APP_DIR"
else
  codesign -s "$SIGN_IDENTITY" --force -o runtime --entitlements "$ENTITLEMENTS_PATH" "$APP_DIR"
fi

# 硬校验：签名有效且启用了 Hardened Runtime
codesign --verify --strict "$APP_DIR"
sig_info="$(codesign -dv "$APP_DIR" 2>&1)"
if [[ "$sig_info" != *"flags="*"runtime"* ]]; then
  echo "错误：$APP_DIR 未启用 Hardened Runtime" >&2
  exit 1
fi
echo "签名规则：$(codesign -d -r- "$APP_DIR" 2>&1 | sed -n 's/.*designated => //p')"

echo "=== 4. 创建 Applications 软链接 ==="
ln -shf /Applications "$STAGE_DIR/Applications"

echo "=== 5. 打包 DMG 与 ZIP ==="
mkdir -p "$PROJECT_DIR/build"
DMG_PATH="$PROJECT_DIR/build/SwiftFlash-$VERSION.dmg"
ZIP_PATH="$PROJECT_DIR/build/SwiftFlash-v$VERSION.zip"
DMG_SHA_PATH="$PROJECT_DIR/build/SwiftFlash.dmg.sha256"
ZIP_SHA_PATH="$PROJECT_DIR/build/SwiftFlash-v$VERSION.zip.sha256"
rm -f "$DMG_PATH" "$ZIP_PATH" "$ZIP_SHA_PATH" "$DMG_SHA_PATH"

hdiutil create -volname "SwiftFlash" -srcfolder "$STAGE_DIR" -ov -format UDZO "$DMG_PATH"

(cd "$STAGE_DIR" && zip -ry "$ZIP_PATH" SwiftFlash.app)
(cd "$PROJECT_DIR/build" && shasum -a 256 "SwiftFlash-v$VERSION.zip" > "SwiftFlash-v$VERSION.zip.sha256")
(cd "$PROJECT_DIR/build" && shasum -a 256 "SwiftFlash-$VERSION.dmg" > "SwiftFlash.dmg.sha256")

if [ "${RELEASE:-0}" = "1" ]; then
  echo "=== 6. 复制发布件到仓库根目录（RELEASE=1）==="
  rm -f "$PROJECT_DIR"/SwiftFlash-v*.zip "$PROJECT_DIR"/SwiftFlash-v*.zip.sha256
  cp "$DMG_PATH" "$PROJECT_DIR/SwiftFlash.dmg"
  cp "$ZIP_PATH" "$PROJECT_DIR/SwiftFlash-v$VERSION.zip"
  cp "$ZIP_SHA_PATH" "$PROJECT_DIR/SwiftFlash-v$VERSION.zip.sha256"
  (cd "$PROJECT_DIR" && shasum -a 256 "SwiftFlash.dmg" > "SwiftFlash.dmg.sha256")
  echo "发布件：SwiftFlash.dmg / SwiftFlash.dmg.sha256 / SwiftFlash-v$VERSION.zip（含 .sha256）"
else
  echo "提示：本次为本地验证构建，仓库根目录的发布件未被改动；需要发布件请用 RELEASE=1 bash scripts/build.sh"
fi

echo "=== 构建完成！==="
echo "DMG 产物: $DMG_PATH"
echo "ZIP 产物: $ZIP_PATH"
echo "SHA256:  $ZIP_SHA_PATH"
echo "SHA256:  $DMG_SHA_PATH"
