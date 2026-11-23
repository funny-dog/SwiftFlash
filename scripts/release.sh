#!/usr/bin/env bash
set -euo pipefail

# 发版脚本：校验 → 本地发版准备 → 单次推送 → 等待远端 CI → GitHub 正式发布 → Homebrew Cask 同步。
#
#   scripts/release.sh --check                           # 发版前只读校验，不修改任何文件
#   scripts/release.sh 1.0.0                             # 本地准备：校验 → 更新版本 → 本地 CI → 提交与打 tag → 签名打包 → 资产深度校验
#   scripts/release.sh 1.0.0 --publish                   # 全流程自动化发布：推送 main+tag → 等远端 CI → 核验后发布 Release → 同步 Homebrew Cask
#   scripts/release.sh 1.0.0 --publish --draft           # 仅创建 draft Release
#   scripts/release.sh 1.0.0 --publish --notes-file <f>  # 指定更新说明文件发布
#   scripts/release.sh 1.0.0 --sync-only                 # 仅对已正式发布的版本同步 Homebrew Cask

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

PLIST_PATH="Resources/Info.plist"
REPO_SLUG="funny-dog/SwiftFlash"

declare -a TIMING_NAMES=()
declare -a TIMING_DURATIONS=()
declare -a TIMING_STATUSES=()

fail() {
  echo "错误：$*" >&2
  exit 1
}

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1"
}

plist_set() {
  /usr/libexec/PlistBuddy -c "Set :$2 $3" "$1"
}

current_version() {
  plist_value "$PLIST_PATH" CFBundleShortVersionString
}

current_build() {
  plist_value "$PLIST_PATH" CFBundleVersion
}

run_timed_step() {
  local name="$1"
  shift
  local start_time
  start_time=$(date +%s)
  echo ""
  echo ">>> [开始] $name"
  local status
  set +e
  (
    set -e
    "$@"
  )
  status=$?
  set -e
  local end_time
  end_time=$(date +%s)
  local duration=$((end_time - start_time))
  TIMING_NAMES+=("$name")
  TIMING_DURATIONS+=("${duration}s")
  if [ $status -eq 0 ]; then
    TIMING_STATUSES+=("成功")
    echo ">>> [完成] $name (耗时 ${duration}s)"
  else
    TIMING_STATUSES+=("失败 (退出码 $status)")
    echo ">>> [失败] $name (耗时 ${duration}s, 退出码 $status)" >&2
    print_timing_summary
    return $status
  fi
}

print_timing_summary() {
  echo ""
  echo "========================================="
  echo "              发版耗时统计"
  echo "========================================="
  printf "| %-36s | %-10s | %-10s |\n" "阶段" "耗时" "状态"
  printf "|-%-36s-|-%-10s-|-%-10s-|\n" "------------------------------------" "----------" "----------"
  local total=0
  for i in "${!TIMING_NAMES[@]}"; do
    printf "| %-36s | %-10s | %-10s |\n" "${TIMING_NAMES[$i]}" "${TIMING_DURATIONS[$i]}" "${TIMING_STATUSES[$i]}"
    local d="${TIMING_DURATIONS[$i]%s}"
    total=$((total + d))
  done
  printf "| %-36s | %-10s | %-10s |\n" "总计" "${total}s" "-"
  echo "========================================="
  echo ""
}

check_plist_version() {
  [ -f "$PLIST_PATH" ] || fail "找不到 $PLIST_PATH"
  plutil -lint "$PLIST_PATH" >/dev/null
  local version build
  version="$(current_version)"
  build="$(current_build)"
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Info.plist 版本号格式应为 x.y.z，实际为：$version"
  [[ "$build" =~ ^[0-9]+$ ]] || fail "Info.plist 构建号应为整数，实际为：$build"
  echo "版本清单：v$version (build $build)，$PLIST_PATH 格式有效"
}

