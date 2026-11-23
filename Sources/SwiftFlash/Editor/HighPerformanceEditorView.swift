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
    private var observers: [NSObjectProtocol] = []
    private var themeCancellables: Set<AnyCancellable> = []
    private var keyMonitor: Any?

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
    }

    private func setupObservers() {
        scrollView.contentView.postsBoundsChangedNotifications = true

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

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  self.workspace?.activeOverlay == OverlayPanelMode.none,
                  let window = self.window,
                  window.firstResponder === self.textView,
                  !self.textView.hasMarkedText() else {
                return event
            }

            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
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
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: tab.scrollOffsetY))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }

            isProgrammaticUpdate = false
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

    // MARK: - TextViewDelegate

    nonisolated func textView(_ textView: TextView, didReplaceContentsIn range: NSRange, with string: String) {
        MainActor.assumeIsolated {
            guard !isProgrammaticUpdate else { return }
            workspace?.updateActiveTabContent(textView.string)
            gutterView.needsDisplay = true
            scheduleViewportHighlight(debounceMs: 18)
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
}

// MARK: - SwiftUI Bridge

struct HighPerformanceEditorRepresentable: NSViewRepresentable {
    @ObservedObject var workspace: WorkspaceState
    let activeTab: EditorTab?

    func makeNSView(context: Context) -> HighPerformanceEditorContainerView {
        let view = HighPerformanceEditorContainerView(workspace: workspace)
        workspace.onToggleCommentRequested = { [weak view] in
            view?.textView.toggleComment()
        }
        workspace.onJumpToLineRequested = { [weak view] line in
            view?.jumpToLine(line)
        }
        workspace.onFocusEditorRequested = { [weak view] in
            view?.focusEditor()
        }
        view.syncWithTab(activeTab)
        return view
    }

    func updateNSView(_ nsView: HighPerformanceEditorContainerView, context: Context) {
        workspace.onToggleCommentRequested = { [weak nsView] in
            nsView?.textView.toggleComment()
        }
        workspace.onJumpToLineRequested = { [weak nsView] line in
            nsView?.jumpToLine(line)
        }
        workspace.onFocusEditorRequested = { [weak nsView] in
            nsView?.focusEditor()
        }
        nsView.syncWithTab(activeTab)
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
