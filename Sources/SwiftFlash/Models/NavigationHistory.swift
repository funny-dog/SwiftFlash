import Foundation

// MARK: - Navigation Location & History Stack (Back / Forward)

struct NavigationLocation: Equatable, Hashable, Sendable {
    let url: URL
    let line: Int     // 1-based
    let column: Int   // 1-based

    var normalizedPath: String {
        url.standardized.path
    }

    func isNear(_ other: NavigationLocation, lineThreshold: Int = 3) -> Bool {
        normalizedPath == other.normalizedPath && abs(line - other.line) <= lineThreshold
    }
}

@MainActor
final class NavigationHistory: ObservableObject {
    @Published private(set) var canGoBack: Bool = false
    @Published private(set) var canGoForward: Bool = false

    private var backStack: [NavigationLocation] = []
    private var forwardStack: [NavigationLocation] = []
    private let maxCapacity: Int

    init(maxCapacity: Int = 100) {
        self.maxCapacity = max(10, maxCapacity)
    }

    /// Records the departure location before jumping elsewhere.
    func record(_ location: NavigationLocation) {
        if let last = backStack.last, last.isNear(location, lineThreshold: 2) {
            backStack[backStack.count - 1] = location
        } else {
            backStack.append(location)
            if backStack.count > maxCapacity {
                backStack.removeFirst(backStack.count - maxCapacity)
            }
        }
        forwardStack.removeAll()
        syncFlags()
    }

    /// Pops the previous location and pushes `current` onto the forward stack.
    func goBack(from current: NavigationLocation?) -> NavigationLocation? {
        while let target = backStack.popLast() {
            if let current, target.isNear(current, lineThreshold: 0) {
                continue
            }
            if let current {
                if forwardStack.last != current {
                    forwardStack.append(current)
                }
            }
            syncFlags()
            return target
        }
        syncFlags()
        return nil
    }

    /// Pops the next location and pushes `current` onto the back stack.
    func goForward(from current: NavigationLocation?) -> NavigationLocation? {
        while let target = forwardStack.popLast() {
            if let current, target.isNear(current, lineThreshold: 0) {
                continue
            }
            if let current {
                if backStack.last != current {
                    backStack.append(current)
                    if backStack.count > maxCapacity {
                        backStack.removeFirst(backStack.count - maxCapacity)
                    }
                }
            }
            syncFlags()
            return target
        }
        syncFlags()
        return nil
    }

    func clear() {
        backStack.removeAll()
        forwardStack.removeAll()
        syncFlags()
    }

    private func syncFlags() {
        canGoBack = !backStack.isEmpty
        canGoForward = !forwardStack.isEmpty
    }
}
