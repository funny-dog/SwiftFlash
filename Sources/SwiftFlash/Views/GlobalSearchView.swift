import SwiftUI

struct GlobalSearchView: View {
    private struct FileSearchGroup: Identifiable {
        var id: String { url.standardized.path }
        let url: URL
        let relativePath: String
        let matches: [SearchMatch]
    }

    @ObservedObject var workspace: WorkspaceState
    @ObservedObject private var themeManager = ThemeManager.shared
    @FocusState private var isSearchFocused: Bool
    @State private var showFileFilters = false
    @State private var collapsedFilePaths: Set<String> = []

    private var groupedResults: [FileSearchGroup] {
        var order: [String] = []
        var map: [String: (url: URL, rel: String, matches: [SearchMatch])] = [:]
        for match in workspace.searchResults {
            let key = match.url.standardized.path
            if map[key] == nil {
                order.append(key)
                map[key] = (match.url, match.relativePath, [match])
            } else {
                map[key]?.matches.append(match)
            }
        }
        return order.compactMap { key in
            guard let item = map[key] else { return nil }
            return FileSearchGroup(url: item.url, relativePath: item.rel, matches: item.matches)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                // Search Query Row + Toggle Replace & Options
                HStack(spacing: 5) {
                    Button {
                        workspace.isGlobalReplaceExpanded.toggle()
                    } label: {
                        Image(systemName: workspace.isGlobalReplaceExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(Color(nsColor: ZedTheme.secondaryText))
                            .frame(width: 14, height: 18)
                    }
                    .buttonStyle(.plain)
                    .help(L10n("find.toggleReplaceHelp"))

                    HStack(spacing: 5) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 10.5))
                            .foregroundColor(Color(nsColor: ZedTheme.mutedText))

                        TextField(L10n("search.placeholder"), text: $workspace.searchQuery)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                            .foregroundColor(Color(nsColor: ZedTheme.primaryText))
                            .focused($isSearchFocused)
                            .onSubmit {
                                workspace.performGlobalSearch(debounceMs: 0)
                            }
                            .onChange(of: workspace.searchQuery) { _, _ in
                                workspace.performGlobalSearch()
                            }

                        if !workspace.searchQuery.isEmpty {
                            Button {
                                workspace.searchQuery = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 10.5))
                                    .foregroundColor(Color(nsColor: ZedTheme.mutedText))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .background(Color(nsColor: ZedTheme.background))
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(
                                Color(nsColor: workspace.searchRegexError != nil ? ZedTheme.attribute : ZedTheme.border),
                                lineWidth: 1
                            )
                    )
                }

