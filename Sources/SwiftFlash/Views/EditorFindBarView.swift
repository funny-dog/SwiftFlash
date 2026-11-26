import AppKit
import SwiftUI

struct EditorFindBarView: View {
    @ObservedObject var workspace: WorkspaceState
    @ObservedObject var findState: EditorFindState
    @ObservedObject private var themeManager = ThemeManager.shared
    @FocusState private var focusedField: FocusField?

    private enum FocusField {
        case find
        case replace
        case goToLine
    }

    var body: some View {
        VStack(spacing: 6) {
            if findState.isFindBarVisible {
                findRow
                if findState.isReplaceExpanded {
                    replaceRow
                }
            }
            if findState.isGoToLineVisible {
                goToLineRow
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color(nsColor: ZedTheme.sidebarBackground))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: ZedTheme.border))
                .frame(height: 1)
        }
        .onAppear {
            requestAppropriateFocus()
        }
        .onChange(of: findState.focusRequestNonce) { _, _ in
            requestAppropriateFocus()
        }
        .onChange(of: findState.isFindBarVisible) { _, visible in
            if visible {
                requestAppropriateFocus()
            }
        }
        .onChange(of: findState.isGoToLineVisible) { _, visible in
            if visible {
                requestAppropriateFocus()
            }
        }
    }

    private func requestAppropriateFocus() {
        let target: FocusField? = findState.isGoToLineVisible
            ? .goToLine
            : (findState.isFindBarVisible ? .find : nil)
        guard let target else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            focusedField = target
        }
    }

    private var findRow: some View {
        HStack(spacing: 6) {
            Button {
                findState.isReplaceExpanded.toggle()
            } label: {
                Image(systemName: findState.isReplaceExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Color(nsColor: ZedTheme.secondaryText))
                    .frame(width: 18, height: 22)
            }
            .buttonStyle(.plain)
            .help(L10n("find.toggleReplaceHelp"))

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(Color(nsColor: ZedTheme.mutedText))

                TextField(L10n("find.placeholder"), text: $findState.findQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(Color(nsColor: ZedTheme.primaryText))
                    .focused($focusedField, equals: .find)
                    .onSubmit {
                        workspace.findNextInActiveFile()
                    }
                    .onChange(of: findState.findQuery) { _, _ in
                        workspace.recomputeFindMatches()
                    }
                    .onKeyPress(.escape) {
                        workspace.closeFindAndGoToLine()
                        return .handled
                    }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(minWidth: 200, maxWidth: 280)
            .background(Color(nsColor: ZedTheme.background))
            .cornerRadius(5)
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Color(nsColor: ZedTheme.border), lineWidth: 1)
            )

            toggleChip(
                label: "Aa",
                isActive: findState.isCaseSensitive,
                helpText: L10n("find.caseSensitiveHelp")
            ) {
                findState.isCaseSensitive.toggle()
                workspace.recomputeFindMatches()
            }

            toggleChip(
                label: ".*",
                isActive: findState.isRegex,
                helpText: L10n("find.regexHelp")
            ) {
                findState.isRegex.toggle()
                workspace.recomputeFindMatches()
            }

            Text(matchCounterText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(
                    findState.matches.isEmpty && !findState.findQuery.isEmpty
                        ? Color(nsColor: ZedTheme.attribute)
                        : Color(nsColor: ZedTheme.mutedText)
                )
                .frame(minWidth: 56, alignment: .center)

            iconButton(icon: "chevron.up", helpText: L10n("find.previousHelp")) {
                workspace.findPreviousInActiveFile()
            }
            .disabled(findState.matches.isEmpty)

            iconButton(icon: "chevron.down", helpText: L10n("find.nextHelp")) {
                workspace.findNextInActiveFile()
            }
            .disabled(findState.matches.isEmpty)

            Spacer()

            iconButton(icon: "xmark", helpText: "ESC") {
                workspace.closeFindAndGoToLine()
            }
        }
    }

    private var replaceRow: some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: 18, height: 22)

            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 10.5))
                    .foregroundColor(Color(nsColor: ZedTheme.mutedText))

                TextField(L10n("find.replacePlaceholder"), text: $findState.replaceQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(Color(nsColor: ZedTheme.primaryText))
                    .focused($focusedField, equals: .replace)
                    .onSubmit {
                        workspace.replaceCurrentInActiveFile()
                    }
                    .onKeyPress(.escape) {
                        workspace.closeFindAndGoToLine()
                        return .handled
                    }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(minWidth: 200, maxWidth: 280)
            .background(Color(nsColor: ZedTheme.background))
            .cornerRadius(5)
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Color(nsColor: ZedTheme.border), lineWidth: 1)
            )

            actionButton(title: L10n("find.replaceButton")) {
                workspace.replaceCurrentInActiveFile()
            }
            .disabled(findState.matches.isEmpty)

            actionButton(title: L10n("find.replaceAllButton")) {
                workspace.replaceAllInActiveFile()
            }
            .disabled(findState.matches.isEmpty)

            Spacer()
        }
    }

    private var goToLineRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.right.to.line")
                .font(.system(size: 11))
                .foregroundColor(Color(nsColor: ZedTheme.function))

            Text(L10n("goToLine.label"))
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(Color(nsColor: ZedTheme.secondaryText))

            TextField(L10n("goToLine.placeholder"), text: $findState.goToLineInput)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(Color(nsColor: ZedTheme.primaryText))
                .focused($focusedField, equals: .goToLine)
                .frame(width: 140)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(nsColor: ZedTheme.background))
                .cornerRadius(5)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(Color(nsColor: ZedTheme.border), lineWidth: 1)
                )
                .onSubmit {
                    workspace.commitGoToLine()
                }
                .onKeyPress(.escape) {
                    workspace.closeFindAndGoToLine()
                    return .handled
                }

            actionButton(title: L10n("goToLine.jump")) {
                workspace.commitGoToLine()
            }

            Spacer()

            iconButton(icon: "xmark", helpText: "ESC") {
                findState.isGoToLineVisible = false
                findState.goToLineInput = ""
                workspace.onFocusEditorRequested?()
            }
        }
    }

    private var matchCounterText: String {
        if findState.findQuery.isEmpty { return "" }
        if findState.matches.isEmpty { return L10n("find.noResults") }
        let idx = max(0, findState.currentMatchIndex) + 1
        return "\(idx)/\(findState.matches.count)"
    }

    private func toggleChip(label: String, isActive: Bool, helpText: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(Color(nsColor: isActive ? ZedTheme.pillText : ZedTheme.secondaryText))
                .padding(.horizontal, 6)
                .padding(.vertical, 3.5)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(nsColor: isActive ? ZedTheme.pillBackground : ZedTheme.background))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color(nsColor: ZedTheme.border), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help(helpText)
    }

    private func iconButton(icon: String, helpText: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Color(nsColor: ZedTheme.secondaryText))
                .frame(width: 24, height: 22)
                .background(Color(nsColor: ZedTheme.background))
                .cornerRadius(4)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color(nsColor: ZedTheme.border), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help(helpText)
    }

    private func actionButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Color(nsColor: ZedTheme.primaryText))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Color(nsColor: ZedTheme.background))
                .cornerRadius(4)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color(nsColor: ZedTheme.border), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}