check_git_state() {
  local require_remote="${1:-0}"
  local branch
  branch="$(git rev-parse --abbrev-ref HEAD)"
  [ "$branch" = "main" ] || fail "发版请在 main 上进行，当前是 $branch"
  git rev-parse --verify HEAD >/dev/null 2>&1 || fail "当前分支尚无提交，请先完成初始提交后再发版"
  [ -z "$(git status --porcelain)" ] || fail "工作区不干净，先提交或清理改动：
$(git status --short)"

  if ! git remote get-url origin >/dev/null 2>&1; then
    if [ "$require_remote" = "1" ]; then
      fail "尚未配置远程仓库 origin，无法推送或发布"
    fi
    echo "Git 状态：main 干净（尚未配置远程仓库 origin）"
    return 0
  fi

  if ! git rev-parse --verify origin/main >/dev/null 2>&1; then
    git fetch --quiet origin main 2>/dev/null || true
  else
    git fetch --quiet origin main
  fi

  if ! git rev-parse --verify origin/main >/dev/null 2>&1; then
    echo "Git 状态：main 干净（origin 尚无 main 分支，将在发版时首次推送）"
    return 0
  fi

  local behind ahead
  behind="$(git rev-list --count HEAD..origin/main)"
  ahead="$(git rev-list --count origin/main..HEAD)"

  if [ "$behind" -gt 0 ]; then
    fail "本地 main 落后于 origin/main ($behind 个提交)，请先 pull / rebase"
  fi

  if [ "$ahead" -gt 0 ]; then
    echo "Git 状态：main 干净，本地超前 origin/main $ahead 个提交（将在发版时一并推送）"
  else
    echo "Git 状态：main 干净，且与 origin/main 完全同步"
  fi
}

check_ci_state() {
  if ! git remote get-url origin >/dev/null 2>&1; then
    echo "提示：尚未配置远程仓库 origin，跳过远端 CI 状态检查"
    return 0
  fi
  command -v gh >/dev/null 2>&1 || { echo "提示：未安装 gh，跳过远端 CI 状态检查"; return 0; }
  local origin_head
  origin_head="$(git rev-parse origin/main 2>/dev/null || true)"
  local conclusion=""
  if [ -n "$origin_head" ]; then
    conclusion="$(gh run list --workflow CI --commit "$origin_head" --json conclusion -q '.[0].conclusion' 2>/dev/null || true)"
  fi
  if [ -z "$conclusion" ]; then
    conclusion="$(gh run list --workflow CI --limit 1 --json conclusion -q '.[0].conclusion' 2>/dev/null || true)"
  fi
  case "$conclusion" in
    success) echo "CI 状态：远端最近一次运行成功" ;;
    "") echo "提示：读不到远端 CI 运行记录，本地将执行完整 CI" ;;
    *) fail "远端最近一次 CI 结果是 ${conclusion}，必须修复后再发版" ;;
  esac
}

check_signing_identity() {
  local name="${SWIFTFLASH_SIGN_IDENTITY:-SwiftFlash Self-Signed}"
  local identities
  identities="$(security find-identity -p codesigning ${SWIFTFLASH_KEYCHAIN:+"$SWIFTFLASH_KEYCHAIN"} 2>/dev/null || true)"
  if [[ "$identities" != *"\"$name\""* ]]; then
    fail "未在钥匙串中找到签名证书「${name}」。发版严禁使用 ad-hoc 签名！请先执行 bash scripts/setup-signing.sh"
  fi
  echo "代码签名证书：找到「${name}」"
}

check_installed_app_safety() {
  local installed="/Applications/SwiftFlash.app"
  if [ -d "$installed" ]; then
    local installed_ver installed_build
    installed_ver="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$installed/Contents/Info.plist" 2>/dev/null || true)"
    installed_build="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$installed/Contents/Info.plist" 2>/dev/null || true)"
    echo "本机已安装应用：/Applications/SwiftFlash.app (v${installed_ver} build ${installed_build}，发布流程不修改)"
  fi
}

is_first_release_same_version() {
  local new="$1"
  local current existing_tags
  current="$(current_version)"
  existing_tags="$(git tag -l 'v*')"
  [ -z "$existing_tags" ] && [ "$new" = "$current" ]
}

target_build_for_version() {
  local new="$1"
  if is_first_release_same_version "$new"; then
    current_build
  else
    echo $(( $(current_build) + 1 ))
  fi
}

