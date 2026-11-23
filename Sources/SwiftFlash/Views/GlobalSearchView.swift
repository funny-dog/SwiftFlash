import SwiftUI

struct GlobalSearchView: View {
    @ObservedObject var workspace: WorkspaceState
    @ObservedObject private var themeManager = ThemeManager.shared
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundColor(Color(nsColor: ZedTheme.mutedText))

                    TextField(L10n("search.placeholder"), text: $workspace.searchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundColor(Color(nsColor: ZedTheme.primaryText))
                        .focused($isSearchFocused)
                        .onSubmit {
                            workspace.performGlobalSearch(query: workspace.searchQuery)
                        }
                        .onChange(of: workspace.searchQuery) { _, newValue in
                            workspace.performGlobalSearch(query: newValue)
                        }

                    if !workspace.searchQuery.isEmpty {
                        Button {
                            workspace.searchQuery = ""
                            workspace.searchResults = []
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundColor(Color(nsColor: ZedTheme.mutedText))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color(nsColor: ZedTheme.background))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: ZedTheme.border), lineWidth: 1)
                )

                HStack {
                    if workspace.isSearching {
                        ProgressView()
                            .scaleEffect(0.55)
                            .frame(width: 12, height: 12)
                        Text(L10n("search.searching"))
                            .font(.system(size: 10.5))
                            .foregroundColor(Color(nsColor: ZedTheme.mutedText))
                    } else if !workspace.searchQuery.isEmpty {
                        Text(L10n("search.matchesFormat", workspace.searchResults.count))
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
                    ForEach(workspace.searchResults) { match in
                        SearchMatchRow(match: match) {
                            workspace.openFile(url: match.url, atLine: match.lineNumber)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                isSearchFocused = true
            }
        }
    }
}

private struct SearchMatchRow: View {
    let match: SearchMatch
    let onTap: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(match.relativePath)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Color(nsColor: ZedTheme.function))
                        .lineLimit(1)
                        .truncationMode(.head)

                    Spacer()

                    Text(":\(match.lineNumber)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(Color(nsColor: ZedTheme.number))
                }

                Text(match.linePreview)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundColor(Color(nsColor: ZedTheme.secondaryText))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHovered ? Color(nsColor: ZedTheme.hoverBackground) : Color.clear)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
