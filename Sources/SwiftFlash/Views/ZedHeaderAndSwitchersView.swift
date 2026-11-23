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
    @ObservedObject private var themeManager = ThemeManager.shared

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

// MARK: - Shared Switcher Primitives

private struct SwitcherKeyboardHandler: ViewModifier {
    let itemCount: Int
    @Binding var selectedIndex: Int
    @Binding var keyboardScrollNonce: Int
    let onSubmit: () -> Void
    let onDismiss: () -> Void

    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear {
                installMonitor()
            }
            .onDisappear {
                removeMonitor()
            }
    }

    private func installMonitor() {
        removeMonitor()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch Int(event.keyCode) {
            case 53: // Escape
                onDismiss()
                return nil
            case 125: // Down Arrow
                if itemCount > 0 {
                    selectedIndex = min(selectedIndex + 1, itemCount - 1)
                    keyboardScrollNonce &+= 1
                }
                return nil
            case 126: // Up Arrow
                if itemCount > 0 {
                    selectedIndex = max(selectedIndex - 1, 0)
                    keyboardScrollNonce &+= 1
                }
                return nil
            default:
                return event
            }
        }
    }

    private func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}

private struct SwitcherSearchInput: View {
    let placeholder: String
    @Binding var query: String
    @FocusState private var isFocused: Bool
    let onSubmit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            TextField(placeholder, text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .foregroundColor(Color(nsColor: ZedTheme.primaryText))
                .focused($isFocused)
                .onSubmit(onSubmit)

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(Color(nsColor: ZedTheme.mutedText))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                isFocused = true
            }
        }
    }
}

private struct SwitcherSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundColor(Color(nsColor: ZedTheme.mutedText))
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private func fuzzyMatches(query: String, candidate: String) -> Bool {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return true }
    let q = Array(trimmed.lowercased())
    let c = Array(candidate.lowercased())
    var qi = 0
    for ch in c {
        if qi < q.count && ch == q[qi] {
            qi += 1
        }
    }
    return qi == q.count
}

private func abbreviatedPath(_ url: URL) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let path = url.path
    if path.hasPrefix(home) {
        return "~" + path.dropFirst(home.count)
    }
    return path
}

// MARK: - 1. Zed Project / Directory Switcher

struct ZedProjectSwitcherView: View {
    @ObservedObject var workspace: WorkspaceState
    @ObservedObject private var themeManager = ThemeManager.shared
    @State private var query: String = ""
    @State private var selectedIndex: Int = 0
    @State private var hoveredIndex: Int? = nil
    @State private var keyboardScrollNonce: Int = 0

    private var windowMatches: [URL] {
        workspace.windowProjects.filter { fuzzyMatches(query: query, candidate: $0.lastPathComponent) }
    }

    private var recentMatches: [URL] {
        let windowPaths = Set(workspace.windowProjects.map { $0.standardized.path })
        return workspace.recentProjects.filter { url in
            !windowPaths.contains(url.standardized.path)
                && fuzzyMatches(query: query, candidate: url.lastPathComponent)
        }
    }

    private var combinedItems: [URL] {
        windowMatches + recentMatches
    }

    var body: some View {
        VStack(spacing: 0) {
            SwitcherSearchInput(placeholder: L10n("switcher.project.searchPlaceholder"), query: $query) {
                selectHighlighted()
            }

            Divider().overlay(Color(nsColor: ZedTheme.border))

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        if !windowMatches.isEmpty {
                            SwitcherSectionHeader(title: L10n("switcher.project.thisWindow"))
                            ForEach(Array(windowMatches.enumerated()), id: \.element.path) { idx, url in
                                projectRow(url: url, index: idx)
                            }
                        }

                        if !recentMatches.isEmpty {
                            if !windowMatches.isEmpty {
                                Divider()
                                    .overlay(Color(nsColor: ZedTheme.border).opacity(0.65))
                                    .padding(.vertical, 4)
                            }
                            SwitcherSectionHeader(title: L10n("switcher.project.recentProjects"))
                            ForEach(Array(recentMatches.enumerated()), id: \.element.path) { offset, url in
                                let globalIdx = windowMatches.count + offset
                                projectRow(url: url, index: globalIdx)
                            }
                        }

                        if combinedItems.isEmpty {
                            Text(L10n("switcher.project.empty"))
                                .font(.system(size: 12))
                                .foregroundColor(Color(nsColor: ZedTheme.mutedText))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 16)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 360)
                .onChange(of: keyboardScrollNonce) { _, _ in
                    proxy.scrollTo(selectedIndex)
                }
            }

            Divider().overlay(Color(nsColor: ZedTheme.border))

