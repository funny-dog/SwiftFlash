import AppKit
import SwiftUI

struct SymbolOutlineModalView: View {
    @ObservedObject var workspace: WorkspaceState
    @ObservedObject private var themeManager = ThemeManager.shared
    @State private var query: String = ""
    @State private var selectedIndex: Int = 0
    @State private var countBox = SwitcherCountBox()
    @State private var eventMonitor: Any?
    @FocusState private var isInputFocused: Bool

    private var filteredSymbols: [LSPDocumentSymbol] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return workspace.activeDocumentSymbols
        }
        return workspace.activeDocumentSymbols.filter { sym in
            switcherFuzzyMatches(query: trimmed, candidate: sym.name)
                || (sym.containerName.map { switcherFuzzyMatches(query: trimmed, candidate: $0) } ?? false)
        }
    }

    var body: some View {
        let items = filteredSymbols
        ZStack {
            Color.black.opacity(ZedTheme.isDark ? 0.42 : 0.22)
                .ignoresSafeArea()
                .onTapGesture {
                    workspace.dismissOverlay()
                }

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "list.bullet.indent")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(Color(nsColor: ZedTheme.function))

                    TextField(L10n("symbols.searchPlaceholder"), text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .foregroundColor(Color(nsColor: ZedTheme.primaryText))
                        .focused($isInputFocused)
                        .onSubmit {
                            jumpToSelected(items: items)
                        }

                    Text("⌘⇧O")
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
                    Text(L10n("symbols.empty"))
                        .font(.system(size: 12.5))
                        .foregroundColor(Color(nsColor: ZedTheme.mutedText))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 28)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 2) {
                                ForEach(Array(items.enumerated()), id: \.element.id) { idx, sym in
                                    let isSelected = idx == selectedIndex
                                    Button {
                                        jump(to: sym)
                                    } label: {
                                        HStack(spacing: 8) {
                                            if sym.depth > 0 {
                                                Spacer()
                                                    .frame(width: CGFloat(min(sym.depth, 4)) * 12)
                                            }

                                            Image(systemName: sym.kind.iconName)
                                                .font(.system(size: 11, weight: .semibold))
                                                .foregroundColor(Color(nsColor: NSColor(hex: sym.kind.badgeColorHex)))
                                                .frame(width: 18, height: 18)
                                                .background(
                                                    RoundedRectangle(cornerRadius: 4)
                                                        .fill(Color(nsColor: NSColor(hex: sym.kind.badgeColorHex)).opacity(0.14))
                                                )

                                            Text(sym.name)
                                                .font(.system(size: 13, weight: isSelected ? .semibold : .regular, design: .monospaced))
                                                .foregroundColor(Color(nsColor: ZedTheme.primaryText))
                                                .lineLimit(1)

                                            if let container = sym.containerName, !container.isEmpty {
                                                Text(container)
                                                    .font(.system(size: 11))
                                                    .foregroundColor(Color(nsColor: ZedTheme.mutedText))
                                                    .lineLimit(1)
                                            } else if let detail = sym.detail, !detail.isEmpty {
                                                Text(detail)
                                                    .font(.system(size: 11))
                                                    .foregroundColor(Color(nsColor: ZedTheme.mutedText))
                                                    .lineLimit(1)
                                            }

                                            Spacer()

                                            Text(":\(sym.selectionRange.start.line + 1)")
                                                .font(.system(size: 11, design: .monospaced))
                                                .foregroundColor(Color(nsColor: ZedTheme.number))
                                        }
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
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
                        .frame(maxHeight: 360)
                        .onChange(of: selectedIndex) { _, newIdx in
                            proxy.scrollTo(newIdx, anchor: .center)
                        }
                    }
                }
            }
            .frame(width: 560)
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
            countBox.count = filteredSymbols.count
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                isInputFocused = true
            }
            installKeyMonitor()
        }
        .onChange(of: query) { _, _ in
            selectedIndex = 0
            countBox.count = filteredSymbols.count
        }
        .onChange(of: workspace.activeDocumentSymbols) { _, _ in
            countBox.count = filteredSymbols.count
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

    private func jumpToSelected(items: [LSPDocumentSymbol]) {
        guard !items.isEmpty else { return }
        let idx = min(max(0, selectedIndex), items.count - 1)
        jump(to: items[idx])
    }

    private func jump(to symbol: LSPDocumentSymbol) {
        workspace.recordCurrentNavigationLocation()
        workspace.dismissOverlay()
        workspace.onJumpToLocationRequested?(
            symbol.selectionRange.start.line + 1,
            symbol.selectionRange.start.character + 1
        )
    }
}
