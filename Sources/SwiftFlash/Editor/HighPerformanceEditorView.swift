import AppKit
import CodeEditTextView
import Combine
import CoreText
import SwiftUI

// MARK: - FlashTextView (Enhanced CodeEditTextView)

final class FlashTextView: TextView {
    var currentLanguage: CodeLanguage = .swift

    private let autoPairs: [Character: Character] = [
        "(": ")",
        "[": "]",
        "{": "}",
        "\"": "\"",
        "'": "'"
    ]
    private let closingPairs: Set<Character> = [")", "]", "}", "\"", "'"]

    func handleSmartTab() {
        guard isEditable else { return }
        let selections = selectionManager.textSelections.map(\.range)
        if selections.count == 1, let range = selections.first, range.length > 0 {
            indentLines(in: range, unindent: false)
        } else {
            replaceCharacters(in: selections, with: "    ")
        }
    }

    func handleSmartBacktab() {
        guard isEditable else { return }
        guard let range = selectionManager.textSelections.first?.range else { return }
        indentLines(in: range, unindent: true)
    }

    func handleSmartNewline() -> Bool {
        guard isEditable,
              let sel = selectionManager.textSelections.first?.range else {
            return false
        }

        let nsString = textStorage.string as NSString
        let lineRange = nsString.lineRange(for: NSRange(location: sel.location, length: 0))
        let linePrefixRange = NSRange(location: lineRange.location, length: max(0, sel.location - lineRange.location))
        let lineBeforeCursor = nsString.substring(with: linePrefixRange)

        // Extract leading indentation spaces/tabs
        var indent = ""
        for ch in lineBeforeCursor {
            if ch == " " || ch == "\t" {
                indent.append(ch)
            } else {
                break
            }
        }

        let trimmedBefore = lineBeforeCursor.trimmingCharacters(in: .whitespaces)
        let shouldIncreaseIndent = trimmedBefore.hasSuffix("{")
            || trimmedBefore.hasSuffix("(")
            || trimmedBefore.hasSuffix("[")
            || (trimmedBefore.hasSuffix(":") && currentLanguage == .python)

        let nextChar: String? = sel.location < nsString.length
            ? nsString.substring(with: NSRange(location: sel.location, length: 1))
            : nil
        let prevChar: String? = sel.location > 0
            ? nsString.substring(with: NSRange(location: sel.location - 1, length: 1))
            : nil

        let isBetweenBrackets = (prevChar == "{" && nextChar == "}")
            || (prevChar == "[" && nextChar == "]")
            || (prevChar == "(" && nextChar == ")")

        if isBetweenBrackets {
            let innerIndent = indent + "    "
            let insertion = "\n\(innerIndent)\n\(indent)"
            replaceCharacters(in: sel, with: insertion, skipUpdateSelection: true)
            let newCursor = sel.location + 1 + innerIndent.count
            selectionManager.setSelectedRange(NSRange(location: newCursor, length: 0))
            scrollSelectionToVisible()
            return true
        }

        let newIndent = shouldIncreaseIndent ? (indent + "    ") : indent
        replaceCharacters(in: sel, with: "\n" + newIndent)
        return true
    }

    func handleAutoPairEvent(_ event: NSEvent) -> Bool {
        guard isEditable,
              !hasMarkedText(),
              !event.modifierFlags.contains(.command),
              !event.modifierFlags.contains(.control),
              let chars = event.characters,
              chars.count == 1,
              let ch = chars.first,
              selectionManager.textSelections.count == 1,
              let sel = selectionManager.textSelections.first?.range else {
            return false
        }

        let nsString = textStorage.string as NSString

        // Overtype existing closing bracket/quote
        if sel.length == 0,
           closingPairs.contains(ch),
           sel.location < nsString.length {
            let nextStr = nsString.substring(with: NSRange(location: sel.location, length: 1))
            if nextStr == String(ch) {
                selectionManager.setSelectedRange(NSRange(location: sel.location + 1, length: 0))
                return true
            }
        }

        // Auto-close brackets and quotes
        if let closing = autoPairs[ch] {
            if sel.length > 0 {
                let selectedText = nsString.substring(with: sel)
                let wrapped = "\(ch)\(selectedText)\(closing)"
                replaceCharacters(in: sel, with: wrapped, skipUpdateSelection: true)
                selectionManager.setSelectedRange(NSRange(location: sel.location + 1, length: sel.length))
                return true
            } else {
                let shouldAutoClose: Bool
                if ch == "\"" || ch == "'" {
                    if sel.location > 0 {
                        let prev = nsString.substring(with: NSRange(location: sel.location - 1, length: 1))
                        shouldAutoClose = prev.rangeOfCharacter(from: .alphanumerics) == nil
                    } else {
                        shouldAutoClose = true
                    }
                } else {
                    shouldAutoClose = true
                }

                if shouldAutoClose {
                    replaceCharacters(in: sel, with: "\(ch)\(closing)", skipUpdateSelection: true)
                    selectionManager.setSelectedRange(NSRange(location: sel.location + 1, length: 0))
                    return true
                }
            }
        }

        return false
    }

