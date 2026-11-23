import AppKit
import SwiftUI

enum BottomPanelTab: String, CaseIterable {
    case terminal
    case run
    case problems
}

struct BottomPanelView: View {
    @ObservedObject var workspace: WorkspaceState
    @ObservedObject var session: TerminalSession
    @ObservedObject var taskRunner: TaskRunnerState
    @ObservedObject private var themeManager = ThemeManager.shared

    private var consoleFont: Font {
        let size = max(11, themeManager.editorFontSize - 1)
        if themeManager.editorFontFamily == "System Monospace" {
            return .system(size: size, design: .monospaced)
        }
        if let nsFont = NSFont(name: themeManager.editorFontFamily, size: size) {
            return Font(nsFont)
        }
        return .system(size: size, design: .monospaced)
    }

    var body: some View {
        VStack(spacing: 0) {
            panelHeader

            switch workspace.bottomPanelTab {
            case .terminal:
                IntegratedTerminalView(workspace: workspace, session: session, showHeader: false)
            case .run:
                runOutputBody
            case .problems:
                problemsBody
            }
        }
        .background(Color(nsColor: ZedTheme.background))
    }

    private var panelHeader: some View {
        HStack(spacing: 8) {
            tabPill(
                tab: .terminal,
                icon: "terminal.fill",
                title: L10n("panel.tab.terminal"),
                badgeCount: 0,
                badgeColor: ZedTheme.string
            )

            tabPill(
                tab: .run,
                icon: taskRunner.isRunning ? "play.circle.fill" : "play.fill",
                title: L10n("panel.tab.run"),
                badgeCount: 0,
                badgeColor: ZedTheme.function
            )

            let errorCount = workspace.totalErrorCount
            let warningCount = workspace.totalWarningCount
            tabPill(
                tab: .problems,
                icon: "exclamationmark.triangle",
                title: L10n("panel.tab.problems"),
                badgeCount: errorCount + warningCount,
                badgeColor: errorCount > 0 ? NSColor(hex: 0xE06C75) : NSColor(hex: 0xE5C07B)
            )

            Spacer()

            if workspace.bottomPanelTab == .terminal {
                Text(session.currentDirectory.lastPathComponent)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Color(nsColor: ZedTheme.mutedText))

                if session.isRunning {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 12, height: 12)
                }

                quickChip("swift build", color: ZedTheme.function) {
                    session.runCommand("swift build")
                }
                quickChip("git status", color: ZedTheme.keyword) {
                    session.runCommand("git status -sb")
                }
                if session.isRunning {
                    quickChip(L10n("terminal.stop"), color: ZedTheme.attribute) {
                        session.terminateRunningCommand()
                    }
                }
                headerIcon(icon: "trash", help: L10n("terminal.clearHelp")) {
                    session.clear()
                }
            } else if workspace.bottomPanelTab == .run {
                if !taskRunner.activeTaskName.isEmpty {
                    Text(taskRunner.activeTaskName)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Color(nsColor: ZedTheme.mutedText))
                }
                if taskRunner.isRunning {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 12, height: 12)
                    quickChip(L10n("runner.stop"), color: ZedTheme.attribute) {
                        taskRunner.stop()
                    }
                } else if let task = taskRunner.selectedTask {
                    quickChip(L10n("runner.rerun"), color: ZedTheme.string) {
                        workspace.runTask(task)
                    }
                }
                headerIcon(icon: "trash", help: L10n("runner.clearHelp")) {
                    taskRunner.clear()
                }
            } else if workspace.bottomPanelTab == .problems {
                if errorCount > 0 || warningCount > 0 {
                    Text(L10n("problems.summaryFormat", errorCount, warningCount))
                        .font(.system(size: 11))
                        .foregroundColor(Color(nsColor: ZedTheme.mutedText))
                }
            }

            headerIcon(icon: "xmark", help: L10n("terminal.hideHelp")) {
                workspace.onToggleTerminalAction?()
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Color(nsColor: ZedTheme.tabBarBackground))
        .overlay(alignment: .top) {
            Rectangle().fill(Color(nsColor: ZedTheme.border)).frame(height: 1)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(nsColor: ZedTheme.border)).frame(height: 1)
        }
    }

    private func tabPill(
        tab: BottomPanelTab,
        icon: String,
        title: String,
        badgeCount: Int,
        badgeColor: NSColor
    ) -> some View {
        let isActive = workspace.bottomPanelTab == tab
        return Button {
            workspace.bottomPanelTab = tab
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10.5, weight: .medium))
                Text(title)
                    .font(.system(size: 11, weight: isActive ? .semibold : .medium))
                if badgeCount > 0 {
                    Text("\(badgeCount)")
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color(nsColor: badgeColor)))
                }
            }
            .foregroundColor(Color(nsColor: isActive ? ZedTheme.primaryText : ZedTheme.secondaryText))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isActive ? Color(nsColor: ZedTheme.activeTabBackground) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    private var runOutputBody: some View {
        Group {
            if taskRunner.outputLines.isEmpty {
                VStack(spacing: 8) {
                    Text(L10n("runner.empty"))
                        .font(.system(size: 12))
                        .foregroundColor(Color(nsColor: ZedTheme.mutedText))
                    if let task = taskRunner.selectedTask {
                        quickChip("\(L10n("runner.run")) \(task.name) (⌘R)", color: ZedTheme.string) {
                            workspace.runTask(task)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(taskRunner.outputLines) { line in
                                if let loc = line.location {
                                    Button {
                                        workspace.openFile(url: loc.url, atLine: loc.line)
                                    } label: {
                                        Text(line.text)
                                            .font(consoleFont)
                                            .foregroundColor(Color(nsColor: line.isError ? ZedTheme.attribute : ZedTheme.function))
                                            .underline()
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .buttonStyle(.plain)
                                    .help("\(loc.url.lastPathComponent):\(loc.line)")
                                } else {
                                    Text(line.text)
                                        .font(consoleFont)
                                        .foregroundColor(Color(nsColor: line.isError ? ZedTheme.attribute : ZedTheme.plainText))
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            Color.clear.frame(height: 1).id("RUN_BOTTOM")
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                    .onChange(of: taskRunner.outputLines.count) { _, _ in
                        proxy.scrollTo("RUN_BOTTOM", anchor: .bottom)
                    }
                }
            }
        }
    }

    private var problemsBody: some View {
        let items = workspace.allDiagnosticEntries
        return Group {
            if items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 20))
                        .foregroundColor(Color(nsColor: ZedTheme.string))
                    Text(L10n("problems.empty"))
                        .font(.system(size: 12))
                        .foregroundColor(Color(nsColor: ZedTheme.mutedText))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(items) { entry in
                            Button {
                                workspace.openFile(url: entry.fileURL, atLine: entry.diagnostic.range.start.line + 1)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: entry.diagnostic.severity.iconName)
                                        .font(.system(size: 11))
                                        .foregroundColor(Color(nsColor: NSColor(hex: entry.diagnostic.severity.colorHex)))

                                    Text(entry.diagnostic.message)
                                        .font(.system(size: 12))
                                        .foregroundColor(Color(nsColor: ZedTheme.primaryText))
                                        .lineLimit(1)
                                        .truncationMode(.tail)

                                    Spacer(minLength: 10)

                                    if let source = entry.diagnostic.source {
                                        Text(source)
                                            .font(.system(size: 10.5))
                                            .foregroundColor(Color(nsColor: ZedTheme.mutedText))
                                    }

                                    Text("\(entry.relativePath):\(entry.diagnostic.range.start.line + 1):\(entry.diagnostic.range.start.character + 1)")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(Color(nsColor: ZedTheme.function))
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color.clear)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
    }

    private func quickChip(_ title: String, color: NSColor, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundColor(Color(nsColor: color))
                .padding(.horizontal, 7)
                .padding(.vertical, 2.5)
                .background(Color(nsColor: ZedTheme.background))
                .cornerRadius(4)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color(nsColor: ZedTheme.border), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private func headerIcon(icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(Color(nsColor: ZedTheme.secondaryText))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
