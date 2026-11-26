import AppKit
import SwiftUI

// MARK: - 1. Zed Project / Directory Switcher

struct ZedProjectSwitcherView: View {
    @ObservedObject var workspace: WorkspaceState
    @ObservedObject private var themeManager = ThemeManager.shared
    @State private var query: String = ""
    @State private var selectedIndex: Int = 0
    @State private var hoveredIndex: Int? = nil
    @State private var keyboardScrollNonce: Int = 0

    private var windowMatches: [URL] {
        workspace.windowProjects.filter { switcherFuzzyMatches(query: query, candidate: $0.lastPathComponent) }
    }

    private var recentMatches: [URL] {
        let windowPaths = Set(workspace.windowProjects.map { $0.standardized.path })
        return workspace.recentProjects.filter { url in
            !windowPaths.contains(url.standardized.path)
                && switcherFuzzyMatches(query: query, candidate: url.lastPathComponent)
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
                    Text(switcherAbbreviatedPath(url.deletingLastPathComponent()))
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
            switcherFuzzyMatches(query: query, candidate: item.name)
                || switcherFuzzyMatches(query: query, candidate: item.branch)
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

                    Text(switcherAbbreviatedPath(wt.url))
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
        workspace.gitBranches.filter { !$0.isRemote && switcherFuzzyMatches(query: query, candidate: $0.name) }
    }

    private var remoteBranches: [GitBranchItem] {
        workspace.gitBranches.filter { $0.isRemote && switcherFuzzyMatches(query: query, candidate: $0.name) }
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
