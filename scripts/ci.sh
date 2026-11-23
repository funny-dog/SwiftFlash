#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

echo "=== [CI] 1. 运行单元测试 (swift test) ==="
swift test

echo "=== [CI] 2. 编译 Release 版本 (swift build -c release) ==="
swift build -c release

echo "=== [CI] 3. 校验 Plist 与 Entitlements ==="
plutil -lint Resources/Info.plist Resources/SwiftFlash.entitlements

python3 - <<'PY'
import plistlib
import re
from pathlib import Path

with Path("Resources/Info.plist").open("rb") as f:
    info = plistlib.load(f)

version = info.get("CFBundleShortVersionString", "")
build = info.get("CFBundleVersion", "")
bundle_id = info.get("CFBundleIdentifier", "")

assert re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version), f"版本号格式必须为 x.y.z，实际为：{version!r}"
assert re.fullmatch(r"[0-9]+", str(build)) and int(build) >= 1, f"构建号必须为正整数，实际为：{build!r}"
assert bundle_id == "dev.swiftflash.ide", f"CFBundleIdentifier 异常：{bundle_id!r}"
print(f"Info.plist 校验通过：v{version} (build {build}), bundle_id={bundle_id}")
PY

echo "=== [CI] 4. 校验 Shell 脚本语法 ==="
for script in scripts/*.sh; do
  bash -n "$script"
done
echo "脚本语法校验通过"
