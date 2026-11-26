import SwiftUI

struct EditorWorkspaceView: View {
    @ObservedObject var workspace: WorkspaceState
    @ObservedObject private var findState: EditorFindState
    @ObservedObject private var themeManager = ThemeManager.shared

    init(workspace: WorkspaceState) {
        self.workspace = workspace
        self.findState = workspace.findState
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
                .layoutPriority(1)

            if workspace.activeTab != nil {
                if findState.isFindBarVisible || findState.isGoToLineVisible {
                    EditorFindBarView(workspace: workspace, findState: findState)
                        .layoutPriority(1)
                }

                if workspace.isSplitEditorActive {
                    HSplitView {
                        editorPaneView(pane: .primary, tab: workspace.activeTab)
                            .frame(minWidth: 240, maxWidth: .infinity, maxHeight: .infinity)

                        editorPaneView(pane: .secondary, tab: workspace.secondaryTab ?? workspace.activeTab)
                            .frame(minWidth: 240, maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    editorPaneView(pane: .primary, tab: workspace.activeTab)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                welcomeEmptyState
            }
        }
        .background(Color(nsColor: ZedTheme.background))
    }

    // MARK: - Primary Tab Bar

    private var tabBar: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(workspace.openTabs) { tab in
                        let isActive = (!workspace.isSplitEditorActive && tab.id == workspace.activeTabID)
                            || (workspace.isSplitEditorActive && tab.id == workspace.focusedTabID)
                        TabItemView(
                            tab: tab,
                            isActive: isActive,
                            onSelect: {
                                workspace.selectTab(id: tab.id)
                            },
                            onClose: {
                                workspace.closeTab(id: tab.id)
                            }
                        )
                        .contextMenu {
                            Button(L10n("tab.context.openToSide")) {
                                workspace.openInSecondaryPane(tabID: tab.id)
                            }
                            Divider()
                            Button(L10n("tab.context.close")) {
                                workspace.closeTab(id: tab.id)
                            }
                            Button(L10n("tab.context.closeOthers")) {
                                workspace.closeOtherTabs(keeping: tab.id)
                            }
                            Button(L10n("tab.context.closeToRight")) {
                                workspace.closeTabsToRight(of: tab.id)
                            }
                            if let url = tab.url {
                                Divider()
                                Button(L10n("explorer.context.copyPath")) {
                                    workspace.copyPathToPasteboard(url, relative: false)
                                }
                                Button(L10n("explorer.context.copyRelativePath")) {
                                    workspace.copyPathToPasteboard(url, relative: true)
                                }
                                Button(L10n("explorer.context.revealInFinder")) {
                                    workspace.revealInFinder(url)
                                }
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
            }

            if !workspace.openTabs.isEmpty {
                Divider()
                    .frame(height: 16)
                    .overlay(Color(nsColor: ZedTheme.border))

                Button {
                    workspace.toggleSplitEditor()
                } label: {
                    Image(systemName: workspace.isSplitEditorActive ? "rectangle.split.2x1.fill" : "rectangle.split.2x1")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(
                            Color(nsColor: workspace.isSplitEditorActive ? ZedTheme.function : ZedTheme.secondaryText)
                        )
                        .frame(width: 30, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L10n("editor.split.toggleHelp"))
            }
        }
        .frame(height: 34)
        .background(Color(nsColor: ZedTheme.tabBarBackground))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: ZedTheme.border))
                .frame(height: 1)
        }
    }

    // MARK: - Single / Split Editor Pane

    @ViewBuilder
    private func editorPaneView(pane: EditorPane, tab: EditorTab?) -> some View {
        let isFocusedPane = !workspace.isSplitEditorActive || workspace.focusedEditorPane == pane

        VStack(spacing: 0) {
            if workspace.isSplitEditorActive {
                splitPaneHeader(pane: pane, tab: tab, isFocused: isFocusedPane)
                    .layoutPriority(1)
            }

            if let tab {
                breadcrumbBar(for: tab, isFocusedPane: isFocusedPane)
                    .layoutPriority(1)

                if tab.hasExternalConflict {
                    externalConflictBanner(for: tab)
                        .layoutPriority(1)
                }

                HighPerformanceEditorRepresentable(workspace: workspace, activeTab: tab, pane: pane)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            } else {
                Spacer()
            }
        }
        .overlay(alignment: .top) {
            if workspace.isSplitEditorActive && isFocusedPane {
                Rectangle()
                    .fill(Color(nsColor: ZedTheme.cursor))
                    .frame(height: 1.5)
            }
        }
    }