check_new_version() {
  local new="$1" current
  current="$(current_version)"
  [[ "$new" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "版本号格式应为 x.y.z，收到：$new"

  if git rev-parse -q --verify "refs/tags/v$new" >/dev/null 2>&1; then
    fail "标签 v$new 已存在，请确认目标版本号或先处理本地标签"
  fi

  if is_first_release_same_version "$new"; then
    echo "首个版本发布：v$new (build $(current_build))"
    return 0
  fi

  [ "$new" != "$current" ] || fail "新版本号与当前版本相同（${current}）"
  if [ "$(printf '%s\n%s\n' "$current" "$new" | sort -V | tail -1)" != "$new" ]; then
    fail "新版本号 $new 必须大于当前版本 $current"
  fi
  echo "版本升级：$current → $new (build $(( $(current_build) + 1 )))"
}

bump_version_if_needed() {
  local new="$1"
  if is_first_release_same_version "$new"; then
    echo "首个版本沿用 $PLIST_PATH 中的 v$new (build $(current_build))"
    return 0
  fi
  local next_build=$(( $(current_build) + 1 ))
  plist_set "$PLIST_PATH" CFBundleShortVersionString "$new"
  plist_set "$PLIST_PATH" CFBundleVersion "$next_build"
  check_plist_version
}

verify_assets() {
  local version="$1"
  local build="$2"

  [ -f "SwiftFlash.dmg" ] || fail "缺少 SwiftFlash.dmg"
  [ -f "SwiftFlash.dmg.sha256" ] || fail "缺少校验文件 SwiftFlash.dmg.sha256"
  [ -f "SwiftFlash-v${version}.zip" ] || fail "缺少 SwiftFlash-v${version}.zip"
  [ -f "SwiftFlash-v${version}.zip.sha256" ] || fail "缺少校验文件 SwiftFlash-v${version}.zip.sha256"

  local stale_zip
  for stale_zip in SwiftFlash-v*.zip SwiftFlash-v*.zip.sha256; do
    [ -e "$stale_zip" ] || continue
    if [ "$stale_zip" != "SwiftFlash-v${version}.zip" ] && [ "$stale_zip" != "SwiftFlash-v${version}.zip.sha256" ]; then
      fail "仓库根目录存在旧版本发布件：${stale_zip}，请先清理"
    fi
  done

  (shasum -a 256 -c "SwiftFlash-v${version}.zip.sha256" >/dev/null) || fail "zip sha256 校验不通过"
  (shasum -a 256 -c "SwiftFlash.dmg.sha256" >/dev/null) || fail "dmg sha256 校验不通过"

  python3 - "$version" "$build" <<'PY'
import os
import plistlib
import subprocess
import sys
import zipfile
from pathlib import Path

version, build = sys.argv[1], sys.argv[2]
root = Path.cwd()
app = root / "build/dmg-stage/SwiftFlash.app"
assert app.exists(), "build/dmg-stage/SwiftFlash.app 不存在"

plist_path = app / "Contents/Info.plist"
with plist_path.open("rb") as f:
    info = plistlib.load(f)
assert (info["CFBundleShortVersionString"], str(info["CFBundleVersion"])) == (version, build), (
    f"SwiftFlash.app 版本或构建号不匹配: {info['CFBundleShortVersionString']} ({info['CFBundleVersion']})"
)

subprocess.run(["codesign", "--verify", "--strict", str(app)], check=True)
signature = subprocess.run(["codesign", "-dvv", str(app)], check=True, capture_output=True, text=True)
identity = os.environ.get("SWIFTFLASH_SIGN_IDENTITY", "SwiftFlash Self-Signed")
sig_text = signature.stderr + "\n" + signature.stdout
assert f"Authority={identity}" in sig_text.splitlines(), f"SwiftFlash.app 未使用发布证书「{identity}」签名"
assert any("flags=" in line and "runtime" in line for line in sig_text.splitlines()), "SwiftFlash.app 未启用 Hardened Runtime"

with zipfile.ZipFile(root / f"SwiftFlash-v{version}.zip") as z:
    names = [
        n for n in z.namelist()
        if n == "SwiftFlash.app/Contents/Info.plist"
    ]
    assert len(names) == 1, f"ZIP 内 Info.plist 数量不等于 1：{names}"
    zip_info = plistlib.loads(z.read(names[0]))
    assert (zip_info["CFBundleShortVersionString"], str(zip_info["CFBundleVersion"])) == (version, build), (
        f"ZIP 内 Info.plist 版本不匹配: {zip_info['CFBundleShortVersionString']} ({zip_info['CFBundleVersion']})"
    )

print("深度资产校验通过：SwiftFlash.app 严格签名、Hardened Runtime、版本与 ZIP 组件均一致")
PY
  echo "发布资产校验：dmg / dmg.sha256 / zip / zip.sha256 齐备，校验和匹配"
}

generate_release_notes() {
  local version="$1"
  local target_file="$2"
  local prev_tag
  prev_tag="$(git describe --tags --abbrev=0 "v${version}^" 2>/dev/null || true)"
  local range="v$version"
  if [ -n "$prev_tag" ]; then
    range="${prev_tag}..v$version"
  fi
  {
    echo "### 新增与优化"
    echo ""
    git log --pretty='- %s' "$range" | grep -v -E 'chore: 发布|chore\(release\)' || true
  } > "$target_file"
}

git_commit_and_tag() {
  local version="$1"
  local build="$2"
  if [ -n "$(git status --porcelain -- "$PLIST_PATH")" ]; then
    git add "$PLIST_PATH"
    git commit -m "chore: 发布 v${version}（构建号 ${build}）"
  fi
  git tag -a "v$version" -m "v$version"
}

git_push_main_and_tag() {
  local version="$1"
  echo "推送 main 与 tag v$version 到 GitHub..."
  git push --atomic origin main "v$version"
}

wait_for_remote_ci() {
  local target_sha="$1"
  echo "等待远端针对提交 $target_sha 的 GitHub Actions CI 启动..."
  local run_id=""
  for _ in {1..30}; do
    run_id="$(gh run list --workflow CI --commit "$target_sha" --json databaseId -q '.[0].databaseId' 2>/dev/null || true)"
    if [ -n "$run_id" ]; then
      break
    fi
    sleep 3
  done
  [ -n "$run_id" ] || fail "未能在 90 秒内检测到针对提交 $target_sha 的 CI 运行记录"
  echo "远端 CI 正在运行 (Run ID: $run_id)，等待完成..."
  gh run watch "$run_id" --exit-status
  echo "远端 GitHub Actions CI 运行通过！"
}

create_and_verify_release() {
  local version="$1"
  local notes_file="$2"
  local is_draft="$3"

  local title="v$version"
  local tag="v$version"
  echo "创建 GitHub draft Release ($tag)，校验后再公开..."
  gh release create "$tag" --draft --verify-tag --title "$title" --notes-file "$notes_file" \
    "SwiftFlash.dmg" "SwiftFlash.dmg.sha256" "SwiftFlash-v$version.zip" "SwiftFlash-v$version.zip.sha256"

  echo "核验远端 Release 资产与 SHA-256..."
  python3 - "$tag" "$is_draft" <<'PYTHON'
import hashlib
import json
import subprocess
import sys
from pathlib import Path

tag = sys.argv[1]
keep_draft = sys.argv[2] == "1"
data = json.loads(subprocess.check_output([
    "gh", "release", "view", tag,
    "--json", "tagName,isDraft,isPrerelease,assets",
]))
assert data.get("tagName") == tag
assert data.get("isDraft") is True, "校验资产时 Release 必须仍为 draft"
assert data.get("isPrerelease") is False, "Release 不应为 prerelease"

names = ["SwiftFlash.dmg", "SwiftFlash.dmg.sha256", f"SwiftFlash-{tag}.zip", f"SwiftFlash-{tag}.zip.sha256"]
selected = [a for a in data.get("assets", []) if a.get("name") in names]
assert len(selected) == 4, "四个资产必须齐备且无重复"
assets = {a["name"]: a for a in selected}
for name in names:
    assert name in assets, f"远端 Release 缺少资产: {name}"
    assert assets[name]["state"] == "uploaded", f"资产 {name} 未上传完成"
    local = Path(name)
    assert assets[name]["size"] == local.stat().st_size, f"资产 {name} 大小不符"
    digest = hashlib.sha256(local.read_bytes()).hexdigest()
    assert assets[name]["digest"] == f"sha256:{digest}", f"资产 {name} SHA-256 不符"
print(f"远端 Release {tag} 四个资产全部上传完成，SHA-256 校验一致")
if not keep_draft:
    subprocess.run(["gh", "release", "edit", tag, "--draft=false", "--latest"], check=True)
    published = json.loads(subprocess.check_output([
        "gh", "release", "view", tag, "--json", "tagName,isDraft,isPrerelease",
    ]))
    assert published.get("tagName") == tag
    assert published.get("isDraft") is False and published.get("isPrerelease") is False, "Release 未正式公开"
    print(f"正式发布完成：{tag}")
PYTHON
}

check_sync_version() {
  python3 - "$1" "$REPO_SLUG" <<'PYTHON'
import json
import subprocess
import sys

data = json.loads(subprocess.check_output([
    "gh", "release", "view", "--repo", sys.argv[2],
    "--json", "tagName,isDraft,isPrerelease",
]))
assert data.get("isDraft") is False and data.get("isPrerelease") is False, "只同步正式发布"
assert data.get("tagName") == f"v{sys.argv[1]}", f"请求版本不是最新正式版：{data.get('tagName')}；尚未执行渠道同步"
PYTHON
}

sync_homebrew_if_present() {
  local version="$1"
  local tap_dir
  tap_dir="$(brew --repository funny-dog/tap 2>/dev/null || true)"
  if [ -z "$tap_dir" ] || [ ! -d "$tap_dir" ]; then
    tap_dir="/opt/homebrew/Library/Taps/funny-dog/homebrew-tap"
  fi
  local cask_file="$tap_dir/Casks/swiftflash.rb"
  if [ -f "$cask_file" ]; then
    bash scripts/sync-homebrew-cask.sh "$version"
  else
    echo "提示：未在 $tap_dir 找到 Casks/swiftflash.rb，跳过自动同步。"
    echo "请先将 packaging/homebrew/swiftflash.rb 添加到 funny-dog/homebrew-tap 的 Casks/swiftflash.rb，再运行："
    echo "  bash scripts/sync-homebrew-cask.sh $version"
  fi
}

prepare_local_release() {
  local new_version="$1"
  check_new_version "$new_version"
  local target_build
  target_build="$(target_build_for_version "$new_version")"

  run_timed_step "更新版本清单 ($new_version build $target_build)" bump_version_if_needed "$new_version"
  run_timed_step "运行完整本地 CI (bash scripts/ci.sh)" bash scripts/ci.sh
  run_timed_step "提交版本变更并打本地 tag" git_commit_and_tag "$new_version" "$target_build"
  run_timed_step "签名并打包发布件 (RELEASE=1 bash scripts/build.sh)" env RELEASE=1 bash scripts/build.sh
  run_timed_step "深度校验发布资产与签名" verify_assets "$new_version" "$target_build"
  run_timed_step "安全复核（保留本机已安装版本）" check_installed_app_safety
}

publish_full_pipeline() {
  local version="$1"
  local notes_file="$2"
  local is_draft="$3"

  run_timed_step "单次推送 main 与 tag 到 GitHub" git_push_main_and_tag "$version"

  local release_sha
  release_sha="$(git rev-parse HEAD)"
  run_timed_step "等待远端 GitHub Actions CI 完成" wait_for_remote_ci "$release_sha"

  run_timed_step "创建 GitHub Release 并上传资产" create_and_verify_release "$version" "$notes_file" "$is_draft"

  if [ "$is_draft" = "1" ]; then
    echo "draft Release v$version 创建完成，等待在网页上补充说明并正式 Publish。"
    return 0
  fi

  run_timed_step "确认渠道同步的目标版本" check_sync_version "$version"
  run_timed_step "同步 Homebrew Cask" sync_homebrew_if_present "$version"
  run_timed_step "安全复核（保留本机已安装版本）" check_installed_app_safety
}

main() {
  MODE="release"
  VERSION_ARG=""
  PUBLISH=0
  DRAFT=0
  SYNC_ONLY=0
  NOTES_FILE=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --check) MODE="check"; shift ;;
      --publish) PUBLISH=1; shift ;;
      --draft) DRAFT=1; shift ;;
      --sync-only) SYNC_ONLY=1; shift ;;
      --notes-file)
        shift
        [ "$#" -gt 0 ] || fail "缺少 --notes-file 参数值"
        NOTES_FILE="$1"
        shift
        ;;
      -*) fail "未知参数：$1" ;;
      *)
        if [ -z "$VERSION_ARG" ]; then
          VERSION_ARG="$1"
        else
          fail "多余的参数：$1"
        fi
        shift
        ;;
    esac
  done

  if [ "$MODE" = "check" ]; then
    echo "=== 发版前校验 ==="
    check_git_state 0
    check_plist_version
    check_ci_state
    check_signing_identity
    check_installed_app_safety
    echo ""
    echo "发版前校验全部通过（未改动任何文件）。"
    exit 0
  fi

  [ -n "$VERSION_ARG" ] || fail "缺少版本号。用法：scripts/release.sh x.y.z [--publish] [--draft] [--notes-file <file>]"
  VERSION="${VERSION_ARG#v}"
  [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "版本号格式应为 x.y.z"

  if [ "$SYNC_ONLY" = "1" ]; then
    echo "=== 仅同步 Homebrew Cask：v$VERSION ==="
    run_timed_step "确认渠道同步的目标版本" check_sync_version "$VERSION"
    run_timed_step "同步 Homebrew Cask" sync_homebrew_if_present "$VERSION"
    run_timed_step "安全复核（保留本机已安装版本）" check_installed_app_safety
    print_timing_summary
    echo "同步完成：v$VERSION"
    exit 0
  fi

  echo "=== 发版前校验 ==="
  check_git_state "$PUBLISH"
  check_plist_version
  check_ci_state
  check_signing_identity

  TAG_AT_HEAD="$(git tag --points-at HEAD --list "v$VERSION")"
  IS_PREPARED=0
  if [ "$TAG_AT_HEAD" = "v$VERSION" ] && [ "$(current_version)" = "$VERSION" ]; then
    echo "检测到 HEAD 已打上标签 v${VERSION}，重新校验发布资产。"
    IS_PREPARED=1
    run_timed_step "恢复发布：深度校验发布资产与签名" verify_assets "$VERSION" "$(current_build)"
  fi

  if [ "$IS_PREPARED" = "0" ]; then
    echo ""
    echo "=== 执行本地发版准备 (Phase 1) ==="
    prepare_local_release "$VERSION"
  fi

  TMP_NOTES=""
  if [ -z "$NOTES_FILE" ]; then
    TMP_NOTES="$(mktemp "${TMPDIR:-/tmp}/swiftflash-release-notes-XXXXXX")"
    generate_release_notes "$VERSION" "$TMP_NOTES"
    NOTES_FILE="$TMP_NOTES"
  fi

  if [ "$PUBLISH" = "1" ]; then
    echo ""
    echo "=== 执行自动化发布与渠道同步 (Phase 2) ==="
    publish_full_pipeline "$VERSION" "$NOTES_FILE" "$DRAFT"
    [ -z "$TMP_NOTES" ] || rm -f "$TMP_NOTES"
    print_timing_summary
    echo "🎉 SwiftFlash v$VERSION 发布流程全部完成！"
    exit 0
  fi

  print_timing_summary
  echo "========================================="
  echo "  本地发版准备已完成（尚未推送到远端）"
  echo "========================================="
  echo "版本号：v$VERSION (构建号 $(current_build))"
  echo "本地最新提交：$(git log -1 --oneline)"
  echo "待推送标签：v$VERSION"
  echo ""
  echo "更新说明草稿预览 ($NOTES_FILE)："
  echo "-----------------------------------------"
  cat "$NOTES_FILE"
  echo "-----------------------------------------"
  echo ""
  echo "继续正式发布可执行："
  echo "  bash scripts/release.sh $VERSION --publish --notes-file \"$NOTES_FILE\""
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
