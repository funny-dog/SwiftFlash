import AppKit
import SwiftUI

struct SidebarView: View {
    @ObservedObject var workspace: WorkspaceState
    @ObservedObject private var themeManager = ThemeManager.shared
    @State private var isCreatingFile = false
    @State private var newFileName = ""

    var body: some View {
        Group {
            switch workspace.sidebarMode {
            case .explorer:
                explorerSection
            case .git:
                ZedGitPanelView(workspace: workspace)
            case .search:
                GlobalSearchView(workspace: workspace)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: ZedTheme.sidebarBackground))
    }

    private var explorerSection: some View {
        VStack(spacing: 0) {
            // Project Toolbar
            HStack(spacing: 6) {
                Button {
                    workspace.toggleOverlay(.projectSwitcher)
                } label: {
                    HStack(spacing: 4) {
                        Text((workspace.hasWorkspaceOpen ? workspace.rootURL.lastPathComponent : "SwiftFlash").uppercased())
                            .font(.system(size: 10.5, weight: .bold, design: .rounded))
                            .foregroundColor(Color(nsColor: ZedTheme.secondaryText))
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundColor(Color(nsColor: ZedTheme.mutedText))
                    }
                }
                .buttonStyle(.plain)
                .help(L10n("sidebar.explorer.switchProjectHelp"))

                Spacer()

                if workspace.hasWorkspaceOpen {
                    Button {
                        newFileName = ""
                        isCreatingFile.toggle()
                    } label: {
                        Image(systemName: "doc.badge.plus")
                            .font(.system(size: 11.5))
                            .foregroundColor(Color(nsColor: ZedTheme.secondaryText))
                    }
                    .buttonStyle(.plain)
                    .help(L10n("sidebar.explorer.newFileHelp"))
                }

                Button {
                    workspace.openFolderPanel()
                } label: {
                    Image(systemName: "folder.badge.gearshape")
                        .font(.system(size: 11.5))
                        .foregroundColor(Color(nsColor: ZedTheme.secondaryText))
                }
                .buttonStyle(.plain)
                .help(L10n("sidebar.explorer.openFolderHelp"))

                if workspace.hasWorkspaceOpen {
                    Button {
                        workspace.reloadWorkspace()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11))
                            .foregroundColor(Color(nsColor: ZedTheme.secondaryText))
                    }
                    .buttonStyle(.plain)
                    .help(L10n("sidebar.explorer.refreshHelp"))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()
                .overlay(Color(nsColor: ZedTheme.border))

            if isCreatingFile {
                HStack(spacing: 6) {
                    TextField(L10n("sidebar.explorer.newFilePlaceholder"), text: $newFileName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(Color(nsColor: ZedTheme.primaryText))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(Color(nsColor: ZedTheme.background))
                        .cornerRadius(4)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color(nsColor: ZedTheme.cursor), lineWidth: 1)
                        )
                        .onSubmit {
                            let trimmed = newFileName.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty {
                                workspace.createFileInWorkspace(named: trimmed)
                            }
                            isCreatingFile = false
                        }

                    Button {
                        isCreatingFile = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10))
                            .foregroundColor(Color(nsColor: ZedTheme.mutedText))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 4)
            }

