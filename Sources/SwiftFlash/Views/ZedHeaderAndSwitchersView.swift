import AppKit
import SwiftUI

// MARK: - Window Drag Support for Full-Size Content Titlebar

private struct TitlebarWindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        DraggableTitlebarNSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DraggableTitlebarNSView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}

// MARK: - Zed Top Header Bar

struct ZedTopHeaderBarView: View {
    @ObservedObject var workspace: WorkspaceState
    @ObservedObject private var taskRunner: TaskRunnerState
    @ObservedObject private var themeManager = ThemeManager.shared

    init(workspace: WorkspaceState) {
        self.workspace = workspace
        self.taskRunner = workspace.taskRunner
    }

    var body: some View {
        ZStack {
            Color(nsColor: ZedTheme.tabBarBackground)
                .ignoresSafeArea()
            TitlebarWindowDragArea()

            HStack(spacing: 8) {
                // Reserve space for macOS traffic lights (close/minimize/zoom)
                Color.clear
                    .frame(width: 72, height: 1)

                // Project Selector Pill
                Button {
                    if workspace.hasWorkspaceOpen {
                        workspace.toggleOverlay(.projectSwitcher)
                    } else {
                        workspace.openFolderPanel()
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(workspace.hasWorkspaceOpen ? workspace.rootURL.lastPathComponent : L10n("menu.file.openFolder"))
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundColor(Color(nsColor: ZedTheme.pillText))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3.5)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color(nsColor: ZedTheme.pillBackground))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(
                                workspace.activeOverlay == .projectSwitcher
                                    ? Color(nsColor: ZedTheme.cursor).opacity(0.65)
                                    : Color.clear,
                                lineWidth: 1
                            )
                    )
                }
                .buttonStyle(.plain)
                .help(workspace.hasWorkspaceOpen ? L10n("header.project.help") : L10n("menu.file.openFolder"))

                // Worktree Selector
                Button {
                    workspace.toggleOverlay(.worktreeSwitcher)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.right.and.arrow.down.left")
                            .font(.system(size: 10.5, weight: .medium))
                        Text(workspace.isGitRepository ? workspace.currentWorktreeName : L10n("header.worktree.local"))
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                    }
                    .foregroundColor(
                        workspace.activeOverlay == .worktreeSwitcher
                            ? Color(nsColor: ZedTheme.primaryText)
                            : Color(nsColor: ZedTheme.secondaryText)
                    )
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(
                                workspace.activeOverlay == .worktreeSwitcher
                                    ? Color(nsColor: ZedTheme.hoverBackground)
                                    : Color.clear
                            )
                    )
                }
                .buttonStyle(.plain)
                .help(L10n("header.worktree.help"))

                Text("/")
                    .font(.system(size: 12))
                    .foregroundColor(Color(nsColor: ZedTheme.mutedText))

                // Branch Selector
                Button {
                    workspace.toggleOverlay(.branchSwitcher)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 10.5, weight: .medium))
                        Text(workspace.gitBranch)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                    }
                    .foregroundColor(
                        workspace.activeOverlay == .branchSwitcher
                            ? Color(nsColor: ZedTheme.primaryText)
                            : Color(nsColor: ZedTheme.secondaryText)
                    )
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(
                                workspace.activeOverlay == .branchSwitcher
                                    ? Color(nsColor: ZedTheme.hoverBackground)
                                    : Color.clear
                            )
                    )
                }
                .buttonStyle(.plain)
                .help(L10n("header.branch.help"))

                Spacer(minLength: 16)

                // Run / Test Task Controls
                if workspace.hasWorkspaceOpen, !taskRunner.detectedTasks.isEmpty {
                    HStack(spacing: 4) {
                        Menu {
                            ForEach(taskRunner.detectedTasks) { task in
                                Button {
                                    workspace.runTask(task)
                                } label: {
                                    HStack {
                                        Text("\(task.name)  (\(task.sourceLabel))")
                                        if task.id == taskRunner.selectedTask?.id {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(taskRunner.selectedTask?.name ?? L10n("runner.run"))
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundColor(Color(nsColor: ZedTheme.primaryText))
                                    .lineLimit(1)
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundColor(Color(nsColor: ZedTheme.mutedText))
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3.5)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(Color(nsColor: ZedTheme.background))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .stroke(Color(nsColor: ZedTheme.border).opacity(0.65), lineWidth: 1)
                            )
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help(L10n("runner.selectTaskHelp"))

                        if taskRunner.isRunning {
                            headerIconButton(
                                icon: "stop.fill",
                                title: nil,
                                isActive: true,
                                helpText: L10n("runner.stopHelp")
                            ) {
                                workspace.stopRunningTask()
                            }
                        } else {
                            headerIconButton(
                                icon: "play.fill",
                                title: nil,
                                isActive: false,
                                helpText: L10n("runner.runHelp")
                            ) {
                                workspace.runDefaultRunTask()
                            }
                        }

                        if taskRunner.detectedTasks.contains(where: { $0.kind == .test }) {
                            headerIconButton(
                                icon: "checkmark.diamond",
                                title: nil,
                                isActive: false,
                                helpText: L10n("runner.testHelp")
                            ) {
                                workspace.runDefaultTestTask()
                            }
                        }
                    }
                }

                // Right Utility Controls
                HStack(spacing: 6) {
                    headerIconButton(
                        icon: "magnifyingglass",
                        title: "⌘P",
                        isActive: workspace.activeOverlay == .quickOpen,
                        helpText: L10n("header.quickOpen.help")
                    ) {
                        workspace.toggleOverlay(.quickOpen)
                    }

                    headerIconButton(
                        icon: "paintbrush",
                        title: "\(themeManager.currentThemeID.rawValue) • \(Int(themeManager.editorFontSize))pt",
                        isActive: workspace.activeOverlay == .settings,
                        helpText: L10n("header.settings.help")
                    ) {
                        workspace.toggleOverlay(.settings)
                    }

                    headerIconButton(
                        icon: "sidebar.left",
                        title: nil,
                        isActive: workspace.isSidebarVisible,
                        helpText: L10n("header.sidebar.help")
                    ) {
                        workspace.onToggleSidebarAction?()
                    }

                    headerIconButton(
                        icon: "terminal",
                        title: nil,
                        isActive: workspace.isTerminalVisible,
                        helpText: L10n("header.terminal.help")
                    ) {
                        workspace.onToggleTerminalAction?()
                    }
                }
            }
            .padding(.trailing, 12)
        }
        .frame(height: 38)
        .ignoresSafeArea()
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: ZedTheme.border))
                .frame(height: 1)
        }
    }

    private func headerIconButton(
        icon: String,
        title: String?,
        isActive: Bool,
        helpText: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                if let title {
                    Text(title)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                }
            }
            .foregroundColor(
                isActive
                    ? Color(nsColor: ZedTheme.primaryText)
                    : Color(nsColor: ZedTheme.secondaryText)
            )
            .padding(.horizontal, 7)
            .padding(.vertical, 3.5)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isActive ? Color(nsColor: ZedTheme.activeTabBackground) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Color(nsColor: ZedTheme.border).opacity(isActive ? 0.9 : 0.45), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help(helpText)
    }
}