    private func splitPaneHeader(pane: EditorPane, tab: EditorTab?, isFocused: Bool) -> some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(workspace.openTabs) { item in
                    Button {
                        workspace.selectTab(id: item.id, in: pane)
                    } label: {
                        HStack {
                            Text(item.title)
                            if item.id == tab?.id {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    if let tab {
                        Image(systemName: tab.language.iconName)
                            .font(.system(size: 10.5))
                            .foregroundColor(Color(nsColor: tab.language.iconColor))
                        Text(tab.title)
                            .font(.system(size: 11.5, weight: isFocused ? .semibold : .regular))
                            .foregroundColor(Color(nsColor: isFocused ? ZedTheme.primaryText : ZedTheme.secondaryText))
                            .lineLimit(1)
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundColor(Color(nsColor: ZedTheme.mutedText))
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer()

            if pane == .secondary {
                Button {
                    workspace.closeSplitEditor()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundColor(Color(nsColor: ZedTheme.secondaryText))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .help(L10n("editor.split.closeHelp"))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(Color(nsColor: isFocused ? ZedTheme.activeTabBackground : ZedTheme.tabBarBackground))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: ZedTheme.border))
                .frame(height: 1)
        }
        .onTapGesture {
            workspace.focusPane(pane)
        }
    }

    private func externalConflictBanner(for tab: EditorTab) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11.5))
                .foregroundColor(Color(nsColor: ZedTheme.typeName))

            Text(L10n("editor.externalConflict.message", tab.title))
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(Color(nsColor: ZedTheme.primaryText))
                .lineLimit(1)

            Spacer()

            Button {
                workspace.reloadConflictedTab(id: tab.id)
            } label: {
                Text(L10n("editor.externalConflict.reload"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color(nsColor: ZedTheme.pillText))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: ZedTheme.pillBackground)))
            }
            .buttonStyle(.plain)

            Button {
                workspace.keepLocalChangesForTab(id: tab.id)
            } label: {
                Text(L10n("editor.externalConflict.keepLocal"))
                    .font(.system(size: 11))
                    .foregroundColor(Color(nsColor: ZedTheme.secondaryText))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: ZedTheme.background)))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(nsColor: ZedTheme.border), lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: ZedTheme.activeTabBackground))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: ZedTheme.typeName).opacity(0.6))
                .frame(height: 1)
        }
    }

    private func breadcrumbBar(for tab: EditorTab, isFocusedPane: Bool) -> some View {
        HStack(spacing: 6) {
            let rel = tab.virtualKey != nil ? tab.title : workspace.relativePath(for: tab.url)
            let parts = rel.split(separator: "/").map(String.init)
            ForEach(Array(parts.enumerated()), id: \.offset) { idx, part in
                if idx > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundColor(Color(nsColor: ZedTheme.mutedText))
                }
                Text(part)
                    .font(.system(size: 11))
                    .foregroundColor(
                        idx == parts.count - 1
                            ? Color(nsColor: ZedTheme.primaryText)
                            : Color(nsColor: ZedTheme.secondaryText)
                    )
                    .lineLimit(1)
            }

            if isFocusedPane, let sym = workspace.currentBreadcrumbSymbol {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundColor(Color(nsColor: ZedTheme.mutedText))

                Button {
                    workspace.toggleOverlay(.symbolOutline)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: sym.kind.iconName)
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundColor(Color(nsColor: NSColor(hex: sym.kind.badgeColorHex)))
                        Text(sym.name)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(Color(nsColor: ZedTheme.function))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: ZedTheme.hoverBackground).opacity(0.6)))
                }
                .buttonStyle(.plain)
                .help(L10n("symbols.breadcrumbHelp"))
            }

            Spacer()

            if tab.isDirty {
                Text(L10n("editor.modifiedHint"))
                    .font(.system(size: 10.5))
                    .foregroundColor(Color(nsColor: ZedTheme.typeName))
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 24)
        .background(Color(nsColor: ZedTheme.background))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: ZedTheme.border).opacity(0.6))
                .frame(height: 1)
        }
    }

    private var welcomeEmptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 40))
                .foregroundColor(Color(nsColor: ZedTheme.function))

            Text("SwiftFlash IDE")
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .foregroundColor(Color(nsColor: ZedTheme.primaryText))

            Text(L10n("editor.welcome.subtitle"))
                .font(.system(size: 13))
                .foregroundColor(Color(nsColor: ZedTheme.secondaryText))

            Button {
                workspace.openFolderPanel()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 12, weight: .medium))
                    Text(L10n("menu.file.openFolder"))
                        .font(.system(size: 13, weight: .medium))
                    Text("⌘ O")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(Color(nsColor: ZedTheme.function))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(nsColor: ZedTheme.background).opacity(0.8))
                        .cornerRadius(4)
                }
                .foregroundColor(Color(nsColor: ZedTheme.primaryText))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color(nsColor: ZedTheme.pillBackground))
                .cornerRadius(7)
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(Color(nsColor: ZedTheme.border), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 8) {
                shortcutRow(L10n("commandPalette.title"), shortcut: "⌘ ⇧ P")
                shortcutRow(L10n("editor.welcome.quickOpen"), shortcut: "⌘ P")
                shortcutRow(L10n("symbols.title"), shortcut: "⌘ ⇧ O")
                shortcutRow(L10n("editor.welcome.globalSearch"), shortcut: "⌘ ⇧ F")
                shortcutRow(L10n("editor.welcome.switchWorktree"), shortcut: "⌘ ⇧ W")
                shortcutRow(L10n("editor.welcome.switchBranch"), shortcut: "⌘ ⇧ B")
                shortcutRow(L10n("editor.welcome.toggleTerminal"), shortcut: "⌘ J")
                shortcutRow(L10n("editor.welcome.settings"), shortcut: "⌘ ,")
            }
            .padding(16)
            .background(Color(nsColor: ZedTheme.sidebarBackground))
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color(nsColor: ZedTheme.border), lineWidth: 1)
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func shortcutRow(_ label: String, shortcut: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(Color(nsColor: ZedTheme.secondaryText))
            Spacer(minLength: 40)
            Text(shortcut)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(Color(nsColor: ZedTheme.function))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color(nsColor: ZedTheme.background))
                .cornerRadius(4)
        }
        .frame(width: 280)
    }
}

