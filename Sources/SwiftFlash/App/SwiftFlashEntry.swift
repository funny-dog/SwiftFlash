import AppKit
import Darwin

@main
@MainActor
struct SwiftFlashEntry {
    private static var appDelegate: AppDelegate?

    static func main() {
        // Prevent SIGPIPE from terminating the app if an LSP/subprocess pipe closes mid-write.
        Darwin.signal(SIGPIPE, SIG_IGN)
        let app = NSApplication.shared
        let delegate = AppDelegate()
        appDelegate = delegate
        app.delegate = delegate
        app.run()
    }
}
