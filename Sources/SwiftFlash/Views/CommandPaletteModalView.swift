import AppKit
import SwiftUI

struct PaletteCommand: Identifiable {
    let id: String
    let title: String
    let category: String
    let shortcut: String
    let icon: String
    let keywords: String
    let action: @MainActor () -> Void
}

struct CommandPaletteModalView: View {
    @ObservedObject var workspace: WorkspaceState
    @ObservedObject private var themeManager = ThemeManager.shared
    @State private var query: String = ""
    @State private var selectedIndex: Int = 0
    @State private var countBox = SwitcherCountBox()
    @State private var eventMonitor: Any?
    @FocusState private var isInputFocused: Bool

    private var allCommands: [PaletteCommand] {
        [
            PaletteCommand(
                id: "file.quickOpen",
                title: L10n("menu.view.quickOpen"),
                category: "File",
                shortcut: "⌘P",
                icon: "doc.text.magnifyingglass",
                keywords: "open file quick",
                action: { workspace.toggleOverlay(.quickOpen) }
            ),
            PaletteCommand(
                id: "symbols.outline",
                title: L10n("symbols.title"),
                category: "Go",
                shortcut: "⌘⇧O",
                icon: "list.bullet.indent",
                keywords: "symbol outline function class struct",
                action: { workspace.toggleOverlay(.symbolOutline) }
            ),
            PaletteCommand(
                id: "editor.format",
                title: L10n("menu.edit.formatDocument"),
                category: "Editor",
                shortcut: "⌥⇧F",
                icon: "wand.and.stars",
                keywords: "format pretty prettier swiftformat",
                action: { workspace.formatActiveDocument() }
            ),
            PaletteCommand(
                id: "lsp.definition",
                title: L10n("menu.edit.goToDefinition"),
                category: "LSP",
                shortcut: "F12",
                icon: "arrow.right.circle",
                keywords: "definition jump goto",
                action: { workspace.onGoToDefinitionAction?() }
            ),
            PaletteCommand(
                id: "lsp.references",
                title: L10n("menu.edit.findReferences"),
                category: "LSP",
                shortcut: "⇧F12",
                icon: "point.3.connected.trianglepath.dotted",
                keywords: "references usages callers",
                action: { workspace.onFindReferencesAction?() }
            ),
            PaletteCommand(
                id: "lsp.hover",
                title: L10n("menu.edit.showHover"),
                category: "LSP",
                shortcut: "⌘K",
                icon: "info.circle",
                keywords: "hover docs type info",
                action: { workspace.onShowHoverAction?() }
            ),
            PaletteCommand(
                id: "nav.back",
                title: L10n("menu.go.back"),
                category: "Go",
                shortcut: "⌃-",
                icon: "chevron.backward",
                keywords: "navigate back history previous",
                action: { workspace.navigateBack() }
            ),
            PaletteCommand(
                id: "nav.forward",
                title: L10n("menu.go.forward"),
                category: "Go",
                shortcut: "⌃⇧-",
                icon: "chevron.forward",
                keywords: "navigate forward history next",
                action: { workspace.navigateForward() }
            ),
            PaletteCommand(
                id: "editor.split",
                title: L10n("menu.view.toggleSplitEditor"),
                category: "View",
                shortcut: "⌘\\",
                icon: "rectangle.split.2x1",
                keywords: "split pane side by side editor",
                action: { workspace.toggleSplitEditor() }
            ),
            PaletteCommand(
                id: "window.new",
                title: L10n("menu.file.newWindow"),
                category: "Window",
                shortcut: "⌘⇧N",
                icon: "macwindow.badge.plus",
                keywords: "new window multi",
                action: { workspace.onNewWindowRequested?() }
            ),
            PaletteCommand(
                id: "file.openFolderNewWindow",
                title: L10n("menu.file.openFolderNewWindow"),
                category: "Window",
                shortcut: "",
                icon: "folder.badge.plus",
                keywords: "open folder new window project",
                action: { workspace.onOpenFolderInNewWindowRequested?() }
            ),
            PaletteCommand(
                id: "file.new",
                title: L10n("menu.file.new"),
                category: "File",
                shortcut: "⌘N",
                icon: "doc.badge.plus",
                keywords: "new untitled buffer",
                action: { workspace.createNewUntitledFile() }
            ),
            PaletteCommand(
                id: "file.openFolder",
                title: L10n("menu.file.openFolder"),
                category: "File",
                shortcut: "⌘O",
                icon: "folder",
                keywords: "open directory project",
                action: { workspace.openFolderPanel() }
            ),
            PaletteCommand(
                id: "file.save",
                title: L10n("menu.file.save"),
                category: "File",
                shortcut: "⌘S",
                icon: "square.and.arrow.down",
                keywords: "save write file",
                action: { workspace.saveActiveTabWithOptionalFormatting() }
            ),
            PaletteCommand(
                id: "project.switch",
                title: L10n("menu.file.switchProject"),
                category: "Project",
                shortcut: "⌃⌘O",
                icon: "folder.badge.gearshape",
                keywords: "switch project recent",
                action: { workspace.toggleOverlay(.projectSwitcher) }
            ),
            PaletteCommand(
                id: "git.worktree",
                title: L10n("menu.view.switchWorktree"),
                category: "Git",
                shortcut: "⌘⇧W",
                icon: "arrow.up.right.and.arrow.down.left",
                keywords: "git worktree switch",
                action: { workspace.toggleOverlay(.worktreeSwitcher) }
            ),
            PaletteCommand(
                id: "git.branch",
                title: L10n("menu.view.switchBranch"),
                category: "Git",
                shortcut: "⌘⇧B",
                icon: "arrow.triangle.branch",
                keywords: "git branch checkout",
                action: { workspace.toggleOverlay(.branchSwitcher) }
            ),
            PaletteCommand(
                id: "git.panel",
                title: L10n("menu.view.toggleGitPanel"),
                category: "Git",
                shortcut: "⌃⇧G",
                icon: "arrow.triangle.pull",
                keywords: "git changes commit stage",
                action: { workspace.toggleDockPanel(.git) }
            ),
            PaletteCommand(
                id: "git.diff",
                title: L10n("menu.view.viewGitDiff"),
                category: "Git",
                shortcut: "⌃⌘D",
                icon: "plusminus",
                keywords: "git diff changes",
                action: { workspace.openGitDiffInEditor() }
            ),
            PaletteCommand(
                id: "search.workspace",
                title: L10n("menu.edit.findInWorkspace"),
                category: "Search",
                shortcut: "⌘⇧F",
                icon: "magnifyingglass",
                keywords: "global search find replace workspace",
                action: {
                    workspace.toggleDockPanel(.search)
                    workspace.searchFocusNonce &+= 1
                }
            ),
            PaletteCommand(
                id: "search.file",
                title: L10n("menu.edit.find"),
                category: "Search",
                shortcut: "⌘F",
                icon: "text.magnifyingglass",
                keywords: "find file",
                action: { workspace.presentFindBar(replace: false) }
            ),
            PaletteCommand(
                id: "search.replace",
                title: L10n("menu.edit.findReplace"),
                category: "Search",
                shortcut: "⌥⌘F",
                icon: "arrow.2.squarepath",
                keywords: "find replace file",
                action: { workspace.presentFindBar(replace: true) }
            ),
            PaletteCommand(
                id: "go.line",
                title: L10n("menu.edit.goToLine"),
                category: "Go",
                shortcut: "⌘L",
                icon: "number",
                keywords: "goto line number",
                action: { workspace.presentGoToLine() }
            ),
            PaletteCommand(
                id: "edit.selectNext",
                title: L10n("menu.edit.selectNextOccurrence"),
                category: "Edit",
                shortcut: "⌘D",
                icon: "cursorarrow.click.2",
                keywords: "multi cursor select next occurrence word",
                action: { workspace.onSelectNextOccurrenceAction?() }
            ),
            PaletteCommand(
                id: "edit.deleteLine",
                title: L10n("menu.edit.deleteLine"),
                category: "Edit",
                shortcut: "⌘⇧K",
                icon: "trash",
                keywords: "delete remove line",
                action: { workspace.onDeleteLinesAction?() }
            ),
            PaletteCommand(
                id: "edit.toggleComment",
                title: L10n("menu.edit.toggleComment"),
                category: "Edit",
                shortcut: "⌘/",
                icon: "text.bubble",
                keywords: "comment toggle line",
                action: { workspace.onToggleCommentRequested?() }
            ),
            PaletteCommand(
                id: "terminal.toggle",
                title: L10n("menu.view.toggleTerminal"),
                category: "Terminal",
                shortcut: "⌘J",
                icon: "terminal",
                keywords: "terminal shell pty bottom",
                action: { workspace.onToggleTerminalAction?() }
            ),
            PaletteCommand(
                id: "terminal.newTab",
                title: L10n("terminal.newTab"),
                category: "Terminal",
                shortcut: "⌃⇧`",
                icon: "plus.rectangle",
                keywords: "new terminal tab shell pty",
                action: {
                    workspace.showBottomPanel(.terminal)
                    workspace.onNewTerminalTabAction?()
                }
            ),
            PaletteCommand(
                id: "panel.problems",
                title: L10n("menu.view.showProblems"),
                category: "View",
                shortcut: "",
                icon: "exclamationmark.triangle",
                keywords: "problems errors warnings diagnostics",
                action: { workspace.showBottomPanel(.problems) }
            ),
            PaletteCommand(
                id: "run.project",
                title: L10n("menu.run.run"),
                category: "Run",
                shortcut: "⌘R",
                icon: "play.fill",
                keywords: "run build execute task",
                action: { workspace.runDefaultRunTask() }
            ),
            PaletteCommand(
                id: "run.test",
                title: L10n("menu.run.test"),
                category: "Run",
                shortcut: "⌘U",
                icon: "checkmark.diamond",
                keywords: "test unit pytest cargo swift",
                action: { workspace.runDefaultTestTask() }
            ),
            PaletteCommand(
                id: "run.stop",
                title: L10n("menu.run.stop"),
                category: "Run",
                shortcut: "⌘.",
                icon: "stop.fill",
                keywords: "stop cancel task",
                action: { workspace.stopRunningTask() }
            ),
            PaletteCommand(
                id: "view.sidebar",
                title: L10n("menu.view.toggleSidebar"),
                category: "View",
                shortcut: "⌘B",
                icon: "sidebar.left",
                keywords: "sidebar explorer toggle",
                action: { workspace.onToggleSidebarAction?() }
            ),
            PaletteCommand(
                id: "settings.open",
                title: L10n("menu.app.settings"),
                category: "Settings",
                shortcut: "⌘,",
                icon: "paintbrush",
                keywords: "settings theme font language",
                action: { workspace.openSettings(section: .appearance) }
            ),
            PaletteCommand(
                id: "settings.lsp",
                title: L10n("settings.tab.languageServers"),
                category: "Settings",
                shortcut: "",
                icon: "server.rack",
                keywords: "lsp language server install status",
                action: { workspace.openSettings(section: .languageServers) }
            ),
            PaletteCommand(
                id: "settings.toggleFormatOnSave",
                title: L10n("command.toggleFormatOnSave"),
                category: "Settings",
                shortcut: "",
                icon: "checkmark.seal",
                keywords: "format on save auto",
                action: {
                    ThemeManager.shared.formatOnSave.toggle()
                    workspace.statusMessage = ThemeManager.shared.formatOnSave
                        ? L10n("status.formatOnSaveEnabled")
                        : L10n("status.formatOnSaveDisabled")
                }
            )
        ]
    }

