import AppKit
import SwiftUI

struct QuickOpenModalView: View {
    private struct MatchEntry: Identifiable {
        var id: URL { url }
        let url: URL
        let relativePath: String
        let score: Int
    }

    @ObservedObject var workspace: WorkspaceState
    @ObservedObject private var themeManager = ThemeManager.shared
    @State private var query: String = ""
    @State private var selectedIndex: Int = 0
    @State private var cachedResults: [MatchEntry] = []
    @State private var countBox = SwitcherCountBox()
    @State private var eventMonitor: Any?
    @FocusState private var isInputFocused: Bool

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
                            recomputeFilteredFiles()
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
                if cachedResults.isEmpty {
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
                                ForEach(Array(cachedResults.enumerated()), id: \.offset) { idx, item in
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
            recomputeFilteredFiles()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                isInputFocused = true
            }
            installKeyMonitor()
        }
        .onChange(of: workspace.allWorkspaceFiles) { _, _ in
            recomputeFilteredFiles()
        }
        .onDisappear {
            removeKeyMonitor()
        }
    }

    private func recomputeFilteredFiles() {
        let rootPath = workspace.rootURL.path
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        let computed: [MatchEntry]
        if trimmed.isEmpty {
            computed = workspace.allWorkspaceFiles.prefix(40).map { url in
                let rel = url.path.hasPrefix(rootPath + "/")
                    ? String(url.path.dropFirst(rootPath.count + 1))
                    : url.lastPathComponent
                return MatchEntry(url: url, relativePath: rel, score: 1)
            }
        } else {
            let mapped: [MatchEntry] = workspace.allWorkspaceFiles.compactMap { url in
                let rel = url.path.hasPrefix(rootPath + "/")
                    ? String(url.path.dropFirst(rootPath.count + 1))
                    : url.lastPathComponent
                guard let score = Self.fuzzyScore(query: trimmed, candidate: rel) else { return nil }
                return MatchEntry(url: url, relativePath: rel, score: score)
            }
            computed = Array(mapped.sorted { $0.score > $1.score }.prefix(40))
        }

        cachedResults = computed
        countBox.count = computed.count
        selectedIndex = 0
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        let box = countBox
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Respect IME composition and ignore events targeting other windows.
            guard event.window === NSApp.keyWindow,
                  !SwitcherKeyboardSupport.hasActiveMarkedText() else {
                return event
            }
            switch Int(event.keyCode) {
            case 53: // Escape
                dismiss()
                return nil
            case 125: // Down Arrow
                let count = box.count
                if count > 0 {
                    selectedIndex = min(selectedIndex + 1, count - 1)
                }
                return nil
            case 126: // Up Arrow
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

    private func openSelected() {
        guard !cachedResults.isEmpty else { return }
        let idx = min(max(0, selectedIndex), cachedResults.count - 1)
        workspace.openFile(url: cachedResults[idx].url)
        dismiss()
    }

    private func dismiss() {
        workspace.dismissOverlay()
    }

    /// Unicode-safe fuzzy file matcher operating strictly on original character indices
    /// (never mixes indices from `candidate` and `candidate.lowercased()`).
    nonisolated static func fuzzyScore(query: String, candidate: String) -> Int? {
        let qLower = query.lowercased()
        let qChars = Array(qLower)
        guard !qChars.isEmpty else { return 1 }

        let origChars = Array(candidate)
        let fileName = (candidate as NSString).lastPathComponent.lowercased()

        var qi = 0
        var score = 0
        var consecutive = 0

        for ci in 0..<origChars.count {
            let origChar = origChars[ci]
            let loweredSegment = origChar.lowercased()
            var matched = false
            if qi < qChars.count {
                // Handle both 1-to-1 and rare 1-to-N Unicode lowercase expansions safely.
                let segChars = Array(loweredSegment)
                if segChars.count == 1 {
                    if segChars[0] == qChars[qi] {
                        matched = true
                        qi += 1
                    }
                } else if qi + segChars.count <= qChars.count
                            && Array(qChars[qi..<(qi + segChars.count)]) == segChars {
                    matched = true
                    qi += segChars.count
                }
            }

            if matched {
                consecutive += 1
                score += 10 + consecutive * 6
                let isBoundary = ci == 0
                    || origChars[ci - 1] == "/"
                    || origChars[ci - 1] == "_"
                    || origChars[ci - 1] == "-"
                    || origChar.isUppercase
                if isBoundary {
                    score += 15
                }
            } else {
                consecutive = 0
            }
        }

        guard qi == qChars.count else { return nil }
        if fileName.contains(qLower) {
            score += 40
        }
        score -= candidate.count / 6
        return score
    }
}