            if !workspace.hasWorkspaceOpen {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "folder")
                        .font(.system(size: 24))
                        .foregroundColor(Color(nsColor: ZedTheme.mutedText))
                    Button {
                        workspace.openFolderPanel()
                    } label: {
                        Text(L10n("menu.file.openFolder"))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Color(nsColor: ZedTheme.primaryText))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color(nsColor: ZedTheme.pillBackground))
                            .cornerRadius(6)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color(nsColor: ZedTheme.border), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geo in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(workspace.rootItems) { item in
                                FileTreeNodeView(item: item, workspace: workspace, uiFontSize: themeManager.uiFontSize, depth: 0)
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(minWidth: geo.size.width, minHeight: geo.size.height, alignment: .topLeading)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                        .contextMenu {
                            Button(L10n("explorer.context.newFile")) {
                                DispatchQueue.main.async {
                                    workspace.promptNewFile(inside: workspace.rootURL)
                                }
                            }
                            Button(L10n("explorer.context.newFolder")) {
                                DispatchQueue.main.async {
                                    workspace.promptNewFolder(inside: workspace.rootURL)
                                }
                            }
                            Divider()
                            Button(L10n("explorer.context.refresh")) {
                                workspace.reloadWorkspace()
                            }
                            Button(L10n("explorer.context.revealInFinder")) {
                                workspace.revealInFinder(workspace.rootURL)
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Zed-Style Git Panel

private struct ZedGitPanelView: View {
    @ObservedObject var workspace: WorkspaceState
    @ObservedObject private var themeManager = ThemeManager.shared
    @State private var isCommitExpanded = false

    private var hasUnstagedOrUntracked: Bool {
        workspace.gitChanges.contains { $0.hasUnstagedChanges || $0.isUntracked }
    }

    private var isUnstageMode: Bool {
        !workspace.gitChanges.isEmpty && !hasUnstagedOrUntracked
    }

    private var stageButtonTitle: String {
        isUnstageMode ? L10n("git.action.unstageAll") : L10n("git.action.stageAll")
    }

    private var commitNSFont: NSFont {
        let size = max(11.5, themeManager.uiFontSize - 0.5)
        if themeManager.editorFontFamily == "System Monospace" {
            return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }
        return NSFont(name: themeManager.editorFontFamily, size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    private var commitFont: Font {
        Font(commitNSFont)
    }

    var body: some View {
        VStack(spacing: 0) {
            // 1. Top Tabs: Changes | History
            HStack(spacing: 0) {
                panelTabButton(.changes)
                Rectangle()
                    .fill(Color(nsColor: ZedTheme.border))
                    .frame(width: 1)
                panelTabButton(.history)
            }
            .frame(height: 30)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color(nsColor: ZedTheme.border))
                    .frame(height: 1)
            }

            if !workspace.isGitRepository {
                notAGitRepoView
            } else {
                if workspace.gitPanelTab == .changes {
                    changesToolbar
                    changesListArea
                } else {
                    historyToolbar
                    historyListArea
                }

                branchAndFetchBar
                commitEditorSection
                lastCommitBar
            }
        }
        .onAppear {
            workspace.refreshGitMetadata()
        }
    }

    private func panelTabButton(_ tab: GitPanelTab) -> some View {
        let isActive = workspace.gitPanelTab == tab
        return Button {
            workspace.gitPanelTab = tab
            if tab == .history {
                workspace.refreshGitMetadata()
            }
        } label: {
            Text(tab.localizedTitle)
                .font(.system(size: 12, weight: isActive ? .medium : .regular))
                .foregroundColor(
                    Color(nsColor: isActive ? ZedTheme.primaryText : ZedTheme.mutedText)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    Color(nsColor: isActive ? ZedTheme.activeTabBackground : ZedTheme.sidebarBackground)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var notAGitRepoView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 26))
                .foregroundColor(Color(nsColor: ZedTheme.mutedText))
            Text(L10n("git.notARepo.title"))
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Color(nsColor: ZedTheme.secondaryText))
            Button {
                workspace.initializeGitRepository()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle.fill")
                    Text(L10n("git.init.button"))
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
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Changes Toolbar & List

    private var changesToolbar: some View {
        HStack(spacing: 5) {
            Menu {
                ForEach(GitChangeFilter.allCases, id: \.self) { filter in
                    Button {
                        workspace.gitChangeFilter = filter
                    } label: {
                        HStack {
                            Text(filter.localizedTitle)
                            if workspace.gitChangeFilter == filter {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Text(workspace.gitChangeFilter.localizedTitle)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(Color(nsColor: ZedTheme.primaryText))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundColor(Color(nsColor: ZedTheme.mutedText))
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            Button {
                workspace.openGitDiffInEditor()
            } label: {
                HStack(spacing: 3.5) {
                    Image(systemName: "plusminus")
                        .font(.system(size: 10.5))
                    Text(L10n("git.action.viewDiff"))
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .foregroundColor(
                    Color(nsColor: workspace.gitChanges.isEmpty ? ZedTheme.mutedText : ZedTheme.primaryText)
                )
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(nsColor: ZedTheme.hoverBackground).opacity(0.75))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color(nsColor: ZedTheme.border).opacity(0.6), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .fixedSize()
            .help(L10n("git.action.viewDiffHelp"))

            Spacer(minLength: 4)

            Menu {
                Button(L10n("git.action.refreshStatus")) {
                    workspace.refreshGitMetadata()
                }
                Divider()
                Button(L10n("git.action.stageAllChanges")) {
                    workspace.stageAllGitChanges(trackedOnly: false)
                }
                Button(L10n("git.action.stageTrackedOnly")) {
                    workspace.stageAllGitChanges(trackedOnly: true)
                }
                Button(L10n("git.action.unstageAllChanges")) {
                    workspace.unstageAllGitChanges()
                }
                Divider()
                Button(L10n("git.action.discardAllUnstaged"), role: .destructive) {
                    workspace.discardAllUnstagedGitChanges()
                }
                .disabled(workspace.gitChanges.isEmpty)
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 11))
                    .foregroundColor(Color(nsColor: ZedTheme.secondaryText))
                    .frame(width: 20, height: 20)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(L10n("git.action.optionsHelp"))

            splitPillButton(
                title: stageButtonTitle,
                primaryAction: {
                    if isUnstageMode {
                        workspace.unstageAllGitChanges()
                    } else {
                        workspace.stageAllGitChanges(trackedOnly: false)
                    }
                },
                menuContent: {
                    Button(L10n("git.action.stageAll")) {
                        workspace.stageAllGitChanges(trackedOnly: false)
                    }
                    Button(L10n("git.action.stageTracked")) {
                        workspace.stageAllGitChanges(trackedOnly: true)
                    }
                    Button(L10n("git.action.unstageAll")) {
                        workspace.unstageAllGitChanges()
                    }
                    Divider()
                    Button(L10n("git.action.discardAllUnstaged"), role: .destructive) {
                        workspace.discardAllUnstagedGitChanges()
                    }
                    .disabled(workspace.gitChanges.isEmpty)
                }
            )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var changesListArea: some View {
        let items = workspace.filteredGitChanges
        return Group {
            if items.isEmpty {
                VStack {
                    Spacer()
                    Text(
                        workspace.gitChanges.isEmpty
                            ? L10n("git.empty.noChanges")
                            : L10n("git.empty.filteredFormat", workspace.gitChangeFilter.localizedTitle.lowercased())
                    )
                    .font(.system(size: 12.5))
                    .foregroundColor(Color(nsColor: ZedTheme.mutedText))
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(items) { item in
                            GitChangedFileRowView(item: item, workspace: workspace)
                        }
                    }
                    .padding(.vertical, 4)
                    .background(OverlayScrollConfigurator())
                }
                .scrollIndicators(.hidden)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: History Toolbar & List

    private var historyToolbar: some View {
        HStack(spacing: 6) {
            Text(L10n("git.history.recentCommitsFormat", workspace.gitCommitHistory.count))
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(Color(nsColor: ZedTheme.secondaryText))

            Spacer()

            Button {
                workspace.refreshGitMetadata()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11))
                    .foregroundColor(Color(nsColor: ZedTheme.secondaryText))
            }
            .buttonStyle(.plain)
            .help(L10n("git.history.refreshHelp"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: ZedTheme.border).opacity(0.6))
                .frame(height: 1)
        }
    }

    private var historyListArea: some View {
        Group {
            if workspace.gitCommitHistory.isEmpty {
                VStack {
                    Spacer()
                    Text(L10n("git.history.empty"))
                        .font(.system(size: 12.5))
                        .foregroundColor(Color(nsColor: ZedTheme.mutedText))
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(workspace.gitCommitHistory) { commit in
                            GitCommitHistoryRowView(commit: commit) {
                                workspace.openGitCommitDiffInEditor(
                                    commitHash: commit.hash,
                                    shortHash: commit.shortHash
                                )
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .background(OverlayScrollConfigurator())
                }
                .scrollIndicators(.hidden)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: Branch & Fetch Bar

    private var branchAndFetchBar: some View {
        HStack(spacing: 6) {
            Button {
                workspace.toggleOverlay(.branchSwitcher)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 11))
                        .foregroundColor(Color(nsColor: ZedTheme.mutedText))
                    Text(workspace.gitBranch)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Color(nsColor: ZedTheme.primaryText))
                        .lineLimit(1)

                    if workspace.gitAheadCount > 0 || workspace.gitBehindCount > 0 {
                        Text("↑\(workspace.gitAheadCount) ↓\(workspace.gitBehindCount)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(Color(nsColor: ZedTheme.mutedText))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n("header.branch.help"))

            Spacer()

            splitPillButton(
                title: L10n("git.remote.fetch"),
                leadingIcon: workspace.isGitOperationInProgress ? nil : "arrow.clockwise",
                isLoading: workspace.isGitOperationInProgress,
                primaryAction: {
                    workspace.performGitRemoteAction("fetch")
                },
                menuContent: {
                    Button(L10n("git.remote.fetchPrune")) {
                        workspace.performGitRemoteAction("fetch")
                    }
                    Button(L10n("git.remote.pull")) {
                        workspace.performGitRemoteAction("pull")
                    }
                    Button(L10n("git.remote.push")) {
                        workspace.performGitRemoteAction("push")
                    }
                }
            )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color(nsColor: ZedTheme.border))
                .frame(height: 1)
        }
    }

    // MARK: Commit Editor & Action Bar

    private var commitEditorSection: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                CommitMessageEditorView(
                    text: $workspace.gitCommitMessage,
                    font: commitNSFont,
                    textColor: ZedTheme.primaryText,
                    cursorColor: ZedTheme.cursor
                )
                .padding(.leading, 4)
                .padding(.trailing, 28)
                .padding(.top, 2)
                .padding(.bottom, 2)

                if workspace.gitCommitMessage.isEmpty {
                    Text(L10n("git.commit.placeholder"))
                        .font(commitFont)
                        .foregroundColor(Color(nsColor: ZedTheme.mutedText))
                        .padding(.leading, 13)
                        .padding(.top, 8)
                        .allowsHitTesting(false)
                }

                HStack {
                    Spacer()
                    VStack(spacing: 6) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                isCommitExpanded.toggle()
                            }
                        } label: {
                            Image(systemName: isCommitExpanded
                                  ? "arrow.down.right.and.arrow.up.left"
                                  : "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 10.5))
                                .foregroundColor(Color(nsColor: ZedTheme.mutedText))
                                .frame(width: 18, height: 18)
                        }
                        .buttonStyle(.plain)
                        .help(isCommitExpanded ? L10n("git.commit.collapseHelp") : L10n("git.commit.expandHelp"))
                    }
                    .padding(.top, 6)
                    .padding(.trailing, 10)
                }
            }
            .frame(height: isCommitExpanded ? 168 : 96)

            HStack(spacing: 8) {
                Menu {
                    ForEach(GitCommitActionMode.allCases, id: \.self) { mode in
                        Button {
                            workspace.gitCommitActionMode = mode
                        } label: {
                            HStack {
                                Text(mode.localizedTitle)
                                if workspace.gitCommitActionMode == mode {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Color(nsColor: ZedTheme.secondaryText))
                        .frame(width: 18, height: 18)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(L10n("git.commit.optionsHelp"))

                Button {
                    workspace.generateDraftCommitMessage()
                } label: {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 11.5))
                        .foregroundColor(Color(nsColor: ZedTheme.secondaryText))
                }
                .buttonStyle(.plain)
                .help(L10n("git.commit.generateHelp"))

                Spacer()

                splitPillButton(
                    title: workspace.gitCommitActionMode.localizedTitle,
                    isEmphasized: !workspace.gitCommitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    primaryAction: {
                        workspace.commitGitChanges()
                    },
                    menuContent: {
                        ForEach(GitCommitActionMode.allCases, id: \.self) { mode in
                            Button {
                                workspace.gitCommitActionMode = mode
                            } label: {
                                HStack {
                                    Text(mode.localizedTitle)
                                    if workspace.gitCommitActionMode == mode {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    }
                )
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 7)
            .padding(.top, 2)
        }
        .background(Color(nsColor: ZedTheme.background))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color(nsColor: ZedTheme.border))
                .frame(height: 1)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: ZedTheme.border))
                .frame(height: 1)
        }
    }

    // MARK: Last Commit Footer

    private var lastCommitBar: some View {
        HStack(spacing: 8) {
            Button {
                if !workspace.lastCommitShortHash.isEmpty {
                    workspace.openGitCommitDiffInEditor(
                        commitHash: "HEAD",
                        shortHash: workspace.lastCommitShortHash
                    )
                }
            } label: {
                Text(workspace.lastCommitSubject.isEmpty ? L10n("git.history.empty") : workspace.lastCommitSubject)
                    .font(.system(size: 11.5))
                    .foregroundColor(
                        Color(nsColor: workspace.lastCommitSubject.isEmpty ? ZedTheme.mutedText : ZedTheme.primaryText)
                    )
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .buttonStyle(.plain)
            .disabled(workspace.lastCommitShortHash.isEmpty)
            .help(workspace.lastCommitShortHash.isEmpty ? "" : L10n("git.commit.viewLastHelpFormat", workspace.lastCommitShortHash))

            Spacer()

            Button {
                workspace.uncommitLastGitCommit()
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 11))
                    .foregroundColor(
                        Color(nsColor: workspace.lastCommitShortHash.isEmpty ? ZedTheme.mutedText : ZedTheme.secondaryText)
                    )
            }
            .buttonStyle(.plain)
            .disabled(workspace.lastCommitShortHash.isEmpty)
            .help(L10n("git.commit.undoLastHelp"))

            Button {
                if !workspace.lastCommitShortHash.isEmpty {
                    workspace.openGitCommitDiffInEditor(
                        commitHash: "HEAD",
                        shortHash: workspace.lastCommitShortHash
                    )
                }
            } label: {
                Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                    .font(.system(size: 11))
                    .foregroundColor(
                        Color(nsColor: workspace.lastCommitShortHash.isEmpty ? ZedTheme.mutedText : ZedTheme.secondaryText)
                    )
            }
            .buttonStyle(.plain)
            .disabled(workspace.lastCommitShortHash.isEmpty)
            .help(L10n("git.commit.showLastDiffHelp"))
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(Color(nsColor: ZedTheme.sidebarBackground))
    }

    // MARK: Shared Split Pill Button

    private func splitPillButton<MenuItems: View>(
        title: String,
        leadingIcon: String? = nil,
        isLoading: Bool = false,
        isEmphasized: Bool = false,
        primaryAction: @escaping () -> Void,
        @ViewBuilder menuContent: () -> MenuItems
    ) -> some View {
        HStack(spacing: 0) {
            Button(action: primaryAction) {
                HStack(spacing: 4) {
                    if isLoading {
                        ProgressView()
                            .scaleEffect(0.45)
                            .frame(width: 11, height: 11)
                    } else if let leadingIcon {
                        Image(systemName: leadingIcon)
                            .font(.system(size: 10.5))
                    }
                    Text(title)
                        .font(.system(size: 11.5, weight: .medium))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .foregroundColor(
                    Color(nsColor: isEmphasized ? ZedTheme.pillText : ZedTheme.primaryText)
                )
                .padding(.horizontal, 7)
                .padding(.vertical, 3.5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .fixedSize()

            Rectangle()
                .fill(Color(nsColor: ZedTheme.border))
                .frame(width: 1, height: 18)

            Menu {
                menuContent()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundColor(
                        Color(nsColor: isEmphasized ? ZedTheme.pillText : ZedTheme.secondaryText)
                    )
                    .padding(.horizontal, 6)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(Color(nsColor: isEmphasized ? ZedTheme.pillBackground : ZedTheme.hoverBackground).opacity(0.85))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(Color(nsColor: ZedTheme.border), lineWidth: 1)
        )
    }
}

// MARK: - Git Changed File Row

private struct GitChangedFileRowView: View {
    let item: GitChangedFileItem
    @ObservedObject var workspace: WorkspaceState
    @State private var isHovered = false

    private var statusColor: NSColor {
        switch item.displayStatus {
        case "A", "?": return ZedTheme.string
        case "D", "!": return ZedTheme.attribute
        case "R": return ZedTheme.function
        default: return ZedTheme.typeName
        }
    }

    private var checkboxIcon: String {
        if item.isStaged && !item.hasUnstagedChanges {
            return "checkmark.square.fill"
        } else if item.isStaged && item.hasUnstagedChanges {
            return "minus.square.fill"
        }
        return "square"
    }

    private var checkboxColor: NSColor {
        if item.isStaged && !item.hasUnstagedChanges {
            return ZedTheme.function
        } else if item.isStaged && item.hasUnstagedChanges {
            return ZedTheme.typeName
        }
        return ZedTheme.mutedText
    }

    private var directoryPart: String? {
        let dir = (item.relativePath as NSString).deletingLastPathComponent
        return dir.isEmpty ? nil : dir
    }

    var body: some View {
        HStack(spacing: 6) {
            Button {
                workspace.toggleStageGitFile(item)
            } label: {
                Image(systemName: checkboxIcon)
                    .font(.system(size: 12))
                    .foregroundColor(Color(nsColor: checkboxColor))
            }
            .buttonStyle(.plain)
            .help(item.isStaged && !item.hasUnstagedChanges ? L10n("git.file.unstage") : L10n("git.file.stage"))

            HStack(spacing: 5) {
                Text(item.fileName)
                    .font(.system(size: 12))
                    .foregroundColor(Color(nsColor: ZedTheme.primaryText))
                    .lineLimit(1)

                if let dir = directoryPart {
                    Text(dir)
                        .font(.system(size: 10.5))
                        .foregroundColor(Color(nsColor: ZedTheme.mutedText))
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }

            Spacer(minLength: 4)

            if isHovered {
                HStack(spacing: 5) {
                    if item.displayStatus != "D" {
                        Button {
                            workspace.openFile(url: item.url)
                        } label: {
                            Image(systemName: "arrow.up.forward.square")
                                .font(.system(size: 10.5))
                                .foregroundColor(Color(nsColor: ZedTheme.secondaryText))
                        }
                        .buttonStyle(.plain)
                        .help(L10n("git.file.open"))
                    }

                    Button {
                        workspace.discardGitFileChanges(item)
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 10.5))
                            .foregroundColor(Color(nsColor: ZedTheme.attribute))
                    }
                    .buttonStyle(.plain)
                    .help(L10n("git.file.discard"))
                }
            }

            Text(item.displayStatus)
                .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                .foregroundColor(Color(nsColor: statusColor))
                .frame(width: 14, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4.5)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isHovered ? Color(nsColor: ZedTheme.hoverBackground) : Color.clear)
                .padding(.horizontal, 4)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture {
            workspace.openGitDiffInEditor(for: item)
        }
        .contextMenu {
            Button(L10n("git.action.viewDiff")) {
                workspace.openGitDiffInEditor(for: item)
            }
            if item.displayStatus != "D" {
                Button(L10n("git.file.open")) {
                    workspace.openFile(url: item.url)
                }
            }
            Divider()
            if item.hasUnstagedChanges || item.isUntracked {
                Button(L10n("git.file.stage")) {
                    workspace.stageGitFile(item)
                }
            }
            if item.isStaged {
                Button(L10n("git.file.unstage")) {
                    workspace.unstageGitFile(item)
                }
            }
            Divider()
            Button(L10n("git.file.discardEllipsis"), role: .destructive) {
                workspace.discardGitFileChanges(item)
            }
        }
    }
}

// MARK: - Git Commit History Row

private struct GitCommitHistoryRowView: View {
    let commit: GitCommitLogItem
    let onTap: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 3) {
                Text(commit.subject)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color(nsColor: ZedTheme.primaryText))
                    .lineLimit(1)
                    .truncationMode(.tail)

                HStack(spacing: 6) {
                    Text(commit.shortHash)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(Color(nsColor: ZedTheme.pillText))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color(nsColor: ZedTheme.pillBackground))
                        )

                    Text(commit.author)
                        .font(.system(size: 10.5))
                        .foregroundColor(Color(nsColor: ZedTheme.secondaryText))
                        .lineLimit(1)

                    Spacer()

                    Text(commit.relativeDate)
                        .font(.system(size: 10.5))
                        .foregroundColor(Color(nsColor: ZedTheme.mutedText))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5.5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isHovered ? Color(nsColor: ZedTheme.hoverBackground) : Color.clear)
                    .padding(.horizontal, 4)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Explorer File Tree Row

private struct FileTreeNodeView: View {
    @ObservedObject var item: FileItem
    @ObservedObject var workspace: WorkspaceState
    let uiFontSize: CGFloat
    let depth: Int
    @State private var isHovered = false

    private var isSelected: Bool {
        workspace.activeTab?.url == item.url
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                Spacer()
                    .frame(width: CGFloat(depth) * 14 + 8)

                if item.isDirectory {
                    Image(systemName: item.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(Color(nsColor: ZedTheme.mutedText))
                        .frame(width: 10)

                    Image(systemName: item.isExpanded ? "folder.fill" : "folder")
                        .font(.system(size: 12))
                        .foregroundColor(Color(nsColor: ZedTheme.function))
                } else {
                    Spacer().frame(width: 10)
                    Image(systemName: item.language.iconName)
                        .font(.system(size: 11.5))
                        .foregroundColor(Color(nsColor: item.language.iconColor))
                }

                Text(item.name)
                    .font(.system(size: uiFontSize))
                    .foregroundColor(isSelected ? Color(nsColor: ZedTheme.primaryText) : Color(nsColor: ZedTheme.secondaryText))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer()
            }
            .padding(.vertical, 4)
            .padding(.trailing, 8)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(
                        isSelected
                            ? Color(nsColor: ZedTheme.selectionBackground).opacity(0.75)
                            : (isHovered ? Color(nsColor: ZedTheme.hoverBackground) : Color.clear)
                    )
                    .padding(.horizontal, 4)
            )
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovered = hovering
            }
            .onTapGesture {
                if item.isDirectory {
                    item.loadChildrenIfNeeded()
                    item.isExpanded.toggle()
                } else {
                    workspace.openFile(url: item.url)
                }
            }
            .contextMenu {
                let targetDirectory = item.isDirectory ? item.url : item.url.deletingLastPathComponent()

                if !item.isDirectory {
                    Button(L10n("explorer.context.open")) {
                        workspace.openFile(url: item.url)
                    }
                    Divider()
                }

                Button(L10n("explorer.context.newFile")) {
                    DispatchQueue.main.async {
                        workspace.promptNewFile(inside: targetDirectory)
                    }
                }
                Button(L10n("explorer.context.newFolder")) {
                    DispatchQueue.main.async {
                        workspace.promptNewFolder(inside: targetDirectory)
                    }
                }

                Divider()

                Button(L10n("explorer.context.rename")) {
                    DispatchQueue.main.async {
                        workspace.promptRenameItem(at: item.url, isDirectory: item.isDirectory)
                    }
                }
                Button(L10n("explorer.context.duplicate")) {
                    workspace.duplicateItem(at: item.url, isDirectory: item.isDirectory)
                }
                Button(L10n("explorer.context.delete"), role: .destructive) {
                    DispatchQueue.main.async {
                        workspace.promptDeleteItem(at: item.url, isDirectory: item.isDirectory)
                    }
                }

                Divider()

                Button(L10n("explorer.context.copyPath")) {
                    workspace.copyPathToPasteboard(item.url, relative: false)
                }
                Button(L10n("explorer.context.copyRelativePath")) {
                    workspace.copyPathToPasteboard(item.url, relative: true)
                }
                Button(L10n("explorer.context.revealInFinder")) {
                    workspace.revealInFinder(item.url)
                }
            }

            if item.isDirectory && item.isExpanded, let children = item.children {
                ForEach(children) { child in
                    FileTreeNodeView(item: child, workspace: workspace, uiFontSize: uiFontSize, depth: depth + 1)
                }
            }
        }
    }
}

// MARK: - AppKit Scrollbar Suppression & Native Commit Editor

private struct OverlayScrollConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> EnclosingScrollConfigurerView {
        EnclosingScrollConfigurerView()
    }

    func updateNSView(_ nsView: EnclosingScrollConfigurerView, context: Context) {
        nsView.configureEnclosingScrollView()
    }

    final class EnclosingScrollConfigurerView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureEnclosingScrollView()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            configureEnclosingScrollView()
        }

        func configureEnclosingScrollView() {
            DispatchQueue.main.async { [weak self] in
                guard let scrollView = self?.enclosingScrollView else { return }
                scrollView.hasVerticalScroller = false
                scrollView.hasHorizontalScroller = false
                scrollView.scrollerStyle = .overlay
                scrollView.autohidesScrollers = true
                scrollView.drawsBackground = false
            }
        }
    }
}

private struct CommitMessageEditorView: NSViewRepresentable {
    @Binding var text: String
    let font: NSFont
    let textColor: NSColor
    let cursorColor: NSColor

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 4
        textView.textContainerInset = NSSize(width: 5, height: 6)
        textView.font = font
        textView.textColor = textColor
        textView.insertionPointColor = cursorColor
        textView.typingAttributes = [
            .font: font,
            .foregroundColor: textColor
        ]
        textView.string = text

        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        nsView.hasVerticalScroller = false
        nsView.hasHorizontalScroller = false
        nsView.drawsBackground = false

        guard let textView = context.coordinator.textView else { return }
        if !context.coordinator.isUpdatingFromAppKit && textView.string != text {
            textView.string = text
        }
        textView.font = font
        textView.textColor = textColor
        textView.insertionPointColor = cursorColor
        textView.typingAttributes = [
            .font: font,
            .foregroundColor: textColor
        ]
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: NSScrollView,
        context: Context
    ) -> CGSize? {
        CGSize(
            width: proposal.width ?? 240,
            height: proposal.height ?? 90
        )
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CommitMessageEditorView
        weak var textView: NSTextView?
        var isUpdatingFromAppKit = false

        init(_ parent: CommitMessageEditorView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            isUpdatingFromAppKit = true
            parent.text = textView.string
            isUpdatingFromAppKit = false
        }
    }
}
