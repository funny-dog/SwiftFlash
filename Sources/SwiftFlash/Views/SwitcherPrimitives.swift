import AppKit
import SwiftUI

// MARK: - Shared Switcher Primitives

/// Mutable reference box so NSEvent local monitors always read the latest filtered item count
/// instead of a stale value captured when `.onAppear` ran.
@MainActor
final class SwitcherCountBox {
    var count: Int = 0
}

@MainActor
enum SwitcherKeyboardSupport {
    static func hasActiveMarkedText() -> Bool {
        if let inputClient = NSApp.keyWindow?.firstResponder as? NSTextInputClient {
            return inputClient.hasMarkedText()
        }
        return false
    }
}

struct SwitcherKeyboardHandler: ViewModifier {
    let itemCount: Int
    @Binding var selectedIndex: Int
    @Binding var keyboardScrollNonce: Int
    let onDismiss: () -> Void

    @State private var countBox = SwitcherCountBox()
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear {
                countBox.count = itemCount
                installMonitor()
            }
            .onChange(of: itemCount) { _, newCount in
                countBox.count = newCount
                if newCount == 0 {
                    selectedIndex = 0
                } else if selectedIndex >= newCount {
                    selectedIndex = newCount - 1
                }
            }
            .onDisappear {
                removeMonitor()
            }
    }

    private func installMonitor() {
        removeMonitor()
        let box = countBox
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.window === NSApp.keyWindow,
                  !SwitcherKeyboardSupport.hasActiveMarkedText() else {
                return event
            }
            switch Int(event.keyCode) {
            case 53: // Escape
                onDismiss()
                return nil
            case 125: // Down Arrow
                let count = box.count
                if count > 0 {
                    selectedIndex = min(selectedIndex + 1, count - 1)
                    keyboardScrollNonce &+= 1
                }
                return nil
            case 126: // Up Arrow
                if box.count > 0 {
                    selectedIndex = max(selectedIndex - 1, 0)
                    keyboardScrollNonce &+= 1
                }
                return nil
            default:
                return event
            }
        }
    }

    private func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}

struct SwitcherSearchInput: View {
    let placeholder: String
    @Binding var query: String
    @FocusState private var isFocused: Bool
    let onSubmit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            TextField(placeholder, text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .foregroundColor(Color(nsColor: ZedTheme.primaryText))
                .focused($isFocused)
                .onSubmit(onSubmit)

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(Color(nsColor: ZedTheme.mutedText))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                isFocused = true
            }
        }
    }
}

struct SwitcherSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundColor(Color(nsColor: ZedTheme.mutedText))
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

func switcherFuzzyMatches(query: String, candidate: String) -> Bool {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return true }
    let q = Array(trimmed.lowercased())
    let c = Array(candidate.lowercased())
    var qi = 0
    for ch in c {
        if qi < q.count && ch == q[qi] {
            qi += 1
        }
    }
    return qi == q.count
}

func switcherAbbreviatedPath(_ url: URL) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let path = url.path
    if path.hasPrefix(home) {
        return "~" + path.dropFirst(home.count)
    }
    return path
}
