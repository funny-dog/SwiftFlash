import SwiftUI

struct StatusBarView: View {
    @ObservedObject var workspace: WorkspaceState
    @ObservedObject private var editorStatus: EditorStatusModel
    @ObservedObject private var taskRunner: TaskRunnerState
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var lspManager = LSPManager.shared

    init(workspace: WorkspaceState) {
        self.workspace = workspace
        self.editorStatus = workspace.editorStatus
        self.taskRunner = workspace.taskRunner
    }

    private var isExplorerActive: Bool {
        workspace.isSidebarVisible && workspace.sidebarMode == .explorer
    }

    private var isGitActive: Bool {
        workspace.isSidebarVisible && workspace.sidebarMode == .git
    }

    private var isSearchActive: Bool {
        workspace.isSidebarVisible && workspace.sidebarMode == .search
    }

    var body: some View {
        HStack(spacing: 12) {
            // Left: Zed-style Dock Switcher Icons (Project Tree | Git | Search)
            HStack(spacing: 6) {
                dockButton(isActive: isExplorerActive, helpText: L10n("statusbar.dock.explorerHelp")) {
                    workspace.toggleDockPanel(.explorer)
                } icon: {
                    ZedFileTreeDockIcon(
                        color: Color(nsColor: isExplorerActive ? ZedTheme.function : ZedTheme.primaryText)
                    )
                }

                dockButton(isActive: isGitActive, helpText: L10n("statusbar.dock.gitHelp")) {
                    workspace.toggleDockPanel(.git)
                } icon: {
                    ZStack(alignment: .topTrailing) {
                        ZedGitDockIcon(
                            color: Color(nsColor: isGitActive ? ZedTheme.function : ZedTheme.primaryText)
                        )
                        if !workspace.gitChanges.isEmpty {
                            Circle()
                                .fill(Color(nsColor: ZedTheme.function))
                                .frame(width: 5, height: 5)
                                .offset(x: 2, y: -1)
                        }
                    }
                }

                dockButton(isActive: isSearchActive, helpText: L10n("statusbar.dock.searchHelp")) {
                    workspace.toggleDockPanel(.search)
                } icon: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(Color(nsColor: isSearchActive ? ZedTheme.function : ZedTheme.secondaryText))
                }
            }

            Divider()
                .frame(height: 12)
                .overlay(Color(nsColor: ZedTheme.border))

            // Git branch switcher button & Engine badge
            Button {
                workspace.toggleOverlay(.branchSwitcher)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 10.5))
                        .foregroundColor(Color(nsColor: ZedTheme.keyword))
                    Text(workspace.gitBranch)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Color(nsColor: ZedTheme.primaryText))
                }
            }
            .buttonStyle(.plain)
            .help(L10n("header.branch.help"))

            Button {
                workspace.showBottomPanel(.problems)
            } label: {
                HStack(spacing: 6) {
                    HStack(spacing: 3) {
                        Image(systemName: "xmark.circle")
                            .font(.system(size: 10))
                            .foregroundColor(Color(nsColor: workspace.totalErrorCount > 0 ? NSColor(hex: 0xE06C75) : ZedTheme.mutedText))
                        Text("\(workspace.totalErrorCount)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(Color(nsColor: workspace.totalErrorCount > 0 ? ZedTheme.primaryText : ZedTheme.mutedText))
                    }
                    HStack(spacing: 3) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 10))
                            .foregroundColor(Color(nsColor: workspace.totalWarningCount > 0 ? NSColor(hex: 0xE5C07B) : ZedTheme.mutedText))
                        Text("\(workspace.totalWarningCount)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(Color(nsColor: workspace.totalWarningCount > 0 ? ZedTheme.primaryText : ZedTheme.mutedText))
                    }
                }
            }
            .buttonStyle(.plain)
            .help(L10n("statusbar.problemsHelp"))

            HStack(spacing: 5) {
                Circle()
                    .fill(Color(nsColor: ZedTheme.string))
                    .frame(width: 6, height: 6)
                Text("CoreText B-Tree • 120Hz")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color(nsColor: ZedTheme.secondaryText))
            }

            if editorStatus.lastRenderLatencyMs > 0 {
                Text(String(format: "%.2f ms", editorStatus.lastRenderLatencyMs))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(Color(nsColor: ZedTheme.operatorColor))
            }

            Text(editorStatus.statusMessage)
                .font(.system(size: 11))
                .foregroundColor(Color(nsColor: ZedTheme.mutedText))
                .lineLimit(1)

            Spacer()

            // Right: Theme/Font shortcut, Terminal toggle, Cursor, Encoding, Language
            Button {
                workspace.toggleOverlay(.settings)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "paintbrush")
                        .font(.system(size: 10))
                    Text("\(themeManager.editorFontFamily) \(Int(themeManager.editorFontSize))pt")
                        .font(.system(size: 11))
                }
                .foregroundColor(Color(nsColor: ZedTheme.secondaryText))
            }
            .buttonStyle(.plain)
            .help(L10n("header.settings.help"))

            Button {
                workspace.onToggleTerminalAction?()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "terminal")
                        .font(.system(size: 10.5))
                    Text(L10n("statusbar.terminal"))
                        .font(.system(size: 11))
                }
                .foregroundColor(workspace.isTerminalVisible ? Color(nsColor: ZedTheme.function) : Color(nsColor: ZedTheme.secondaryText))
            }
            .buttonStyle(.plain)
            .help(L10n("statusbar.terminal.help"))

            if let tab = workspace.activeTab {
                Divider()
                    .frame(height: 11)
                    .overlay(Color(nsColor: ZedTheme.border))

                Text(L10n("statusbar.cursorFormat", editorStatus.cursorLine, editorStatus.cursorColumn))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Color(nsColor: ZedTheme.primaryText))

                Text(L10n("statusbar.spacesFormat"))
                    .font(.system(size: 11))
                    .foregroundColor(Color(nsColor: ZedTheme.secondaryText))

                Text("UTF-8")
                    .font(.system(size: 11))
                    .foregroundColor(Color(nsColor: ZedTheme.secondaryText))

                Text(tab.language.rawValue)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color(nsColor: tab.language.iconColor))

                if let matchedLSP = lspManager.serverDefinition(for: tab.language, url: tab.url) {
                    lspStatusPill(for: matchedLSP)
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(Color(nsColor: ZedTheme.statusBarBackground))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color(nsColor: ZedTheme.border))
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private func lspStatusPill(for def: LSPServerDefinition) -> some View {
        let status = lspManager.status(for: def.id)
        let isRunning = lspManager.activeServerIDs.contains(def.id)

        let dotColor: NSColor = {
            if isRunning { return ZedTheme.string }
            switch status {
            case .detected, .installed: return ZedTheme.function
            case .installing: return ZedTheme.typeName
            case .failed: return ZedTheme.attribute
            case .notInstalled: return ZedTheme.mutedText
            }
        }()

        let labelText: String = {
            if case .installing(let progress) = status, let fraction = progress.fraction {
                return "\(def.displayName) \(Int((fraction * 100).rounded()))%"
            }
            return def.displayName
        }()

        Button {
            workspace.openSettings(section: .languageServers)
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(Color(nsColor: dotColor))
                    .frame(width: 6, height: 6)
                Text(labelText)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(Color(nsColor: isRunning || status.isReady ? ZedTheme.primaryText : ZedTheme.mutedText))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(nsColor: ZedTheme.background).opacity(0.75))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color(nsColor: ZedTheme.border), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help(L10n("statusbar.lsp.help"))
    }

    private func dockButton<Icon: View>(
        isActive: Bool,
        helpText: String,
        action: @escaping () -> Void,
        @ViewBuilder icon: () -> Icon
    ) -> some View {
        Button(action: action) {
            icon()
                .frame(width: 22, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isActive ? Color(nsColor: ZedTheme.hoverBackground).opacity(0.85) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(helpText)
    }
}

// MARK: - Zed Dock Vector Icons

private struct ZedFileTreeDockIcon: View {
    let color: Color

    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            let sx = w / 16.0
            let sy = h / 16.0

            var trunk = Path()
            trunk.move(to: CGPoint(x: 2.6 * sx, y: 2.8 * sy))
            trunk.addLine(to: CGPoint(x: 2.6 * sx, y: 13.0 * sy))

            trunk.move(to: CGPoint(x: 2.6 * sx, y: 4.5 * sy))
            trunk.addQuadCurve(
                to: CGPoint(x: 5.2 * sx, y: 5.1 * sy),
                control: CGPoint(x: 3.9 * sx, y: 5.1 * sy)
            )

            trunk.move(to: CGPoint(x: 2.6 * sx, y: 10.6 * sy))
            trunk.addQuadCurve(
                to: CGPoint(x: 5.2 * sx, y: 11.2 * sy),
                control: CGPoint(x: 3.9 * sx, y: 11.2 * sy)
            )

            context.stroke(
                trunk,
                with: .color(color),
                style: StrokeStyle(lineWidth: 1.55, lineCap: .round, lineJoin: .round)
            )

            let topPill = Path(
                roundedRect: CGRect(x: 6.4 * sx, y: 3.1 * sy, width: 7.1 * sx, height: 3.9 * sy),
                cornerRadius: 1.7
            )
            let bottomPill = Path(
                roundedRect: CGRect(x: 6.4 * sx, y: 9.0 * sy, width: 7.1 * sx, height: 3.9 * sy),
                cornerRadius: 1.7
            )
            context.fill(topPill, with: .color(color))
            context.fill(bottomPill, with: .color(color))
        }
        .frame(width: 15, height: 15)
    }
}

