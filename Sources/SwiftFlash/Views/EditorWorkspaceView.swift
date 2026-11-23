import SwiftUI

struct EditorWorkspaceView: View {
    @ObservedObject var workspace: WorkspaceState
    @ObservedObject private var themeManager = ThemeManager.shared

    var body: some View {
        VStack(spacing: 0) {
            tabBar
                .layoutPriority(1)

            if let activeTab = workspace.activeTab {
                breadcrumbBar(for: activeTab)
                    .layoutPriority(1)

                HighPerformanceEditorRepresentable(workspace: workspace, activeTab: activeTab)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            } else {
                welcomeEmptyState
            }
        }
        .background(Color(nsColor: ZedTheme.background))
    }

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(workspace.openTabs) { tab in
                    TabItemView(
                        tab: tab,
                        isActive: tab.id == workspace.activeTabID,
                        onSelect: {
                            workspace.activeTabID = tab.id
                            workspace.onFocusEditorRequested?()
                        },
                        onClose: {
                            workspace.closeTab(id: tab.id)
                        }
                    )
                }
                Spacer(minLength: 0)
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

    private func breadcrumbBar(for tab: EditorTab) -> some View {
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
                shortcutRow(L10n("editor.welcome.switchProject"), shortcut: "⌘ ⇧ O")
                shortcutRow(L10n("editor.welcome.switchWorktree"), shortcut: "⌘ ⇧ W")
                shortcutRow(L10n("editor.welcome.switchBranch"), shortcut: "⌘ ⇧ B")
                shortcutRow(L10n("editor.welcome.settings"), shortcut: "⌘ ,")
                shortcutRow(L10n("editor.welcome.quickOpen"), shortcut: "⌘ P")
                shortcutRow(L10n("editor.welcome.globalSearch"), shortcut: "⌘ ⇧ F")
                shortcutRow(L10n("editor.welcome.toggleTerminal"), shortcut: "⌘ J")
                shortcutRow(L10n("editor.welcome.toggleSidebar"), shortcut: "⌘ B")
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
        .frame(width: 260)
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