            VStack(spacing: 2) {
                footerActionRow(title: L10n("switcher.project.openFolders"), icon: "folder") {
                    workspace.dismissOverlay()
                    workspace.openFolderPanel()
                }
                footerActionRow(title: L10n("switcher.project.addFolder"), icon: "folder.badge.plus") {
                    workspace.dismissOverlay()
                    workspace.addFolderToWindowPanel()
                }
            }
            .padding(.vertical, 5)
        }
        .onChange(of: query) { _, _ in
            selectedIndex = 0
            hoveredIndex = nil
            keyboardScrollNonce &+= 1
        }
        .modifier(
            SwitcherKeyboardHandler(
                itemCount: combinedItems.count,
                selectedIndex: $selectedIndex,
                keyboardScrollNonce: $keyboardScrollNonce,
                onSubmit: selectHighlighted,
                onDismiss: { workspace.dismissOverlay() }
            )
        )
    }

    private func projectRow(url: URL, index: Int) -> some View {
        let isCurrent = url.standardized.path == workspace.rootURL.standardized.path
        let isSelected = index == selectedIndex
        let isHovered = index == hoveredIndex
        return Button {
            workspace.switchProject(to: url)
        } label: {
            HStack(spacing: 8) {
                Text(url.lastPathComponent)
                    .font(.system(size: 13.5, weight: isCurrent ? .medium : .regular))
                    .foregroundColor(Color(nsColor: ZedTheme.primaryText))
                    .lineLimit(1)

                if isCurrent {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Color(nsColor: ZedTheme.function))
                }

                Spacer()

                if isSelected || isHovered {
                    Text(abbreviatedPath(url.deletingLastPathComponent()))
                        .font(.system(size: 10.5))
                        .foregroundColor(Color(nsColor: ZedTheme.mutedText))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(
                        isSelected
                            ? Color(nsColor: ZedTheme.selectionBackground)
                            : (isHovered ? Color(nsColor: ZedTheme.hoverBackground) : Color.clear)
                    )
                    .padding(.horizontal, 4)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(index)
        .onHover { hovering in
            if hovering {
                hoveredIndex = index
            } else if hoveredIndex == index {
                hoveredIndex = nil
            }
        }
    }

    private func footerActionRow(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundColor(Color(nsColor: ZedTheme.secondaryText))
                Text(title)
                    .font(.system(size: 13))
                    .foregroundColor(Color(nsColor: ZedTheme.primaryText))
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5.5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func selectHighlighted() {
        let items = combinedItems
        guard !items.isEmpty else { return }
        let idx = min(max(0, selectedIndex), items.count - 1)
        workspace.switchProject(to: items[idx])
    }
}

// MARK: - 2. Zed Git Worktree Switcher

struct ZedWorktreeSwitcherView: View {
    @ObservedObject var workspace: WorkspaceState
    @ObservedObject private var themeManager = ThemeManager.shared
    @State private var query: String = ""
    @State private var selectedIndex: Int = 0
    @State private var hoveredIndex: Int? = nil
    @State private var keyboardScrollNonce: Int = 0

    private var filteredWorktrees: [GitWorktreeItem] {
        workspace.gitWorktrees.filter { item in
            fuzzyMatches(query: query, candidate: item.name)
                || fuzzyMatches(query: query, candidate: item.branch)
        }
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 0) {
            SwitcherSearchInput(
                placeholder: L10n("switcher.worktree.searchPlaceholder"),
                query: $query
            ) {
                handleSubmit()
            }

            Divider().overlay(Color(nsColor: ZedTheme.border))

            if !workspace.isGitRepository {
                VStack(spacing: 10) {
                    Text(L10n("git.notARepo.detail"))
                        .font(.system(size: 12.5))
                        .foregroundColor(Color(nsColor: ZedTheme.secondaryText))

                    Button {
                        workspace.initializeGitRepository()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "plus.circle.fill")
                            Text(L10n("git.init.buttonFull"))
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Color(nsColor: ZedTheme.pillText))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color(nsColor: ZedTheme.pillBackground))
                        )
                    }
                    .buttonStyle(.plain)
                }
                .padding(18)
                .frame(maxWidth: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            SwitcherSectionHeader(title: L10n("switcher.worktree.section"))

                            ForEach(Array(filteredWorktrees.enumerated()), id: \.element.id) { idx, wt in
                                worktreeRow(wt, index: idx)
                            }

                            if !trimmedQuery.isEmpty {
                                Button {
                                    workspace.createAndSwitchWorktree(named: trimmedQuery)
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: "plus.square.on.square")
                                            .font(.system(size: 12))
                                            .foregroundColor(Color(nsColor: ZedTheme.string))
                                        Text(L10n("switcher.worktree.createFormat", trimmedQuery))
                                            .font(.system(size: 12.5, weight: .medium))
                                            .foregroundColor(Color(nsColor: ZedTheme.primaryText))
                                        Spacer()
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .background(
                                        RoundedRectangle(cornerRadius: 4)
                                            .fill(Color(nsColor: ZedTheme.hoverBackground).opacity(0.6))
                                            .padding(.horizontal, 4)
                                    )
                                }
                                .buttonStyle(.plain)
                                .padding(.top, 4)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(maxHeight: 300)
                    .onChange(of: keyboardScrollNonce) { _, _ in
                        proxy.scrollTo(selectedIndex)
                    }
                }

                Divider().overlay(Color(nsColor: ZedTheme.border))

                Button {
                    workspace.dismissOverlay()
                    workspace.openFolderPanel()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "folder.badge.gearshape")
                            .font(.system(size: 12))
                            .foregroundColor(Color(nsColor: ZedTheme.secondaryText))
                        Text(L10n("switcher.worktree.openFolder"))
                            .font(.system(size: 12.5))
                            .foregroundColor(Color(nsColor: ZedTheme.primaryText))
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .onChange(of: query) { _, _ in
            selectedIndex = 0
            hoveredIndex = nil
            keyboardScrollNonce &+= 1
        }
        .modifier(
            SwitcherKeyboardHandler(
                itemCount: filteredWorktrees.count,
                selectedIndex: $selectedIndex,
                keyboardScrollNonce: $keyboardScrollNonce,
                onSubmit: handleSubmit,
                onDismiss: { workspace.dismissOverlay() }
            )
        )
    }

    private func worktreeRow(_ wt: GitWorktreeItem, index: Int) -> some View {
        let isSelected = index == selectedIndex
        let isHovered = index == hoveredIndex
        return Button {
            workspace.switchWorktree(to: wt)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.up.right.and.arrow.down.left")
                    .font(.system(size: 11))
                    .foregroundColor(Color(nsColor: wt.isCurrent ? ZedTheme.function : ZedTheme.secondaryText))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(wt.name)
                            .font(.system(size: 13, weight: wt.isCurrent ? .semibold : .regular))
                            .foregroundColor(Color(nsColor: ZedTheme.primaryText))
                        if !wt.branch.isEmpty {
                            Text(wt.branch)
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundColor(Color(nsColor: ZedTheme.pillText))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Color(nsColor: ZedTheme.pillBackground))
                                )
                        }
                    }

                    Text(abbreviatedPath(wt.url))
                        .font(.system(size: 10.5))
                        .foregroundColor(Color(nsColor: ZedTheme.mutedText))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                if wt.isCurrent {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Color(nsColor: ZedTheme.function))
                } else if !wt.commitShort.isEmpty {
                    Text(wt.commitShort)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(Color(nsColor: ZedTheme.mutedText))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(
                        isSelected
                            ? Color(nsColor: ZedTheme.selectionBackground)
                            : (isHovered ? Color(nsColor: ZedTheme.hoverBackground) : Color.clear)
                    )
                    .padding(.horizontal, 4)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(index)
        .onHover { hovering in
            if hovering {
                hoveredIndex = index
            } else if hoveredIndex == index {
                hoveredIndex = nil
            }
        }
    }

    private func handleSubmit() {
        let items = filteredWorktrees
        if !items.isEmpty {
            let idx = min(max(0, selectedIndex), items.count - 1)
            workspace.switchWorktree(to: items[idx])
        } else if !trimmedQuery.isEmpty {
            workspace.createAndSwitchWorktree(named: trimmedQuery)
        }
    }
}