private struct ZedGitDockIcon: View {
    let color: Color

    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            let sx = w / 16.0
            let sy = h / 16.0

            let strokeStyle = StrokeStyle(lineWidth: 1.55, lineCap: .round, lineJoin: .round)

            var lines = Path()
            lines.move(to: CGPoint(x: 4.4 * sx, y: 2.7 * sy))
            lines.addLine(to: CGPoint(x: 4.4 * sx, y: 10.4 * sy))

            lines.move(to: CGPoint(x: 4.4 * sx, y: 9.4 * sy))
            lines.addQuadCurve(
                to: CGPoint(x: 9.6 * sx, y: 5.6 * sy),
                control: CGPoint(x: 5.1 * sx, y: 5.6 * sy)
            )
            context.stroke(lines, with: .color(color), style: strokeStyle)

            let bottomCircle = Path(
                ellipseIn: CGRect(x: 2.6 * sx, y: 10.4 * sy, width: 3.6 * sx, height: 3.6 * sy)
            )
            context.stroke(bottomCircle, with: .color(color), style: strokeStyle)

            let topRightCircle = Path(
                ellipseIn: CGRect(x: 9.6 * sx, y: 3.8 * sy, width: 3.6 * sx, height: 3.6 * sy)
            )
            context.stroke(topRightCircle, with: .color(color), style: strokeStyle)
        }
        .frame(width: 15, height: 15)
    }
}
