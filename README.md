<div align="center">

# SwiftFlash

**原生 Swift / AppKit + CoreText 打造的极速 macOS 轻量代码编辑器。**

**A fast native macOS code editor built with Swift, AppKit, and CoreText.**

免费开源 · 本地运行 / Free & open source · Runs locally on your Mac

[English](#english) · [中文](#中文) · [安全说明 / Security](SECURITY.md)

![platform](https://img.shields.io/badge/platform-macOS%2014%2B%20(Apple%20Silicon)-blue)
![license](https://img.shields.io/badge/license-MIT-green)

</div>

---

## 中文

### ✨ 功能

- ⚡ **CoreText 高性能编辑** —— 基于 `CodeEditTextView` 与 AppKit 原生渲染，支持语法高亮、行注释切换（`⌘/`）与低延迟大文件滚动。
- 🗂 **多项目、Worktree 与分支切换** —— 顶部栏一键切换最近项目（`⌘⇧O`）、Git Worktree（`⌘⇧W`）与分支（`⌘⇧B`）。
- 🔀 **内置 Git 面板与 Diff 视图** —— 查看变更（已暂存 / 未暂存 / 未跟踪）、提交历史、暂存/撤销修改与一键查看 Diff（`⌃⌘D`）。
- 🔍 **快速打开与全局搜索** —— `⌘P` 模糊定位工作区文件，`⌘⇧F` 全文检索并直达对应行。
- 💻 **集成终端** —— `⌘J` 随时呼出工作区集成终端，自动跟随当前项目目录。
- 🎨 **主题、字体与语言包插件** —— `⌘,` 调整多款深浅主题与排版参数，并可从 [swiftflash-plugins](https://github.com/funny-dog/swiftflash-plugins) 在线安装简体中文等界面语言包。

### 📥 安装

要求 **macOS 14+（Sonoma）、Apple Silicon（arm64）**。

#### 方式一：Homebrew（推荐）

```bash
brew install --cask funny-dog/tap/swiftflash
```

> Homebrew 安装会移除隔离属性以跳过 Gatekeeper 首次检查；若希望保留系统检查，请使用 DMG 安装。Tap 由本项目维护，并非 Homebrew 官方仓库。

#### 方式二：DMG 手动安装

前往 [GitHub Releases](https://github.com/funny-dog/SwiftFlash/releases/latest) 下载 `SwiftFlash.dmg`，拖入 `Applications`。当前版本为自签名、未经 Apple 公证，首次打开被拦截时，可在 **系统设置 → 隐私与安全性 → 仍要打开** 放行，或执行：

```bash
xattr -dr com.apple.quarantine /Applications/SwiftFlash.app
```

#### 方式三：从源码构建

```bash
bash scripts/build.sh
bash scripts/install-local.sh
```

> 开发者如需稳定证书签名，可先运行 `bash scripts/setup-signing.sh`。

### ⌨️ 常用快捷键

- `⌘O` / `⌘⇧O`：打开文件夹 / 切换项目
- `⌘P`：快速打开文件
- `⌘⇧F`：全局搜索
- `⌘⇧W` / `⌘⇧B`：切换 Git Worktree / 分支
- `⌘B` / `⌘⇧G` / `⌘J`：切换侧边栏 / Git 面板 / 集成终端
- `⌃⌘D`：查看 Git Diff
- `⌘,`：主题、字体与语言设置

---

## English

### ✨ Features

- ⚡ **CoreText High-Performance Editing** — Built natively with Swift, AppKit, and `CodeEditTextView` for responsive rendering, syntax highlighting, and line commenting (`⌘/`).
- 🗂 **Project, Worktree & Branch Switchers** — Quickly jump between projects (`⌘⇧O`), Git worktrees (`⌘⇧W`), and branches (`⌘⇧B`) from the titlebar.
- 🔀 **Integrated Git Panel & Diff Viewer** — Inspect staged/unstaged/untracked changes, browse commit history, commit changes, and view diffs (`⌃⌘D`).
- 🔍 **Quick Open & Workspace Search** — Fuzzy file navigation (`⌘P`) and workspace-wide text search (`⌘⇧F`).
- 💻 **Integrated Terminal** — Toggle a built-in shell (`⌘J`) synced to the active project directory.
- 🎨 **Themes, Typography & Language Packs** — Customize dark/light themes and fonts (`⌘,`), and install community language packs such as Simplified Chinese from [swiftflash-plugins](https://github.com/funny-dog/swiftflash-plugins).

### 📥 Installation

Requires **macOS 14+ (Sonoma)** on **Apple Silicon (arm64)**.

#### Option 1: Homebrew (Recommended)

```bash
brew install --cask funny-dog/tap/swiftflash
```

> The cask removes the quarantine attribute after installation to skip the Gatekeeper first-launch prompt. Use the DMG installer if you prefer to keep Gatekeeper checks intact.

#### Option 2: Manual DMG Install

Download `SwiftFlash.dmg` from [GitHub Releases](https://github.com/funny-dog/SwiftFlash/releases/latest) and drag `SwiftFlash.app` into `/Applications`. Because the release is self-signed and not notarized by Apple, allow it under **System Settings → Privacy & Security → Open Anyway**, or run:

```bash
xattr -dr com.apple.quarantine /Applications/SwiftFlash.app
```

#### Option 3: Build from Source

```bash
bash scripts/build.sh
bash scripts/install-local.sh
```

> Run `bash scripts/setup-signing.sh` once if you want to sign builds with a persistent self-signed certificate.

### 📄 License

[MIT License](LICENSE). Includes vendored [CodeEditTextView](Vendor/CodeEditTextView/LICENSE.md) (MIT).
