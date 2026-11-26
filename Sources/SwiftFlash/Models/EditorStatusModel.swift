import Foundation

/// High-frequency editor status model observed only by `StatusBarView` so cursor movement,
/// render latency telemetry, and status bar updates never trigger redraws across the sidebar,
/// tab bar, or editor bridge.
@MainActor
final class EditorStatusModel: ObservableObject {
    @Published var cursorLine: Int = 1
    @Published var cursorColumn: Int = 1
    @Published var lastRenderLatencyMs: Double = 0.0
    @Published var statusMessage: String = L10n("status.ready")
}