private struct TabItemView: View {
    let tab: EditorTab
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    @ObservedObject private var themeManager = ThemeManager.shared
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: tab.language.iconName)
                .font(.system(size: 11))
                .foregroundColor(Color(nsColor: tab.language.iconColor))

            Text(tab.title)
                .font(.system(size: 12, weight: isActive ? .medium : .regular))
                .foregroundColor(isActive ? Color(nsColor: ZedTheme.primaryText) : Color(nsColor: ZedTheme.secondaryText))
                .lineLimit(1)

            Button(action: onClose) {
                if tab.isDirty && !isHovered {
                    Circle()
                        .fill(Color(nsColor: ZedTheme.typeName))
                        .frame(width: 7, height: 7)
                } else {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(Color(nsColor: isHovered ? ZedTheme.primaryText : ZedTheme.mutedText))
                }
            }
            .buttonStyle(.plain)
            .frame(width: 14, height: 14)
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(isActive ? Color(nsColor: ZedTheme.activeTabBackground) : Color.clear)
        .overlay(alignment: .top) {
            if isActive {
                Rectangle()
                    .fill(Color(nsColor: ZedTheme.cursor))
                    .frame(height: 2)
            }
        }
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color(nsColor: ZedTheme.border))
                .frame(width: 1)
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(perform: onSelect)
    }
}
