import AppKit
import SwiftUI

struct QuickOpenModalView: View {
    @ObservedObject var workspace: WorkspaceState
    @ObservedObject private var themeManager = ThemeManager.shared
    @State private var query: String = ""
    @State private var selectedIndex: Int = 0
    @State private var eventMonitor: Any?
    @FocusState private var isInputFocused: Bool

    private var filteredFiles: [(url: URL, relativePath: String, score: Int)] {
        let rootPath = workspace.rootURL.path
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        let mapped: [(url: URL, relativePath: String, score: Int)] = workspace.allWorkspaceFiles.compactMap { url in
            let rel = url.path.hasPrefix(rootPath + "/")
                ? String(url.path.dropFirst(rootPath.count + 1))
                : url.lastPathComponent

            if trimmed.isEmpty {
                return (url, rel, 1)
            }
            if let score = Self.fuzzyScore(query: trimmed, candidate: rel) {
                return (url, rel, score)
            }
            return nil
        }

        if trimmed.isEmpty {
            return Array(mapped.prefix(40))
        }
        return Array(mapped.sorted { $0.score > $1.score }.prefix(40))
    }

    var body: some View {
        ZStack {
            Color.black.opacity(ZedTheme.isDark ? 0.42 : 0.22)
                .ignoresSafeArea()
                .onTapGesture {
                    dismiss()
                }

            VStack(spacing: 0) {
                // Search Input
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(Color(nsColor: ZedTheme.function))

                    TextField(L10n("quickOpen.placeholder"), text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .foregroundColor(Color(nsColor: ZedTheme.primaryText))
                        .focused($isInputFocused)
                        .onSubmit {
                            openSelected()
                        }
                        .onChange(of: query) { _, _ in
                            selectedIndex = 0
                        }

                    Text("ESC")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(Color(nsColor: ZedTheme.mutedText))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(nsColor: ZedTheme.background))
                        .cornerRadius(4)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

                Divider()
                    .overlay(Color(nsColor: ZedTheme.border))

                // Results List
                let items = filteredFiles
                if items.isEmpty {
                    VStack(spacing: 6) {
                        Text(L10n("quickOpen.empty"))
                            .font(.system(size: 12.5))
                            .foregroundColor(Color(nsColor: ZedTheme.mutedText))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 2) {
                                ForEach(Array(items.enumerated()), id: \.element.url) { idx, item in
                                    let lang = CodeLanguage.detect(from: item.url)
                                    let isSelected = idx == selectedIndex
                                    Button {
                                        workspace.openFile(url: item.url)
                                        dismiss()
                                    } label: {
                                        HStack(spacing: 10) {
                                            Image(systemName: lang.iconName)
                                                .font(.system(size: 12))
                                                .foregroundColor(Color(nsColor: lang.iconColor))
                                                .frame(width: 16)

                                            VStack(alignment: .leading, spacing: 1) {
                                                Text(item.url.lastPathComponent)
                                                    .font(.system(size: 13, weight: .medium))
                                                    .foregroundColor(Color(nsColor: ZedTheme.primaryText))
                                                Text(item.relativePath)
                                                    .font(.system(size: 11))
                                                    .foregroundColor(Color(nsColor: ZedTheme.mutedText))
                                                    .lineLimit(1)
                                                    .truncationMode(.middle)
                                            }

                                            Spacer()

                                            if isSelected {
                                                Text("↵")
                                                    .font(.system(size: 11, design: .monospaced))
                                                    .foregroundColor(Color(nsColor: ZedTheme.secondaryText))
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
                        .frame(maxHeight: 340)
                        .onChange(of: selectedIndex) { _, newIdx in
                            proxy.scrollTo(newIdx, anchor: .center)
                        }
                    }
                }
            }
            .frame(width: 580)
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                isInputFocused = true
            }
            installKeyMonitor()
        }
        .onDisappear {
            removeKeyMonitor()
        }
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch Int(event.keyCode) {
            case 53: // Escape
                dismiss()
                return nil
            case 125: // Down Arrow
                let count = filteredFiles.count
                if count > 0 {
                    selectedIndex = min(selectedIndex + 1, count - 1)
                }
                return nil
            case 126: // Up Arrow
                if !filteredFiles.isEmpty {
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

    private func openSelected() {
        let items = filteredFiles
        guard !items.isEmpty else { return }
        let idx = min(max(0, selectedIndex), items.count - 1)
        workspace.openFile(url: items[idx].url)
        dismiss()
    }

    private func dismiss() {
        workspace.dismissOverlay()
    }

    private static func fuzzyScore(query: String, candidate: String) -> Int? {
        let qChars = Array(query.lowercased())
        let cChars = Array(candidate.lowercased())
        let origChars = Array(candidate)
        let fileName = (candidate as NSString).lastPathComponent.lowercased()

        var qi = 0
        var score = 0
        var consecutive = 0

        for ci in 0..<cChars.count {
            if qi < qChars.count && cChars[ci] == qChars[qi] {
                consecutive += 1
                score += 10 + consecutive * 6
                // Bonus for start of path segment or camelCase hump
                if ci == 0 || cChars[ci - 1] == "/" || cChars[ci - 1] == "_" || cChars[ci - 1] == "-" || origChars[ci].isUppercase {
                    score += 15
                }
                qi += 1
            } else {
                consecutive = 0
            }
        }

        guard qi == qChars.count else { return nil }
        if fileName.contains(query.lowercased()) {
            score += 40
        }
        // Slightly prefer shorter paths on tie
        score -= candidate.count / 6
        return score
    }
}