    override func deleteBackward(_ sender: Any?) {
        if !hasMarkedText(),
           selectionManager.textSelections.count == 1,
           let sel = selectionManager.textSelections.first?.range,
           sel.length == 0,
           sel.location > 0,
           sel.location < textStorage.length {
            let nsString = textStorage.string as NSString
            let prev = nsString.substring(with: NSRange(location: sel.location - 1, length: 1))
            let next = nsString.substring(with: NSRange(location: sel.location, length: 1))
            if let prevCh = prev.first, let expected = autoPairs[prevCh], String(expected) == next {
                replaceCharacters(in: NSRange(location: sel.location - 1, length: 2), with: "")
                return
            }
        }
        super.deleteBackward(sender)
    }

    func indentLines(in range: NSRange, unindent: Bool) {
        let nsString = textStorage.string as NSString
        let fullLinesRange = nsString.lineRange(for: range)
        let block = nsString.substring(with: fullLinesRange)
        let lines = block.components(separatedBy: "\n")

        var newLines: [String] = []
        for (idx, line) in lines.enumerated() {
            // Preserve trailing empty element produced by trailing newline
            if idx == lines.count - 1 && line.isEmpty && block.hasSuffix("\n") {
                newLines.append("")
                continue
            }
            if unindent {
                if line.hasPrefix("    ") {
                    newLines.append(String(line.dropFirst(4)))
                } else if line.hasPrefix("\t") {
                    newLines.append(String(line.dropFirst(1)))
                } else {
                    let leadingSpaces = line.prefix(while: { $0 == " " }).count
                    newLines.append(String(line.dropFirst(min(leadingSpaces, 4))))
                }
            } else {
                newLines.append("    " + line)
            }
        }

        let replacement = newLines.joined(separator: "\n")
        replaceCharacters(in: fullLinesRange, with: replacement, skipUpdateSelection: true)
        let updatedRange = NSRange(location: fullLinesRange.location, length: (replacement as NSString).length)
        selectionManager.setSelectedRange(updatedRange)
    }

    func toggleComment() {
        guard isEditable else { return }
        let prefix = currentLanguage.lineCommentPrefix ?? "//"
        let nsString = textStorage.string as NSString
        let sel = selectionManager.textSelections.first?.range ?? NSRange(location: 0, length: 0)
        let linesRange = nsString.lineRange(for: sel)
        let block = nsString.substring(with: linesRange)
        let lines = block.components(separatedBy: "\n")

        let nonEmptyLines = lines.enumerated().filter { idx, line in
            !(idx == lines.count - 1 && line.isEmpty && block.hasSuffix("\n")) &&
            !line.trimmingCharacters(in: .whitespaces).isEmpty
        }

        let allCommented = !nonEmptyLines.isEmpty && nonEmptyLines.allSatisfy { _, line in
            line.trimmingCharacters(in: .whitespaces).hasPrefix(prefix)
        }

        var updated: [String] = []
        for (idx, line) in lines.enumerated() {
            if idx == lines.count - 1 && line.isEmpty && block.hasSuffix("\n") {
                updated.append("")
                continue
            }
            if allCommented {
                if let range = line.range(of: prefix + " ") {
                    var mutable = line
                    mutable.removeSubrange(range)
                    updated.append(mutable)
                } else if let range = line.range(of: prefix) {
                    var mutable = line
                    mutable.removeSubrange(range)
                    updated.append(mutable)
                } else {
                    updated.append(line)
                }
            } else {
                if line.trimmingCharacters(in: .whitespaces).isEmpty {
                    updated.append(line)
                } else {
                    let indent = String(line.prefix(while: { $0 == " " || $0 == "\t" }))
                    let rest = line.dropFirst(indent.count)
                    updated.append("\(indent)\(prefix) \(rest)")
                }
            }
        }

        let replacement = updated.joined(separator: "\n")
        replaceCharacters(in: linesRange, with: replacement, skipUpdateSelection: true)
        let cursorOffset = min(linesRange.location + (replacement as NSString).length, textStorage.length)
        selectionManager.setSelectedRange(NSRange(location: cursorOffset, length: 0))
    }
}

