import AppKit
import SwiftUI

struct SidebarView: View {
    @ObservedObject var workspace: WorkspaceState
    @ObservedObject private var themeManager = ThemeManager.shared
    @State private var isCreatingFile = false
    @State private var newFileName = ""

    private var activeFilePath: String? {
        workspace.activeTab?.url?.standardized.path
    }

    private var treeActions: FileTreeActions {
        FileTreeActions(
            onOpen: { workspace.openFile(url: $0) },
            onNewFile: { workspace.promptNewFile(inside: $0) },
            onNewFolder: { workspace.promptNewFolder(inside: $0) },
            onRename: { workspace.promptRenameItem(at: $0, isDirectory: $1) },
            onDuplicate: { workspace.duplicateItem(at: $0, isDirectory: $1) },
            onDelete: { workspace.promptDeleteItem(at: $0, isDirectory: $1) },
            onCopyPath: { workspace.copyPathToPasteboard($0, relative: $1) },
            onRevealInFinder: { workspace.revealInFinder($0) }
        )
    }

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
        let currentPath = activeFilePath
        let actions = treeActions
        return VStack(spacing: 0) {
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
                                FileTreeNodeView(
                                    item: item,
                                    activeFilePath: currentPath,
                                    uiFontSize: themeManager.uiFontSize,
                                    themeID: themeManager.currentThemeID,
                                    depth: 0,
                                    actions: actions
                                )
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

// MARK: - Explorer File Tree Row (Decoupled from WorkspaceState ObservableObject)

private struct FileTreeActions {
    let onOpen: (URL) -> Void
    let onNewFile: (URL) -> Void
    let onNewFolder: (URL) -> Void
    let onRename: (URL, Bool) -> Void
    let onDuplicate: (URL, Bool) -> Void
    let onDelete: (URL, Bool) -> Void
    let onCopyPath: (URL, Bool) -> Void
    let onRevealInFinder: (URL) -> Void
}

private struct FileTreeNodeView: View {
    @ObservedObject var item: FileItem
    let activeFilePath: String?
    let uiFontSize: CGFloat
    let themeID: ThemeID
    let depth: Int
    let actions: FileTreeActions
    @State private var isHovered = false

    private var isSelected: Bool {
        activeFilePath == item.url.standardized.path
    }

    var body: some View {
        let _ = themeID
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
                    actions.onOpen(item.url)
                }
            }
            .contextMenu {
                let targetDirectory = item.isDirectory ? item.url : item.url.deletingLastPathComponent()

                if !item.isDirectory {
                    Button(L10n("explorer.context.open")) {
                        actions.onOpen(item.url)
                    }
                    Divider()
                }

                Button(L10n("explorer.context.newFile")) {
                    DispatchQueue.main.async {
                        actions.onNewFile(targetDirectory)
                    }
                }
                Button(L10n("explorer.context.newFolder")) {
                    DispatchQueue.main.async {
                        actions.onNewFolder(targetDirectory)
                    }
                }

                Divider()

                Button(L10n("explorer.context.rename")) {
                    DispatchQueue.main.async {
                        actions.onRename(item.url, item.isDirectory)
                    }
                }
                Button(L10n("explorer.context.duplicate")) {
                    actions.onDuplicate(item.url, item.isDirectory)
                }
                Button(L10n("explorer.context.delete"), role: .destructive) {
                    DispatchQueue.main.async {
                        actions.onDelete(item.url, item.isDirectory)
                    }
                }

                Divider()

                Button(L10n("explorer.context.copyPath")) {
                    actions.onCopyPath(item.url, false)
                }
                Button(L10n("explorer.context.copyRelativePath")) {
                    actions.onCopyPath(item.url, true)
                }
                Button(L10n("explorer.context.revealInFinder")) {
                    actions.onRevealInFinder(item.url)
                }
            }

            if item.isDirectory && item.isExpanded, let children = item.children {
                ForEach(children) { child in
                    FileTreeNodeView(
                        item: child,
                        activeFilePath: activeFilePath,
                        uiFontSize: uiFontSize,
                        themeID: themeID,
                        depth: depth + 1,
                        actions: actions
                    )
                }
            }
        }
    }
}