// MARK: - 3. Zed Git Branch Switcher

struct ZedBranchSwitcherView: View {
    @ObservedObject var workspace: WorkspaceState
    @ObservedObject private var themeManager = ThemeManager.shared
    @State private var query: String = ""
    @State private var selectedIndex: Int = 0
    @State private var hoveredIndex: Int? = nil
    @State private var keyboardScrollNonce: Int = 0

    private var localBranches: [GitBranchItem] {
        workspace.gitBranches.filter { !$0.isRemote && fuzzyMatches(query: query, candidate: $0.name) }
    }

    private var remoteBranches: [GitBranchItem] {
        workspace.gitBranches.filter { $0.isRemote && fuzzyMatches(query: query, candidate: $0.name) }
    }

    private var combinedBranches: [GitBranchItem] {
        localBranches + remoteBranches
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canCreateBranch: Bool {
        !trimmedQuery.isEmpty && !workspace.gitBranches.contains(where: { !$0.isRemote && $0.name == trimmedQuery })
    }

    var body: some View {
        VStack(spacing: 0) {
            SwitcherSearchInput(
                placeholder: L10n("switcher.branch.searchPlaceholder"),
                query: $query
            ) {
                handleSubmit()
            }

            Divider().overlay(Color(nsColor: ZedTheme.border))

            if !workspace.isGitRepository {
                VStack(spacing: 10) {
                    Text(L10n("git.notARepo.detail"))
                        .font(.system(size: 12.5))
                        .foregroundColor(Color(nsColor: ZedTheme.secondaryText))

                    Button {
                        workspace.initializeGitRepository()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "plus.circle.fill")
                            Text(L10n("git.init.buttonFull"))
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Color(nsColor: ZedTheme.pillText))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color(nsColor: ZedTheme.pillBackground))
                        )
                    }
                    .buttonStyle(.plain)
                }
                .padding(18)
                .frame(maxWidth: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            if !localBranches.isEmpty {
                                SwitcherSectionHeader(title: L10n("switcher.branch.local"))
                                ForEach(Array(localBranches.enumerated()), id: \.element.id) { idx, branch in
                                    branchRow(branch, index: idx)
                                }
                            }

                            if !remoteBranches.isEmpty {
                                if !localBranches.isEmpty {
                                    Divider()
                                        .overlay(Color(nsColor: ZedTheme.border).opacity(0.65))
                                        .padding(.vertical, 4)
                                }
                                SwitcherSectionHeader(title: L10n("switcher.branch.remote"))
                                ForEach(Array(remoteBranches.enumerated()), id: \.element.id) { offset, branch in
                                    branchRow(branch, index: localBranches.count + offset)
                                }
                            }

                            if combinedBranches.isEmpty && !canCreateBranch {
                                Text(L10n("switcher.branch.empty"))
                                    .font(.system(size: 12))
                                    .foregroundColor(Color(nsColor: ZedTheme.mutedText))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 14)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(maxHeight: 320)
                    .onChange(of: keyboardScrollNonce) { _, _ in
                        proxy.scrollTo(selectedIndex)
                    }
                }