// MARK: - CoreText Line Number Gutter View

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

            // Draw using CoreText directly
            if let context {
                context.saveGState()
                // Un-flip locally for CoreText glyph drawing
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

// MARK: - Container View (Gutter + ScrollView + FlashTextView + Incremental Async Highlighter)

@MainActor
final class HighPerformanceEditorContainerView: NSView, TextViewDelegate {
    let gutterView = EditorGutterView()
    let scrollView = NSScrollView()
    let textView: FlashTextView

    weak var workspace: WorkspaceState?

    private var currentTabID: UUID?
    private var currentReloadRevision: Int = 0
    private var isProgrammaticUpdate = false
    private var highlightRevision: Int = 0
    private var highlightTask: Task<Void, Never>?
    private var completionTask: Task<Void, Never>?
    private var completionRevision: Int = 0
    private var pendingCompletionInsertedString: String?
    private var observers: [NSObjectProtocol] = []
    private var themeCancellables: Set<AnyCancellable> = []
    private var keyMonitor: Any?

    let completionState = CompletionState()
    private var completionHostingView: NSHostingView<CompletionPopupView>?

    private var editorFont: NSFont {
        ThemeManager.shared.editorFont
    }

    init(workspace: WorkspaceState) {
        self.workspace = workspace
        let initialFont = ThemeManager.shared.editorFont
        let initialLineHeight = ThemeManager.shared.lineHeightMultiplier
        self.textView = FlashTextView(
            string: "",
            font: initialFont,
            textColor: ZedTheme.plainText,
            lineHeightMultiplier: initialLineHeight,
            wrapLines: false,
            isEditable: true,
            isSelectable: true,
            letterSpacing: 1.0,
            useSystemCursor: false,
            delegate: nil
        )
        super.init(frame: .zero)
        self.textView.delegate = self
        self.gutterView.updateFontSize(ThemeManager.shared.editorFontSize)
        setupUI()
        setupObservers()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        highlightTask?.cancel()
        completionTask?.cancel()
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        for obs in observers {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    private func setupUI() {
        wantsLayer = true
        clipsToBounds = true
        layer?.backgroundColor = ZedTheme.background.cgColor

        textView.edgeInsets = HorizontalEdgeInsets(left: 12, right: 24)
        textView.overscrollAmount = 0.35
        textView.selectionManager.insertionPointColor = ZedTheme.cursor
        textView.selectionManager.selectionBackgroundColor = ZedTheme.selectionBackground
        textView.selectionManager.selectedLineBackgroundColor = ZedTheme.activeLineBackground
        textView.selectionManager.highlightSelectedLine = true

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = ZedTheme.background
        scrollView.contentInsets = NSEdgeInsets(top: 8, left: 0, bottom: 20, right: 0)
        scrollView.documentView = textView

        gutterView.translatesAutoresizingMaskIntoConstraints = false
        gutterView.textView = textView
        gutterView.scrollView = scrollView

        addSubview(gutterView)
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            gutterView.leadingAnchor.constraint(equalTo: leadingAnchor),
            gutterView.topAnchor.constraint(equalTo: topAnchor),
            gutterView.bottomAnchor.constraint(equalTo: bottomAnchor),
            gutterView.widthAnchor.constraint(equalToConstant: 58),

            scrollView.leadingAnchor.constraint(equalTo: gutterView.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        let popup = CompletionPopupView(state: completionState) { [weak self] item in
            self?.acceptCompletion(item)
        }
        let hosting = NSHostingView(rootView: popup)
        hosting.wantsLayer = true
        hosting.layer?.zPosition = 500
        hosting.sizingOptions = []
        hosting.isHidden = true
        addSubview(hosting, positioned: .above, relativeTo: scrollView)
        self.completionHostingView = hosting
    }

    private func setupObservers() {
        scrollView.contentView.postsBoundsChangedNotifications = true

        let textDidChangeObs = NotificationCenter.default.addObserver(
            forName: TextView.textDidChangeNotification,
            object: textView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let inserted = self.pendingCompletionInsertedString {
                    self.pendingCompletionInsertedString = nil
                    self.textView.layoutManager.layoutLines()
                    self.handleTypingForCompletion(insertedString: inserted)
                }
            }
        }
        observers.append(textDidChangeObs)

        let scrollObs = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.gutterView.needsDisplay = true
                self.workspace?.updateActiveTabScroll(y: self.scrollView.documentVisibleRect.origin.y)
                self.scheduleViewportHighlight(debounceMs: 12)
                if self.workspace?.findState.isFindBarVisible == true {
                    self.updateFindEmphases()
                }
                if self.completionState.isVisible {
                    self.completionState.dismiss()
                    self.completionHostingView?.isHidden = true
                }
            }
        }
        observers.append(scrollObs)

        let selObs = NotificationCenter.default.addObserver(
            forName: TextSelectionManager.selectionChangedNotification,
            object: textView.selectionManager,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateCursorStatus()
            }
        }
        observers.append(selObs)

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] event in
            guard let self,
                  self.workspace?.activeOverlay == OverlayPanelMode.none,
                  let window = self.window,
                  event.window === window else {
                return event
            }

            if event.type == .leftMouseDown {
                if let hosting = self.completionHostingView, !hosting.isHidden {
                    let ptInContainer = self.convert(event.locationInWindow, from: nil)
                    if !hosting.frame.contains(ptInContainer) {
                        self.dismissCompletion()
                    }
                }
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                if flags.contains(.command), event.clickCount == 1 {
                    let pt = self.textView.convert(event.locationInWindow, from: nil)
                    if self.textView.bounds.contains(pt),
                       let offset = self.textView.layoutManager.textOffsetAtPoint(pt) {
                        DispatchQueue.main.async { [weak self] in
                            self?.goToDefinition(atOffset: offset)
                        }
                    }
                }
                return event
            }

            guard window.firstResponder === self.textView,
                  !self.textView.hasMarkedText() else {
                return event
            }

            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            // Completion popup navigation & acceptance
            if self.completionState.isVisible {
                switch Int(event.keyCode) {
                case 126: // Up
                    self.completionState.moveUp()
                    return nil
                case 125: // Down
                    self.completionState.moveDown()
                    return nil
                case 53: // ESC
                    self.dismissCompletion()
                    return nil
                case 123, 124, 115, 119, 116, 121: // Left, Right, Home, End, PageUp, PageDown
                    self.dismissCompletion()
                case 48, 36: // Tab or Return
                    if modifiers.isDisjoint(with: [.command, .control, .option]) {
                        if let item = self.completionState.selectedItem {
                            self.acceptCompletion(item)
                            return nil
                        }
                    }
                default:
                    break
                }
            }

            // Manual Completion Trigger: Ctrl+Space (49) or Option+ESC (53)
            if (Int(event.keyCode) == 49 && modifiers == [.control])
                || (Int(event.keyCode) == 53 && modifiers == [.option]) {
                self.triggerCompletion(forceShow: true)
                return nil
            }

            // F12 (111): Go to Definition
            if Int(event.keyCode) == 111 && modifiers.isEmpty {
                let offset = self.textView.selectionManager.textSelections.first?.range.location ?? 0
                self.goToDefinition(atOffset: offset)
                return nil
            }

            // Tab (48) & Shift+Tab
            if Int(event.keyCode) == 48 && !modifiers.contains(.command) && !modifiers.contains(.control) && !modifiers.contains(.option) {
                if modifiers.contains(.shift) {
                    self.textView.handleSmartBacktab()
                } else {
                    self.textView.handleSmartTab()
                }
                return nil
            }
            // Return / Enter (36)
            if Int(event.keyCode) == 36 && modifiers.isDisjoint(with: [.command, .control, .option, .shift]) {
                if self.textView.handleSmartNewline() {
                    return nil
                }
            }
            // Auto-pairs
            if self.textView.handleAutoPairEvent(event) {
                return nil
            }
            return event
        }

        let tm = ThemeManager.shared
        tm.$currentThemeID.dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyThemeAndFont() }
            .store(in: &themeCancellables)

        tm.$editorFontFamily.dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyThemeAndFont() }
            .store(in: &themeCancellables)

        tm.$editorFontSize.dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyThemeAndFont() }
            .store(in: &themeCancellables)

        tm.$lineHeightMultiplier.dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyThemeAndFont() }
            .store(in: &themeCancellables)
    }

    func applyThemeAndFont() {
        let newFont = ThemeManager.shared.editorFont
        let newLineHeight = ThemeManager.shared.lineHeightMultiplier

        layer?.backgroundColor = ZedTheme.background.cgColor
        scrollView.backgroundColor = ZedTheme.background

        textView.typingAttributes = [
            .font: newFont,
            .foregroundColor: ZedTheme.plainText
        ]
        textView.font = newFont
        textView.textColor = ZedTheme.plainText
        textView.lineHeight = newLineHeight

        textView.selectionManager.insertionPointColor = ZedTheme.cursor
        textView.selectionManager.selectionBackgroundColor = ZedTheme.selectionBackground
        textView.selectionManager.selectedLineBackgroundColor = ZedTheme.activeLineBackground

        if let storage = textView.textStorage, storage.length > 0 {
            let fullRange = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.addAttribute(.font, value: newFont, range: fullRange)
            storage.addAttribute(.foregroundColor, value: ZedTheme.plainText, range: fullRange)
            storage.endEditing()
        }

        textView.layoutManager.renderDelegate = textView.layoutManager.renderDelegate
        textView.layoutManager.setNeedsLayout()
        textView.updateFrameIfNeeded()
        textView.layoutManager.layoutLines()
        textView.needsLayout = true
        textView.needsDisplay = true

        gutterView.updateFontSize(ThemeManager.shared.editorFontSize)
        gutterView.needsDisplay = true
        scheduleViewportHighlight(debounceMs: 0)
    }

    func syncWithTab(_ tab: EditorTab?) {
        guard let tab else {
            currentTabID = nil
            currentReloadRevision = 0
            return
        }

        let tabChanged = (currentTabID != tab.id) || (currentReloadRevision != tab.externalReloadRevision)
        if tabChanged {
            currentTabID = tab.id
            currentReloadRevision = tab.externalReloadRevision
            isProgrammaticUpdate = true
            textView.currentLanguage = tab.language
            textView.typingAttributes = [
                .font: editorFont,
                .foregroundColor: ZedTheme.plainText
            ]
            textView.setText(tab.content)
            textView.updateFrameIfNeeded()

            // Restore selection or jump to requested line
            if let jumpLine = tab.pendingJumpLine {
                jumpToLine(jumpLine)
                if let idx = workspace?.openTabs.firstIndex(where: { $0.id == tab.id }) {
                    workspace?.openTabs[idx].pendingJumpLine = nil
                }
            } else {
                let safeLoc = min(tab.selectedRange.location, textView.textStorage.length)
                let safeLen = min(tab.selectedRange.length, max(0, textView.textStorage.length - safeLoc))
                textView.selectionManager.setSelectedRange(NSRange(location: safeLoc, length: safeLen))
                let targetY = tab.scrollOffsetY ?? -scrollView.contentInsets.top
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: targetY))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }

            isProgrammaticUpdate = false
            dismissCompletion()
            refreshDiagnosticsOverlay()
            applyOverlayAttributes()
            gutterView.needsDisplay = true
            updateCursorStatus()
            scheduleViewportHighlight(debounceMs: 0)
            focusEditor()
        } else if let pendingLine = tab.pendingJumpLine {
            jumpToLine(pendingLine)
            if let idx = workspace?.openTabs.firstIndex(where: { $0.id == tab.id }) {
                workspace?.openTabs[idx].pendingJumpLine = nil
            }
            focusEditor()
        }
    }

    func focusEditor() {
        window?.makeFirstResponder(textView)
    }

    func jumpToLine(_ lineNumber: Int) {
        let zeroBased = max(0, lineNumber - 1)
        if let linePos = textView.layoutManager.textLineForIndex(zeroBased) {
            let targetRange = NSRange(location: linePos.range.location, length: 0)
            textView.selectionManager.setSelectedRange(targetRange)
            textView.scrollToRange(targetRange, center: true)
            gutterView.activeLineIndex = zeroBased
            gutterView.needsDisplay = true
        }
    }

    func highlightAndScroll(to range: NSRange) {
        guard let storage = textView.textStorage else { return }
        let safeLoc = min(range.location, storage.length)
        let safeLen = min(range.length, max(0, storage.length - safeLoc))
        let clamped = NSRange(location: safeLoc, length: safeLen)
        textView.selectionManager.setSelectedRange(clamped)
        textView.scrollToRange(clamped, center: true)
        applyOverlayAttributes()
    }

    func replaceRange(_ range: NSRange, with replacement: String) {
        guard let storage = textView.textStorage, range.max <= storage.length else { return }
        textView.replaceCharacters(in: range, with: replacement)
    }

    func replaceEntireDocument(with newText: String) {
        guard let storage = textView.textStorage else { return }
        textView.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: newText)
    }

    // MARK: - TextViewDelegate

    nonisolated func textView(_ textView: TextView, didReplaceContentsIn range: NSRange, with string: String) {
        MainActor.assumeIsolated {
            guard !isProgrammaticUpdate else { return }
            workspace?.updateActiveTabContent(textView.string)
            gutterView.needsDisplay = true
            scheduleViewportHighlight(debounceMs: 18)
            pendingCompletionInsertedString = string
        }
    }

    // MARK: - Cursor Position (O(log N) via B-Tree LineStorage)

    private func updateCursorStatus() {
        let sel = textView.selectionManager.textSelections.first?.range ?? NSRange(location: 0, length: 0)
        let offset = min(sel.location, textView.textStorage.length)
        if let linePos = textView.layoutManager.textLineForOffset(offset) {
            let lineNum = linePos.index + 1
            let colNum = max(1, offset - linePos.range.location + 1)
            gutterView.activeLineIndex = linePos.index
            workspace?.updateActiveTabCursor(line: lineNum, column: colNum, range: sel)
        } else {
            gutterView.activeLineIndex = 0
            workspace?.updateActiveTabCursor(line: 1, column: 1, range: sel)
        }
    }

    // MARK: - Async Incremental Viewport Syntax Highlighting

    private func scheduleViewportHighlight(debounceMs: UInt64) {
        highlightTask?.cancel()
        highlightRevision &+= 1
        let revision = highlightRevision
        let language = textView.currentLanguage
        let totalLength = textView.textStorage.length
        guard totalLength > 0 else { return }

        // Compute visible range + generous buffer so scrolling stays seamless
        let visibleRange = textView.visibleTextRange ?? NSRange(location: 0, length: min(totalLength, 6000))
        let buffer = 3500
        let start = max(0, visibleRange.location - buffer)
        let end = min(totalLength, visibleRange.max + buffer)
        let targetRange = NSRange(location: start, length: max(0, end - start))
        guard targetRange.length > 0 else { return }

        let nsString = textView.textStorage.string as NSString
        let slice = nsString.substring(with: targetRange)
        let palette = ZedTheme.palette

        highlightTask = Task { [weak self] in
            if debounceMs > 0 {
                try? await Task.sleep(nanoseconds: debounceMs * 1_000_000)
            }
            if Task.isCancelled { return }

            let clockStart = DispatchTime.now().uptimeNanoseconds
            let tokens = await Task.detached(priority: .userInitiated) {
                SyntaxHighlighter.shared.tokenize(
                    slice: slice,
                    baseOffset: start,
                    language: language,
                    palette: palette
                )
            }.value
            let tokenizeMs = Double(DispatchTime.now().uptimeNanoseconds - clockStart) / 1_000_000.0

            await MainActor.run {
                guard let self, self.highlightRevision == revision else { return }
                guard !self.textView.hasMarkedText() else { return }
                let storage = self.textView.textStorage!
                let safeLength = storage.length
                let applyStart = min(targetRange.location, safeLength)
                let applyLength = min(targetRange.length, max(0, safeLength - applyStart))
                guard applyLength > 0 else { return }

                let applyRange = NSRange(location: applyStart, length: applyLength)
                storage.beginEditing()
                storage.addAttribute(.foregroundColor, value: NSColor(hex: palette.plainTextHex), range: applyRange)
                for token in tokens {
                    if token.range.location >= applyStart && token.range.max <= applyStart + applyLength {
                        storage.addAttribute(.foregroundColor, value: NSColor(hex: token.colorHex), range: token.range)
                    }
                }
                storage.endEditing()

                self.workspace?.lastRenderLatencyMs = tokenizeMs
            }
        }
    }

    // MARK: - Find Highlights & LSP Diagnostics Overlay

    func applyOverlayAttributes() {
        updateFindEmphases()
        updateDiagnosticEmphases()
    }

    func refreshDiagnosticsOverlay() {
        var map: [Int: LSPDiagnosticSeverity] = [:]
        for diag in workspace?.diagnosticsForActiveTab ?? [] {
            let line = diag.range.start.line
            if let existing = map[line] {
                if diag.severity.rawValue < existing.rawValue {
                    map[line] = diag.severity
                }
            } else {
                map[line] = diag.severity
            }
        }
        gutterView.lineSeverities = map
        gutterView.needsDisplay = true
        updateDiagnosticEmphases()
    }

    private func updateFindEmphases() {
        guard let emphasisManager = textView.emphasisManager else { return }
        guard let findState = workspace?.findState, findState.isFindBarVisible, !findState.matches.isEmpty else {
            emphasisManager.removeEmphases(for: "find-matches")
            return
        }

        textView.layoutManager.layoutLines()
        let matches = findState.matches
        let activeIdx = findState.currentMatchIndex
        let visibleRange = textView.visibleTextRange ?? NSRange(location: 0, length: textView.textStorage.length)

        var emphases: [Emphasis] = []
        emphases.reserveCapacity(min(matches.count, 250))

        for (idx, range) in matches.enumerated() {
            let isActive = (idx == activeIdx)
            if isActive || NSIntersectionRange(range, visibleRange).length > 0 || matches.count <= 200 {
                emphases.append(
                    Emphasis(
                        range: range,
                        style: .standard,
                        flash: false,
                        inactive: !isActive,
                        selectInDocument: false
                    )
                )
            }
            if emphases.count >= 250 { break }
        }

        emphasisManager.replaceEmphases(emphases, for: "find-matches")
        emphasisManager.updateLayerBackgrounds()
    }

    private func updateDiagnosticEmphases() {
        guard let emphasisManager = textView.emphasisManager else { return }
        let diags = workspace?.diagnosticsForActiveTab ?? []
        guard !diags.isEmpty else {
            emphasisManager.removeEmphases(for: "lsp-diagnostics")
            return
        }

        textView.layoutManager.layoutLines()
        var emphases: [Emphasis] = []
        for diag in diags.prefix(200) {
            guard let range = nsRange(for: diag.range), range.length > 0 else { continue }
            emphases.append(
                Emphasis(
                    range: range,
                    style: .underline(color: NSColor(hex: diag.severity.colorHex)),
                    flash: false,
                    inactive: false,
                    selectInDocument: false
                )
            )
        }
        emphasisManager.replaceEmphases(emphases, for: "lsp-diagnostics")
        emphasisManager.updateLayerBackgrounds()
    }

    private func nsRange(for lspRange: LSPRange) -> NSRange? {
        guard let storage = textView.textStorage else { return nil }
        guard let startLine = textView.layoutManager.textLineForIndex(lspRange.start.line) else { return nil }
        let startOffset = min(startLine.range.max, startLine.range.location + max(0, lspRange.start.character))

        let endOffset: Int
        if let endLine = textView.layoutManager.textLineForIndex(lspRange.end.line) {
            endOffset = min(endLine.range.max, endLine.range.location + max(0, lspRange.end.character))
        } else {
            endOffset = min(storage.length, startOffset + 1)
        }

        let safeStart = max(0, min(startOffset, storage.length))
        let safeEnd = max(safeStart, min(endOffset, storage.length))
        if safeEnd == safeStart && safeStart < storage.length {
            return NSRange(location: safeStart, length: 1)
        }
        return NSRange(location: safeStart, length: safeEnd - safeStart)
    }

    private func lspPosition(for offset: Int) -> LSPPosition? {
        guard let storage = textView.textStorage else { return nil }
        return Self.computeLSPPosition(in: storage.string as NSString, at: offset)
    }

    static func computeLSPPosition(in nsString: NSString, at offset: Int) -> LSPPosition {
        let clamped = max(0, min(offset, nsString.length))
        var line = 0
        var lineStart = 0
        var i = 0
        while i < clamped {
            if nsString.character(at: i) == 0x000A {
                line += 1
                lineStart = i + 1
            }
            i += 1
        }
        return LSPPosition(line: line, character: clamped - lineStart)
    }

    // MARK: - Code Completion & Go to Definition

    private func handleTypingForCompletion(insertedString: String) {
        if insertedString.isEmpty {
            if completionState.isVisible {
                triggerCompletion(forceShow: false)
            }
            return
        }

        if insertedString == "." {
            triggerCompletion(forceShow: false)
            return
        }
        if insertedString == ":" {
            triggerCompletion(forceShow: true)
            return
        }
        if insertedString == " ",
           textView.currentLanguage == .python,
           let storage = textView.textStorage {
            let nsText = storage.string as NSString
            let cursor = textView.selectionManager.textSelections.first?.range.location ?? 0
            let lineRange = nsText.lineRange(for: NSRange(location: min(cursor, nsText.length), length: 0))
            let before = nsText.substring(with: NSRange(location: lineRange.location, length: max(0, cursor - lineRange.location)))
            let ctx = LocalCompletionProvider.detectPythonLineContext(beforeCursorOnLine: before)
            if ctx != .general {
                triggerCompletion(forceShow: true)
                return
            }
        }

        let isAllWordChars = !insertedString.isEmpty && insertedString.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "_"
        }
        if isAllWordChars {
            triggerCompletion(forceShow: false)
        } else {
            dismissCompletion()
        }
    }

    func triggerCompletion(forceShow: Bool) {
        completionTask?.cancel()
        completionRevision &+= 1
        let rev = completionRevision

        guard let storage = textView.textStorage else { return }
        let nsText = storage.string as NSString
        let cursor = min(textView.selectionManager.textSelections.first?.range.location ?? 0, nsText.length)
        let prefixRange = LocalCompletionProvider.identifierPrefixRange(in: nsText, at: cursor)
        let prefix = nsText.substring(with: prefixRange)
        let lineRange = nsText.lineRange(for: NSRange(location: cursor, length: 0))
        let beforeCursorOnLine = nsText.substring(
            with: NSRange(location: lineRange.location, length: max(0, cursor - lineRange.location))
        )
        let prevChar: String? = prefixRange.location > 0
            ? nsText.substring(with: NSRange(location: prefixRange.location - 1, length: 1))
            : nil

        let firstPrefixScalar = prefix.unicodeScalars.first
        let startsWithWordChar = firstPrefixScalar.map { CharacterSet.letters.contains($0) || $0 == "_" } ?? false
        if !forceShow && !(startsWithWordChar && prefix.count >= 1) && prevChar != "." {
            dismissCompletion()
            return
        }

        let language = textView.currentLanguage
        let content = storage.string

        // Show local suggestions immediately for instant responsiveness
        let localItems = LocalCompletionProvider.mergeAndRank(
            prefix: prefix,
            language: language,
            documentText: content,
            lspItems: [],
            beforeCursorOnLine: beforeCursorOnLine
        )
        if !localItems.isEmpty {
            showCompletionPopup(items: localItems, prefixRange: prefixRange, cursorOffset: cursor)
        } else {
            dismissCompletion()
        }

        // Also query active LSP in background if document has a file URL
        guard let workspace,
              let fileURL = workspace.activeTab?.url else {
            return
        }
        let pos = Self.computeLSPPosition(in: nsText, at: cursor)
        let root = workspace.rootURL
        completionTask = Task { [weak self] in
            let lspItems = await LSPManager.shared.requestCompletions(
                url: fileURL,
                language: language,
                content: content,
                line: pos.line,
                character: pos.character,
                workspaceRoot: root
            ) ?? []

            await MainActor.run {
                guard let self, self.completionRevision == rev else { return }
                let currentCursor = self.textView.selectionManager.textSelections.first?.range.location ?? 0
                guard currentCursor == cursor else { return }
                guard !lspItems.isEmpty else { return }
                let merged = LocalCompletionProvider.mergeAndRank(
                    prefix: prefix,
                    language: language,
                    documentText: content,
                    lspItems: lspItems,
                    beforeCursorOnLine: beforeCursorOnLine
                )
                if !merged.isEmpty {
                    self.showCompletionPopup(items: merged, prefixRange: prefixRange, cursorOffset: cursor)
                }
            }
        }
    }

    private func showCompletionPopup(items: [LSPCompletionItem], prefixRange: NSRange, cursorOffset: Int) {
        guard !items.isEmpty, let hosting = completionHostingView else {
            dismissCompletion()
            return
        }
        textView.layoutManager.layoutLines()
        completionState.show(items: items, prefixRange: prefixRange)

        let anchorOffset = prefixRange.length > 0 ? prefixRange.location : cursorOffset
        let caretRect: NSRect
        if let directRect = textView.layoutManager.rectForOffset(anchorOffset) {
            caretRect = directRect
        } else if anchorOffset > 0, let prevRect = textView.layoutManager.rectForOffset(anchorOffset - 1) {
            caretRect = NSRect(x: prevRect.maxX, y: prevRect.minY, width: 2, height: max(18, prevRect.height))
        } else if let linePos = textView.layoutManager.textLineForOffset(anchorOffset) {
            caretRect = NSRect(x: textView.edgeInsets.left, y: linePos.yPos, width: 2, height: max(18, linePos.height))
        } else {
            caretRect = NSRect(x: textView.edgeInsets.left, y: scrollView.documentVisibleRect.origin.y + 8, width: 2, height: 18)
        }

        let bottomPoint = textView.convert(NSPoint(x: caretRect.minX, y: caretRect.maxY), to: self)
        let topPoint = textView.convert(NSPoint(x: caretRect.minX, y: caretRect.minY), to: self)

        let popupWidth: CGFloat = 340
        let popupHeight = min(230, CGFloat(max(1, items.count)) * 27 + 10)
        let x = max(8, min(bottomPoint.x, max(8, bounds.width - popupWidth - 8)))

        // Container uses standard macOS bottom-left coordinates (isFlipped == false)
        var y = bottomPoint.y - popupHeight - 4
        if y < 8 {
            y = topPoint.y + 4
        }
        y = max(8, min(y, max(8, bounds.height - popupHeight - 8)))

        hosting.frame = NSRect(x: x, y: y, width: popupWidth, height: popupHeight)
        hosting.isHidden = false
        hosting.invalidateIntrinsicContentSize()
        hosting.needsLayout = true
        hosting.layoutSubtreeIfNeeded()
    }

    func dismissCompletion() {
        completionTask?.cancel()
        completionState.dismiss()
        completionHostingView?.isHidden = true
    }

    private func acceptCompletion(_ item: LSPCompletionItem) {
        let range = completionState.prefixRange
        dismissCompletion()
        guard let storage = textView.textStorage, range.max <= storage.length else { return }
        isProgrammaticUpdate = true
        textView.replaceCharacters(in: range, with: item.insertText)
        let newLoc = min(storage.length, range.location + (item.insertText as NSString).length)
        textView.selectionManager.setSelectedRange(NSRange(location: newLoc, length: 0))
        isProgrammaticUpdate = false
        workspace?.updateActiveTabContent(textView.string)
        gutterView.needsDisplay = true
        scheduleViewportHighlight(debounceMs: 0)
        focusEditor()
    }

    func goToDefinition(atOffset offset: Int) {
        guard let workspace,
              let tab = workspace.activeTab,
              let fileURL = tab.url,
              let pos = lspPosition(for: offset) else {
            return
        }
        let content = tab.content
        let language = tab.language
        let root = workspace.rootURL

        Task { [weak workspace] in
            let locations = await LSPManager.shared.requestDefinition(
                url: fileURL,
                language: language,
                content: content,
                line: pos.line,
                character: pos.character,
                workspaceRoot: root
            )
            await MainActor.run {
                guard let workspace else { return }
                guard let first = locations.first, let targetURL = URL(string: first.uri) else {
                    workspace.statusMessage = L10n("lsp.definition.notFound")
                    return
                }
                workspace.openFile(url: targetURL.standardized, atLine: first.range.start.line + 1)
            }
        }
    }
}