    private var filteredCommands: [PaletteCommand] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return allCommands }
        return allCommands.filter { cmd in
            switcherFuzzyMatches(query: trimmed, candidate: cmd.title)
                || switcherFuzzyMatches(query: trimmed, candidate: "\(cmd.category) \(cmd.keywords)")
        }
    }

    var body: some View {
        let items = filteredCommands
        ZStack {
            Color.black.opacity(ZedTheme.isDark ? 0.42 : 0.22)
                .ignoresSafeArea()
                .onTapGesture {
                    workspace.dismissOverlay()
                }

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "command")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundColor(Color(nsColor: ZedTheme.function))

                    TextField(L10n("commandPalette.placeholder"), text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .foregroundColor(Color(nsColor: ZedTheme.primaryText))
                        .focused($isInputFocused)
                        .onSubmit {
                            executeSelected(items: items)
                        }

                    Text("⌘⇧P")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(Color(nsColor: ZedTheme.mutedText))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(nsColor: ZedTheme.background))
                        .cornerRadius(4)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

                Divider().overlay(Color(nsColor: ZedTheme.border))

                if items.isEmpty {
                    Text(L10n("commandPalette.empty"))
                        .font(.system(size: 12.5))
                        .foregroundColor(Color(nsColor: ZedTheme.mutedText))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 28)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 2) {
                                ForEach(Array(items.enumerated()), id: \.element.id) { idx, cmd in
                                    let isSelected = idx == selectedIndex
                                    Button {
                                        run(cmd)
                                    } label: {
                                        HStack(spacing: 10) {
                                            Image(systemName: cmd.icon)
                                                .font(.system(size: 11.5))
                                                .foregroundColor(Color(nsColor: isSelected ? ZedTheme.function : ZedTheme.secondaryText))
                                                .frame(width: 16)

                                            Text(cmd.category)
                                                .font(.system(size: 10.5, weight: .medium))
                                                .foregroundColor(Color(nsColor: ZedTheme.mutedText))
                                                .frame(minWidth: 52, alignment: .leading)

                                            Text(cmd.title)
                                                .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                                                .foregroundColor(Color(nsColor: ZedTheme.primaryText))
                                                .lineLimit(1)

                                            Spacer()

                                            if !cmd.shortcut.isEmpty {
                                                Text(cmd.shortcut)
                                                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                                    .foregroundColor(Color(nsColor: ZedTheme.function))
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 2)
                                                    .background(Color(nsColor: ZedTheme.background))
                                                    .cornerRadius(4)
                                            }
                                        }
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 7)
                                        .background(
                                            RoundedRectangle(cornerRadius: 6)
                                                .fill(isSelected ? Color(nsColor: ZedTheme.selectionBackground) : Color.clear)
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .id(idx)
                                }
                            }
                            .padding(6)
                        }
                        .frame(maxHeight: 380)
                        .onChange(of: selectedIndex) { _, newIdx in
                            proxy.scrollTo(newIdx, anchor: .center)
                        }
                    }
                }
            }
            .frame(width: 600)
            .background(Color(nsColor: ZedTheme.sidebarBackground))
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color(nsColor: ZedTheme.border), lineWidth: 1)
            )
            .shadow(color: .black.opacity(ZedTheme.isDark ? 0.55 : 0.2), radius: 28, y: 12)
            .padding(.top, 70)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .onAppear {
            query = ""
            selectedIndex = 0
            countBox.count = filteredCommands.count
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                isInputFocused = true
            }
            installKeyMonitor()
        }
        .onChange(of: query) { _, _ in
            selectedIndex = 0
            countBox.count = filteredCommands.count
        }
        .onDisappear {
            removeKeyMonitor()
        }
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        let box = countBox
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.window === NSApp.keyWindow,
                  !SwitcherKeyboardSupport.hasActiveMarkedText() else {
                return event
            }
            switch Int(event.keyCode) {
            case 53:
                workspace.dismissOverlay()
                return nil
            case 125:
                if box.count > 0 {
                    selectedIndex = min(selectedIndex + 1, box.count - 1)
                }
                return nil
            case 126:
                if box.count > 0 {
                    selectedIndex = max(selectedIndex - 1, 0)
                }
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }

    private func executeSelected(items: [PaletteCommand]) {
        guard !items.isEmpty else { return }
        let idx = min(max(0, selectedIndex), items.count - 1)
        run(items[idx])
    }

    private func run(_ cmd: PaletteCommand) {
        workspace.dismissOverlay()
        DispatchQueue.main.async {
            cmd.action()
        }
    }
}
