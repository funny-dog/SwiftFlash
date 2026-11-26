import AppKit
import CoreText

// MARK: - CoreText Line Number Gutter View

@MainActor
final class EditorGutterView: NSView {
    weak var textView: FlashTextView?
    weak var scrollView: NSScrollView?
    var lineSeverities: [Int: LSPDiagnosticSeverity] = [:]
    var activeLineIndex: Int = 0 {
        didSet {
            if oldValue != activeLineIndex {
                needsDisplay = true
            }
        }
    }

    private var gutterFont = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
    private var activeGutterFont = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)

    func updateFontSize(_ editorSize: CGFloat) {
        let size = max(10, editorSize - 1.5)
        gutterFont = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)
        activeGutterFont = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold)
        needsDisplay = true
    }

    /// Computes dynamic gutter width so large files (10,000+ lines) or large fonts
    /// never clip line numbers or collide with diagnostic severity dots.
    func requiredWidth(forLineCount lineCount: Int) -> CGFloat {
        let digits = max(3, String(max(1, lineCount)).count)
        let sample = String(repeating: "8", count: digits)
        let attrs: [NSAttributedString.Key: Any] = [.font: activeGutterFont]
        let textWidth = ceil((sample as NSString).size(withAttributes: attrs).width)
        // Left dot area (14pt) + digits + right padding (14pt)
        return max(54, textWidth + 28)
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        ZedTheme.gutterBackground.setFill()
        dirtyRect.fill()

        // Right 1px divider
        ZedTheme.border.setFill()
        NSRect(x: bounds.width - 1, y: dirtyRect.minY, width: 1, height: dirtyRect.height).fill()

        guard let textView, let scrollView, let layoutManager = textView.layoutManager else { return }
        let context = NSGraphicsContext.current?.cgContext
        context?.saveGState()

        let scrollY = scrollView.documentVisibleRect.origin.y
        let topInset = scrollView.contentInsets.top

        // Iterate only visible lines from CodeEditTextView's B-Tree LineStorage (O(log N + visible))
        for linePos in layoutManager.visibleLines() {
            let yInGutter = linePos.yPos - scrollY + topInset
            if yInGutter + linePos.height < 0 || yInGutter > bounds.height {
                continue
            }

            let isCurrent = (linePos.index == activeLineIndex)
            if isCurrent {
                ZedTheme.activeLineBackground.setFill()
                NSRect(x: 0, y: yInGutter, width: bounds.width - 1, height: linePos.height).fill()
            }

            if let sev = lineSeverities[linePos.index] {
                NSColor(hex: sev.colorHex).setFill()
                let dotRect = NSRect(x: 5, y: yInGutter + (linePos.height - 5) / 2.0, width: 5, height: 5)
                NSBezierPath(ovalIn: dotRect).fill()
            }

            let label = "\(linePos.index + 1)"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: isCurrent ? activeGutterFont : gutterFont,
                .foregroundColor: isCurrent ? ZedTheme.gutterActiveText : ZedTheme.gutterText
            ]
            let attrStr = NSAttributedString(string: label, attributes: attrs)
            let ctLine = CTLineCreateWithAttributedString(attrStr)
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            let textWidth = CGFloat(CTLineGetTypographicBounds(ctLine, &ascent, &descent, &leading))

            if let context {
                context.saveGState()
                let baselineY = yInGutter + (linePos.height + ascent - descent) / 2.0
                context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
                context.textPosition = CGPoint(x: bounds.width - 14 - textWidth, y: baselineY)
                CTLineDraw(ctLine, context)
                context.restoreGState()
            }
        }

        context?.restoreGState()
    }
}