// MARK: - SwiftUI Bridge

struct HighPerformanceEditorRepresentable: NSViewRepresentable {
    @ObservedObject var workspace: WorkspaceState
    let activeTab: EditorTab?

    func makeNSView(context: Context) -> HighPerformanceEditorContainerView {
        let view = HighPerformanceEditorContainerView(workspace: workspace)
        bindCallbacks(to: view)
        view.syncWithTab(activeTab)
        return view
    }

    func updateNSView(_ nsView: HighPerformanceEditorContainerView, context: Context) {
        bindCallbacks(to: nsView)
        nsView.syncWithTab(activeTab)
    }

    private func bindCallbacks(to view: HighPerformanceEditorContainerView) {
        workspace.onToggleCommentRequested = { [weak view] in
            view?.textView.toggleComment()
        }
        workspace.onJumpToLineRequested = { [weak view] line in
            view?.jumpToLine(line)
        }
        workspace.onFocusEditorRequested = { [weak view] in
            view?.focusEditor()
        }
        workspace.onRequestCompletionAction = { [weak view] in
            view?.triggerCompletion(forceShow: true)
        }
        workspace.onGoToDefinitionAction = { [weak view] in
            guard let view else { return }
            let offset = view.textView.selectionManager.textSelections.first?.range.location ?? 0
            view.goToDefinition(atOffset: offset)
        }
        workspace.onFindMatchesChanged = { [weak view] in
            view?.applyOverlayAttributes()
        }
        workspace.onHighlightRangeRequested = { [weak view] range in
            view?.highlightAndScroll(to: range)
        }
        workspace.onReplaceTextInActiveEditor = { [weak view] range, replacement in
            view?.replaceRange(range, with: replacement)
        }
        workspace.onReplaceAllTextInActiveEditor = { [weak view] newText in
            view?.replaceEntireDocument(with: newText)
        }
        workspace.onDiagnosticsUpdated = { [weak view] in
            view?.refreshDiagnosticsOverlay()
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: HighPerformanceEditorContainerView,
        context: Context
    ) -> CGSize? {
        CGSize(
            width: proposal.width ?? 400,
            height: proposal.height ?? 300
        )
    }
}