                if canCreateBranch {
                    Divider().overlay(Color(nsColor: ZedTheme.border))
                    Button {
                        workspace.switchGitBranch(to: trimmedQuery, createNew: true)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 12))
                                .foregroundColor(Color(nsColor: ZedTheme.string))
                            Text(L10n("switcher.branch.createFormat", trimmedQuery))
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundColor(Color(nsColor: ZedTheme.primaryText))
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .onChange(of: query) { _, _ in
            selectedIndex = 0
            hoveredIndex = nil
            keyboardScrollNonce &+= 1
        }
        .modifier(
            SwitcherKeyboardHandler(
                itemCount: combinedBranches.count,
                selectedIndex: $selectedIndex,
                keyboardScrollNonce: $keyboardScrollNonce,
                onSubmit: handleSubmit,
                onDismiss: { workspace.dismissOverlay() }
            )
        )
    }

    private func branchRow(_ branch: GitBranchItem, index: Int) -> some View {
        let isSelected = index == selectedIndex
        let isHovered = index == hoveredIndex
        return Button {
            workspace.switchGitBranch(to: branch.name, createNew: false, isRemote: branch.isRemote)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: branch.isRemote ? "cloud" : "arrow.triangle.branch")
                    .font(.system(size: 11))
                    .foregroundColor(Color(nsColor: branch.isCurrent ? ZedTheme.function : ZedTheme.secondaryText))

                Text(branch.name)
                    .font(.system(size: 13, weight: branch.isCurrent ? .semibold : .regular))
                    .foregroundColor(Color(nsColor: ZedTheme.primaryText))
                    .lineLimit(1)

                if branch.isCheckedOutElsewhere {
                    Text(L10n("switcher.branch.worktreeBadge"))
                        .font(.system(size: 10))
                        .foregroundColor(Color(nsColor: ZedTheme.mutedText))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color(nsColor: ZedTheme.hoverBackground))
                        )
                }

                Spacer()

                if !branch.commitShort.isEmpty {
                    Text(branch.commitShort)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(Color(nsColor: ZedTheme.mutedText))
                }

                if branch.isCurrent {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Color(nsColor: ZedTheme.function))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(
                        isSelected
                            ? Color(nsColor: ZedTheme.selectionBackground)
                            : (isHovered ? Color(nsColor: ZedTheme.hoverBackground) : Color.clear)
                    )
                    .padding(.horizontal, 4)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(index)
        .onHover { hovering in
            if hovering {
                hoveredIndex = index
            } else if hoveredIndex == index {
                hoveredIndex = nil
            }
        }
    }

    private func handleSubmit() {
        let items = combinedBranches
        if !items.isEmpty {
            let idx = min(max(0, selectedIndex), items.count - 1)
            let branch = items[idx]
            workspace.switchGitBranch(to: branch.name, createNew: false, isRemote: branch.isRemote)
        } else if canCreateBranch {
            workspace.switchGitBranch(to: trimmedQuery, createNew: true)
        }
    }
}