// MARK: - Unified Overlay Host

struct WorkspaceOverlayHostView: View {
    @ObservedObject var workspace: WorkspaceState
    @ObservedObject private var themeManager = ThemeManager.shared

    var body: some View {
        Group {
            switch workspace.activeOverlay {
            case .none:
                Color.clear
                    .allowsHitTesting(false)

            case .quickOpen:
                QuickOpenModalView(workspace: workspace)

            case .projectSwitcher:
                dropdownHost(leadingPadding: 74, width: 340) {
                    ZedProjectSwitcherView(workspace: workspace)
                }

            case .worktreeSwitcher:
                dropdownHost(leadingPadding: 170, width: 380) {
                    ZedWorktreeSwitcherView(workspace: workspace)
                }

            case .branchSwitcher:
                dropdownHost(leadingPadding: 245, width: 360) {
                    ZedBranchSwitcherView(workspace: workspace)
                }

            case .settings:
                ZStack {
                    Color.black.opacity(ZedTheme.isDark ? 0.42 : 0.22)
                        .ignoresSafeArea()
                        .onTapGesture {
                            workspace.dismissOverlay()
                        }

                    ThemeAndFontSettingsModalView(workspace: workspace)
                }
            }
        }
    }

    private func dropdownHost<Content: View>(
        leadingPadding: CGFloat,
        width: CGFloat,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.001)
                .ignoresSafeArea()
                .onTapGesture {
                    workspace.dismissOverlay()
                }

            content()
                .frame(width: width)
                .background(Color(nsColor: ZedTheme.sidebarBackground))
                .cornerRadius(9)
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(Color(nsColor: ZedTheme.border), lineWidth: 1)
                )
                .shadow(color: .black.opacity(ZedTheme.isDark ? 0.45 : 0.18), radius: 18, y: 8)
                .padding(.top, 39)
                .padding(.leading, leadingPadding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