                // Replace Input Row
                if workspace.isGlobalReplaceExpanded {
                    HStack(spacing: 5) {
                        Spacer().frame(width: 14)

                        TextField(L10n("find.replacePlaceholder"), text: $workspace.globalReplaceQuery)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                            .foregroundColor(Color(nsColor: ZedTheme.primaryText))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 5)
                            .background(Color(nsColor: ZedTheme.background))
                            .cornerRadius(6)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color(nsColor: ZedTheme.border), lineWidth: 1)
                            )

                        Button {
                            workspace.confirmAndReplaceAllInWorkspace()
                        } label: {
                            Image(systemName: "arrow.2.squarepath")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundColor(Color(nsColor: ZedTheme.pillText))
                                .frame(width: 24, height: 24)
                                .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: ZedTheme.pillBackground)))
                        }
                        .buttonStyle(.plain)
                        .disabled(workspace.searchResults.isEmpty)
                        .opacity(workspace.searchResults.isEmpty ? 0.45 : 1)
                        .help(L10n("search.replaceAll.help"))
                    }
                }

                // Option Toggles (Aa / Whole Word / Regex / File Globs)
                HStack(spacing: 5) {
                    optionPill("Aa", active: workspace.searchCaseSensitive, help: L10n("find.caseSensitiveHelp")) {
                        workspace.searchCaseSensitive.toggle()
                        workspace.performGlobalSearch(debounceMs: 0)
                    }
                    optionPill("W", active: workspace.searchWholeWord, help: L10n("search.wholeWordHelp")) {
                        workspace.searchWholeWord.toggle()
                        workspace.performGlobalSearch(debounceMs: 0)
                    }
                    optionPill(".*", active: workspace.searchUseRegex, help: L10n("find.regexHelp")) {
                        workspace.searchUseRegex.toggle()
                        workspace.performGlobalSearch(debounceMs: 0)
                    }

                    Spacer()

                    Button {
                        showFileFilters.toggle()
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "line.3.horizontal.decrease")
                                .font(.system(size: 9.5, weight: .semibold))
                            Text(L10n("search.filesFilter"))
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundColor(
                            Color(nsColor: (showFileFilters || !workspace.searchIncludeGlob.isEmpty || !workspace.searchExcludeGlob.isEmpty)
                                  ? ZedTheme.function
                                  : ZedTheme.mutedText)
                        )
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2.5)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: ZedTheme.background)))
                    }
                    .buttonStyle(.plain)
                }

                if showFileFilters {
                    VStack(spacing: 4) {
                        filterField(
                            placeholder: L10n("search.includePlaceholder"),
                            text: $workspace.searchIncludeGlob
                        )
                        filterField(
                            placeholder: L10n("search.excludePlaceholder"),
                            text: $workspace.searchExcludeGlob
                        )
                    }
                }

                // Status Summary Row
                HStack {
                    if let err = workspace.searchRegexError {
                        Text(err)
                            .font(.system(size: 10))
                            .foregroundColor(Color(nsColor: ZedTheme.attribute))
                            .lineLimit(1)
                    } else if workspace.isSearching {
                        ProgressView()
                            .scaleEffect(0.55)
                            .frame(width: 12, height: 12)
                        Text(L10n("search.searching"))
                            .font(.system(size: 10.5))
                            .foregroundColor(Color(nsColor: ZedTheme.mutedText))
                    } else if !workspace.searchQuery.isEmpty {
                        Text(L10n("search.matchesInFilesFormat", workspace.searchResults.count, groupedResults.count))
                            .font(.system(size: 10.5))
                            .foregroundColor(Color(nsColor: ZedTheme.mutedText))
                    } else {
                        Text(L10n("search.hint"))
                            .font(.system(size: 10.5))
                            .foregroundColor(Color(nsColor: ZedTheme.mutedText))
                    }
                    Spacer()
                }
            }
            .padding(10)

            Divider()
                .overlay(Color(nsColor: ZedTheme.border))

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(groupedResults) { group in
                        let isCollapsed = collapsedFilePaths.contains(group.id)
                        fileGroupHeader(group: group, isCollapsed: isCollapsed)

                        if !isCollapsed {
                            ForEach(group.matches) { match in
                                SearchMatchRow(match: match) {
                                    workspace.openFile(url: match.url, atLine: match.lineNumber)
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .onAppear {
            requestFocus()
        }
        .onChange(of: workspace.searchFocusNonce) { _, _ in
            requestFocus()
        }
    }

    private func fileGroupHeader(group: FileSearchGroup, isCollapsed: Bool) -> some View {
        let lang = CodeLanguage.detect(from: group.url)
        return HStack(spacing: 5) {
            Button {
                if isCollapsed {
                    collapsedFilePaths.remove(group.id)
                } else {
                    collapsedFilePaths.insert(group.id)
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundColor(Color(nsColor: ZedTheme.mutedText))
                        .frame(width: 10)

                    Image(systemName: lang.iconName)
                        .font(.system(size: 10.5))
                        .foregroundColor(Color(nsColor: lang.iconColor))

                    Text(group.relativePath)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Color(nsColor: ZedTheme.primaryText))
                        .lineLimit(1)
                        .truncationMode(.head)

                    Spacer(minLength: 4)

                    Text("\(group.matches.count)")
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .foregroundColor(Color(nsColor: ZedTheme.secondaryText))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color(nsColor: ZedTheme.hoverBackground)))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if workspace.isGlobalReplaceExpanded {
                Button {
                    _ = workspace.replaceInWorkspaceFiles(urls: [group.url])
                } label: {
                    Image(systemName: "arrow.2.squarepath")
                        .font(.system(size: 9.5))
                        .foregroundColor(Color(nsColor: ZedTheme.function))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help(L10n("search.replaceFileHelp"))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(nsColor: ZedTheme.tabBarBackground).opacity(0.65))
    }

    private func optionPill(_ label: String, active: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(Color(nsColor: active ? ZedTheme.pillText : ZedTheme.secondaryText))
                .padding(.horizontal, 6)
                .padding(.vertical, 2.5)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(nsColor: active ? ZedTheme.pillBackground : ZedTheme.background))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color(nsColor: active ? ZedTheme.cursor.withAlphaComponent(0.7) : ZedTheme.border), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func filterField(placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(Color(nsColor: ZedTheme.primaryText))
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Color(nsColor: ZedTheme.background))
            .cornerRadius(5)
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Color(nsColor: ZedTheme.border), lineWidth: 1)
            )
            .onSubmit {
                workspace.performGlobalSearch(debounceMs: 0)
            }
            .onChange(of: text.wrappedValue) { _, _ in
                workspace.performGlobalSearch(debounceMs: 220)
            }
    }

    private func requestFocus() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
            isSearchFocused = true
        }
    }
}

private struct SearchMatchRow: View {
    let match: SearchMatch
    let onTap: () -> Void
    @ObservedObject private var themeManager = ThemeManager.shared
    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Text("\(match.lineNumber)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Color(nsColor: ZedTheme.number))
                    .frame(minWidth: 28, alignment: .trailing)

                Text(match.linePreview)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundColor(Color(nsColor: ZedTheme.secondaryText))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)
            }
            .padding(.leading, 18)
            .padding(.trailing, 10)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHovered ? Color(nsColor: ZedTheme.hoverBackground) : Color.clear)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