// MARK: - 4. Theme & Font Settings Modal

struct ThemeAndFontSettingsModalView: View {
    @ObservedObject var workspace: WorkspaceState
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var pluginManager = PluginManager.shared
    @ObservedObject private var localizationManager = LocalizationManager.shared
    @State private var escapeMonitor: Any?
    @State private var pendingInstallEntry: RemotePluginEntry?

    private let lineHeights: [CGFloat] = [1.2, 1.38, 1.5, 1.65]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "paintbrush.pointed.fill")
                        .font(.system(size: 13))
                        .foregroundColor(Color(nsColor: ZedTheme.function))
                    Text(L10n("settings.title"))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Color(nsColor: ZedTheme.primaryText))
                }

                Spacer()

                Button {
                    workspace.dismissOverlay()
                } label: {
                    Text("ESC")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(Color(nsColor: ZedTheme.mutedText))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(nsColor: ZedTheme.background))
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider().overlay(Color(nsColor: ZedTheme.border))

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // Language & Plugins Section
                    languageAndPluginsSection

                    Divider().overlay(Color(nsColor: ZedTheme.border))

                    // Theme Selector Grid
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n("settings.section.theme"))
                            .font(.system(size: 10.5, weight: .bold, design: .rounded))
                            .foregroundColor(Color(nsColor: ZedTheme.mutedText))

                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                            ForEach(ThemeID.allCases) { themeID in
                                themeCard(for: themeID)
                            }
                        }
                    }

                    Divider().overlay(Color(nsColor: ZedTheme.border))

                    // Font Family Selector
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(L10n("settings.section.fontFamily"))
                                .font(.system(size: 10.5, weight: .bold, design: .rounded))
                                .foregroundColor(Color(nsColor: ZedTheme.mutedText))
                            Spacer()
                            Picker("", selection: $themeManager.editorFontFamily) {
                                ForEach(themeManager.availableMonospacedFonts, id: \.self) { family in
                                    Text(family).tag(family)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 210)
                        }

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(themeManager.availableMonospacedFonts.prefix(6), id: \.self) { family in
                                    let selected = themeManager.editorFontFamily == family
                                    Button {
                                        themeManager.editorFontFamily = family
                                    } label: {
                                        Text(family)
                                            .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                                            .foregroundColor(Color(nsColor: selected ? ZedTheme.pillText : ZedTheme.secondaryText))
                                            .padding(.horizontal, 9)
                                            .padding(.vertical, 5)
                                            .background(
                                                RoundedRectangle(cornerRadius: 6)
                                                    .fill(Color(nsColor: selected ? ZedTheme.pillBackground : ZedTheme.background))
                                            )
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 6)
                                                    .stroke(Color(nsColor: ZedTheme.border), lineWidth: 1)
                                            )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }

                    // Size & Line Height Controls
                    VStack(alignment: .leading, spacing: 10) {
                        Text(L10n("settings.section.sizeSpacing"))
                            .font(.system(size: 10.5, weight: .bold, design: .rounded))
                            .foregroundColor(Color(nsColor: ZedTheme.mutedText))

                        HStack {
                            Text(L10n("settings.fontSize"))
                                .font(.system(size: 12.5))
                                .foregroundColor(Color(nsColor: ZedTheme.primaryText))
                            Spacer()
                            stepperControls(
                                valueText: "\(Int(themeManager.editorFontSize)) pt",
                                onMinus: { themeManager.decreaseFontSize() },
                                onPlus: { themeManager.increaseFontSize() },
                                onReset: { themeManager.resetFontSize() }
                            )
                        }

                        HStack {
                            Text(L10n("settings.lineHeight"))
                                .font(.system(size: 12.5))
                                .foregroundColor(Color(nsColor: ZedTheme.primaryText))
                            Spacer()
                            HStack(spacing: 4) {
                                ForEach(lineHeights, id: \.self) { ratio in
                                    let isSelected = abs(themeManager.lineHeightMultiplier - ratio) < 0.02
                                    Button {
                                        themeManager.lineHeightMultiplier = ratio
                                    } label: {
                                        Text(String(format: "%.2gx", ratio))
                                            .font(.system(size: 11, weight: isSelected ? .semibold : .regular, design: .monospaced))
                                            .foregroundColor(Color(nsColor: isSelected ? ZedTheme.pillText : ZedTheme.secondaryText))
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(
                                                RoundedRectangle(cornerRadius: 5)
                                                    .fill(Color(nsColor: isSelected ? ZedTheme.pillBackground : ZedTheme.background))
                                            )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }

                        HStack {
                            Text(L10n("settings.uiFontSize"))
                                .font(.system(size: 12.5))
                                .foregroundColor(Color(nsColor: ZedTheme.primaryText))
                            Spacer()
                            stepperControls(
                                valueText: String(format: "%.1f pt", themeManager.uiFontSize),
                                onMinus: { themeManager.uiFontSize = max(11, themeManager.uiFontSize - 0.5) },
                                onPlus: { themeManager.uiFontSize = min(16, themeManager.uiFontSize + 0.5) },
                                onReset: nil
                            )
                        }
                    }

                    // Live Editor Preview
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n("settings.section.preview"))
                            .font(.system(size: 10.5, weight: .bold, design: .rounded))
                            .foregroundColor(Color(nsColor: ZedTheme.mutedText))

                        VStack(alignment: .leading, spacing: 2) {
                            previewLine("func ", color: ZedTheme.keyword, rest: "switchWorkspace(", restColor: ZedTheme.function, tail: "path: String) {", tailColor: ZedTheme.plainText)
                            previewLine("    let ", color: ZedTheme.keyword, rest: "label = ", restColor: ZedTheme.plainText, tail: "\"SwiftFlash\"", tailColor: ZedTheme.string)
                            previewLine(L10n("settings.preview.comment"), color: ZedTheme.comment, rest: "", restColor: ZedTheme.comment, tail: "", tailColor: ZedTheme.comment)
                            previewLine("}", color: ZedTheme.plainText, rest: "", restColor: ZedTheme.plainText, tail: "", tailColor: ZedTheme.plainText)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: ZedTheme.background))
                        .cornerRadius(7)
                        .overlay(
                            RoundedRectangle(cornerRadius: 7)
                                .stroke(Color(nsColor: ZedTheme.border), lineWidth: 1)
                        )
                    }
                }
                .padding(16)
            }
            .frame(maxHeight: 540)
        }
        .frame(width: 560)
        .background(Color(nsColor: ZedTheme.sidebarBackground))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(nsColor: ZedTheme.border), lineWidth: 1)
        )
        .shadow(color: .black.opacity(ZedTheme.isDark ? 0.55 : 0.22), radius: 26, y: 12)
        .onAppear {
            if pluginManager.remotePlugins.isEmpty && !pluginManager.isFetchingRegistry {
                Task {
                    await pluginManager.fetchRemoteRegistry()
                }
            }
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if Int(event.keyCode) == 53 {
                    workspace.dismissOverlay()
                    return nil
                }
                return event
            }
        }
        .onDisappear {
            if let escapeMonitor {
                NSEvent.removeMonitor(escapeMonitor)
                self.escapeMonitor = nil
            }
        }
    }

    // MARK: - Language & Plugins Section

    private struct LanguageDropdownOption: Identifiable {
        let id: String
        let displayName: String
        let isInstalled: Bool
        let remoteEntry: RemotePluginEntry?
    }

    private var availableLanguageOptions: [LanguageDropdownOption] {
        var options: [LanguageDropdownOption] = []
        var seenIDs = Set<String>()

        for installed in pluginManager.installedLanguagePlugins {
            let name = installed.manifest.contributes?.localization?.nativeName ?? installed.manifest.name
            let remote = pluginManager.remoteLanguagePlugins.first { $0.id == installed.id }
            options.append(LanguageDropdownOption(
                id: installed.id,
                displayName: name,
                isInstalled: true,
                remoteEntry: remote
            ))
            seenIDs.insert(installed.id)
        }

        for remote in pluginManager.remoteLanguagePlugins where !seenIDs.contains(remote.id) {
            let name = remote.nativeName ?? remote.name
            options.append(LanguageDropdownOption(
                id: remote.id,
                displayName: name,
                isInstalled: false,
                remoteEntry: remote
            ))
            seenIDs.insert(remote.id)
        }

        return options
    }

    private var currentDropdownDisplayName: String {
        if let pending = pendingInstallEntry {
            return pending.nativeName ?? pending.name
        }
        return pendingTargetLanguageName
    }

    private var pendingTargetLanguageName: String {
        let id = localizationManager.selectedLanguagePluginID
        if id.isEmpty {
            return L10n("settings.language.builtinEnglish")
        }
        if let installed = pluginManager.installedLanguagePlugins.first(where: { $0.id == id }) {
            return installed.manifest.contributes?.localization?.nativeName ?? installed.manifest.name
        }
        return id
    }

    private var languageAndPluginsSection: some View {
        let isInstallingPending = pendingInstallEntry.map { pluginManager.installingPluginIDs.contains($0.id) } ?? false

        return VStack(alignment: .leading, spacing: 10) {
            Text(L10n("settings.section.languagePlugins"))
                .font(.system(size: 10.5, weight: .bold, design: .rounded))
                .foregroundColor(Color(nsColor: ZedTheme.mutedText))

            HStack(spacing: 8) {
                Text(L10n("settings.language.active"))
                    .font(.system(size: 12.5))
                    .foregroundColor(Color(nsColor: ZedTheme.primaryText))

                Spacer()

                // Rounded Language Dropdown
                Menu {
                    Button {
                        pendingInstallEntry = nil
                        localizationManager.selectLanguagePlugin(id: LocalizationManager.builtInEnglishID)
                    } label: {
                        HStack {
                            Text(L10n("settings.language.builtinEnglish"))
                            if localizationManager.selectedLanguagePluginID.isEmpty && pendingInstallEntry == nil {
                                Image(systemName: "checkmark")
                            }
                        }
                    }

                    if !availableLanguageOptions.isEmpty {
                        Divider()
                    }

                    ForEach(availableLanguageOptions) { option in
                        Button {
                            if option.isInstalled {
                                pendingInstallEntry = nil
                                localizationManager.selectLanguagePlugin(id: option.id)
                            } else if let remote = option.remoteEntry {
                                pluginManager.registryError = nil
                                pendingInstallEntry = remote
                            }
                        } label: {
                            HStack {
                                if option.isInstalled {
                                    Text(option.displayName)
                                    if localizationManager.selectedLanguagePluginID == option.id && pendingInstallEntry == nil {
                                        Image(systemName: "checkmark")
                                    }
                                } else {
                                    Text(L10n("settings.language.installOptionSuffix", option.displayName))
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "globe")
                            .font(.system(size: 11.5))
                            .foregroundColor(Color(nsColor: ZedTheme.function))

                        Text(currentDropdownDisplayName)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Color(nsColor: ZedTheme.primaryText))
                            .lineLimit(1)

                        Spacer(minLength: 8)

                        if pluginManager.isFetchingRegistry {
                            ProgressView()
                                .scaleEffect(0.42)
                                .frame(width: 11, height: 11)
                        } else {
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundColor(Color(nsColor: ZedTheme.mutedText))
                        }
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .frame(minWidth: 190, maxWidth: 230)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(nsColor: ZedTheme.background))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color(nsColor: ZedTheme.border), lineWidth: 1)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                // Refresh available languages button
                Button {
                    Task {
                        await pluginManager.fetchRemoteRegistry()
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                        .foregroundColor(Color(nsColor: ZedTheme.secondaryText))
                        .frame(width: 26, height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(Color(nsColor: ZedTheme.background))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 7)
                                .stroke(Color(nsColor: ZedTheme.border), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .disabled(pluginManager.isFetchingRegistry)
                .help(L10n("settings.plugins.refreshHelp"))

                // Uninstall button when an installed language plugin is currently selected
                if !localizationManager.selectedLanguagePluginID.isEmpty,
                   pluginManager.installedPlugin(id: localizationManager.selectedLanguagePluginID) != nil {
                    Button {
                        pluginManager.uninstallPlugin(id: localizationManager.selectedLanguagePluginID)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundColor(Color(nsColor: ZedTheme.attribute))
                            .frame(width: 26, height: 26)
                            .background(
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(Color(nsColor: ZedTheme.background))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 7)
                                    .stroke(Color(nsColor: ZedTheme.border), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(L10n("settings.plugins.uninstallHelp"))
                }
            }

            // Install Confirmation Prompt
            if let entry = pendingInstallEntry {
                let langLabel = entry.nativeName ?? entry.name
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 14))
                            .foregroundColor(Color(nsColor: ZedTheme.function))
                            .padding(.top, 1)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(L10n("settings.language.confirmTitleFormat", langLabel))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(Color(nsColor: ZedTheme.primaryText))

                            Text(L10n("settings.language.confirmBodyFormat", entry.version))
                                .font(.system(size: 11))
                                .foregroundColor(Color(nsColor: ZedTheme.secondaryText))
                        }
                    }

                    HStack(spacing: 8) {
                        Spacer()

                        Button {
                            pendingInstallEntry = nil
                        } label: {
                            Text(L10n("common.cancel"))
                                .font(.system(size: 11))
                                .foregroundColor(Color(nsColor: ZedTheme.secondaryText))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4.5)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(Color(nsColor: ZedTheme.background))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(Color(nsColor: ZedTheme.border), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(isInstallingPending)

                        Button {
                            Task {
                                let success = await pluginManager.installPlugin(entry, activateIfLanguage: true)
                                if success {
                                    pendingInstallEntry = nil
                                }
                            }
                        } label: {
                            HStack(spacing: 5) {
                                if isInstallingPending {
                                    ProgressView()
                                        .scaleEffect(0.45)
                                        .frame(width: 11, height: 11)
                                    Text(L10n("settings.plugins.downloading"))
                                } else {
                                    Text(L10n("settings.language.confirmInstallButton"))
                                }
                            }
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Color(nsColor: ZedTheme.pillText))
                            .padding(.horizontal, 11)
                            .padding(.vertical, 4.5)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color(nsColor: ZedTheme.pillBackground))
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(isInstallingPending)
                    }
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: ZedTheme.activeTabBackground))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(nsColor: ZedTheme.cursor).opacity(0.6), lineWidth: 1)
                )
            }

            // Restart Required Banner
            if localizationManager.needsRestartToApply {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                        .font(.system(size: 13))
                        .foregroundColor(Color(nsColor: ZedTheme.typeName))

                    Text(L10n("settings.language.pendingRestartBanner", pendingTargetLanguageName))
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(Color(nsColor: ZedTheme.primaryText))

                    Spacer()

                    Button {
                        localizationManager.restartApplication()
                    } label: {
                        Text(L10n("settings.language.restartNow"))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Color(nsColor: ZedTheme.pillText))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4.5)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color(nsColor: ZedTheme.pillBackground))
                            )
                    }
                    .buttonStyle(.plain)
                }
                .padding(9)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: ZedTheme.activeTabBackground))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(nsColor: ZedTheme.typeName).opacity(0.6), lineWidth: 1)
                )
            }

            if let errorMsg = pluginManager.registryError {
                Text(errorMsg)
                    .font(.system(size: 11))
                    .foregroundColor(Color(nsColor: ZedTheme.attribute))
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(nsColor: ZedTheme.background))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(nsColor: ZedTheme.attribute).opacity(0.5), lineWidth: 1)
                    )
            }
        }
    }

    private func themeCard(for id: ThemeID) -> some View {
        let palette = ThemePalette.palette(for: id)
        let isSelected = themeManager.currentThemeID == id
        return Button {
            themeManager.currentThemeID = id
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(id.rawValue)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(Color(nsColor: ZedTheme.primaryText))
                        .lineLimit(1)
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(Color(nsColor: ZedTheme.function))
                    }
                }

                HStack(spacing: 5) {
                    ForEach(Array(palette.previewSwatches.enumerated()), id: \.offset) { _, hex in
                        Circle()
                            .fill(Color(nsColor: NSColor(hex: hex)))
                            .frame(width: 11, height: 11)
                            .overlay(
                                Circle()
                                    .stroke(Color(nsColor: ZedTheme.border), lineWidth: 0.6)
                            )
                    }
                    Spacer()
                    Text(palette.isDark ? L10n("settings.theme.dark") : L10n("settings.theme.light"))
                        .font(.system(size: 10))
                        .foregroundColor(Color(nsColor: ZedTheme.mutedText))
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: isSelected ? ZedTheme.activeTabBackground : ZedTheme.background))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        Color(nsColor: isSelected ? ZedTheme.cursor : ZedTheme.border),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private func stepperControls(
        valueText: String,
        onMinus: @escaping () -> Void,
        onPlus: @escaping () -> Void,
        onReset: (() -> Void)?
    ) -> some View {
        HStack(spacing: 6) {
            Button(action: onMinus) {
                Image(systemName: "minus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 22)
                    .background(Color(nsColor: ZedTheme.background))
                    .cornerRadius(5)
            }
            .buttonStyle(.plain)

            Text(valueText)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(Color(nsColor: ZedTheme.primaryText))
                .frame(minWidth: 52)

            Button(action: onPlus) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 22)
                    .background(Color(nsColor: ZedTheme.background))
                    .cornerRadius(5)
            }
            .buttonStyle(.plain)

            if let onReset {
                Button(L10n("common.reset"), action: onReset)
                    .font(.system(size: 11))
                    .foregroundColor(Color(nsColor: ZedTheme.secondaryText))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color(nsColor: ZedTheme.background))
                    .cornerRadius(5)
                    .buttonStyle(.plain)
            }
        }
        .foregroundColor(Color(nsColor: ZedTheme.primaryText))
    }

    private func previewLine(
        _ first: String,
        color: NSColor,
        rest: String,
        restColor: NSColor,
        tail: String,
        tailColor: NSColor
    ) -> some View {
        HStack(spacing: 0) {
            Text(first).foregroundColor(Color(nsColor: color))
            Text(rest).foregroundColor(Color(nsColor: restColor))
            Text(tail).foregroundColor(Color(nsColor: tailColor))
        }
        .font(Font(themeManager.editorFont))
    }
}
