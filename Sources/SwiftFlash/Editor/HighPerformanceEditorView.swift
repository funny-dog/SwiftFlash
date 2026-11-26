import AppKit
@preconcurrency import CodeEditTextView
import Combine
import SwiftUI

private final class EditorResourceBag: @unchecked Sendable {
    private let lock = NSLock()
    private var observers: [NSObjectProtocol] = []
    private var keyMonitor: Any?

    func addObserver(_ token: NSObjectProtocol) {
        lock.lock()
        observers.append(token)
        lock.unlock()
    }

    func setKeyMonitor(_ monitor: Any?) {
        lock.lock()
        let previous = keyMonitor
        keyMonitor = monitor
        lock.unlock()
        if let previous {
            NSEvent.removeMonitor(previous)
        }
    }

    func teardown() {
        if Thread.isMainThread {
            teardownOnMain()
        } else {
            DispatchQueue.main.async { [self] in
                teardownOnMain()
            }
        }
    }

    private func teardownOnMain() {
        lock.lock()
        let currentObservers = observers
        let currentMonitor = keyMonitor
        observers.removeAll()
        keyMonitor = nil
        lock.unlock()

        if let currentMonitor {
            NSEvent.removeMonitor(currentMonitor)
        }
        for obs in currentObservers {
            NotificationCenter.default.removeObserver(obs)
        }
    }
}

// MARK: - LSP Hover Popup State & View

@MainActor
final class HoverPopupState: ObservableObject {
    @Published var isVisible: Bool = false
    @Published var markdownText: String = ""

    func show(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            dismiss()
            return
        }
        markdownText = trimmed
        isVisible = true
    }

    func dismiss() {
        isVisible = false
        markdownText = ""
    }
}

struct HoverPopupView: View {
    @ObservedObject var state: HoverPopupState
    @ObservedObject private var themeManager = ThemeManager.shared

    var body: some View {
        ScrollView {
            Text(renderedHoverText)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundColor(Color(nsColor: ZedTheme.primaryText))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .frame(maxWidth: 460, maxHeight: 220)
        .background(Color(nsColor: ZedTheme.sidebarBackground))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: ZedTheme.border), lineWidth: 1)
        )
        .shadow(color: .black.opacity(ZedTheme.isDark ? 0.48 : 0.2), radius: 14, y: 6)
    }

    private var renderedHoverText: String {
        // Strip markdown fenced code markers cleanly so hover reads crisply in monospace.
        state.markdownText
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Container View (Gutter + ScrollView + FlashTextView + Incremental Async Highlighter)

@MainActor
final class HighPerformanceEditorContainerView: NSView, TextViewDelegate {
    let pane: EditorPane
    let gutterView = EditorGutterView()
    let scrollView = NSScrollView()
    let textView: FlashTextView

    weak var workspace: WorkspaceState?

    private var currentTabID: UUID?
    private var currentTabURL: URL?
    private var currentReloadRevision: Int = 0
    private var currentLanguage: CodeLanguage = .swift
    private var isProgrammaticUpdate = false
    private var highlightRevision: Int = 0
    private var needsHighlightAfterIME = false
    private var highlightTask: Task<Void, Never>?
    private var completionTask: Task<Void, Never>?
    private var hoverTask: Task<Void, Never>?
    private var completionRevision: Int = 0
    private var hoverRevision: Int = 0
    private var lastHoverOffset: Int = -1
    private var hoverTrackingArea: NSTrackingArea?
    private var pendingCompletionInsertedString: String?
    private var gutterWidthConstraint: NSLayoutConstraint?
    private let resourceBag = EditorResourceBag()
    private var themeCancellables: Set<AnyCancellable> = []

    let completionState = CompletionState()
    private var completionHostingView: NSHostingView<CompletionPopupView>?

    let hoverState = HoverPopupState()
    private var hoverHostingView: NSHostingView<HoverPopupView>?

    private var editorFont: NSFont {
        ThemeManager.shared.editorFont
    }

    init(workspace: WorkspaceState, pane: EditorPane = .primary) {
        self.workspace = workspace
        self.pane = pane
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
        hoverTask?.cancel()
        resourceBag.teardown()
    }

    func teardown() {
        highlightTask?.cancel()
        completionTask?.cancel()
        hoverTask?.cancel()
        resourceBag.teardown()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = hoverTrackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard workspace?.activeOverlay == OverlayPanelMode.none,
              !completionState.isVisible else {
            return
        }
        let ptInContainer = convert(event.locationInWindow, from: nil)
        if let hoverView = hoverHostingView, !hoverView.isHidden, hoverView.frame.contains(ptInContainer) {
            return
        }
        let pt = textView.convert(event.locationInWindow, from: nil)
        guard textView.bounds.contains(pt),
              let offset = textView.layoutManager.textOffsetAtPoint(pt) else {
            dismissHover()
            return
        }
        if abs(offset - lastHoverOffset) <= 1 && hoverState.isVisible {
            return
        }
        scheduleHover(atOffset: offset)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        dismissHover()
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

        let widthConstraint = gutterView.widthAnchor.constraint(equalToConstant: 58)
        self.gutterWidthConstraint = widthConstraint

        NSLayoutConstraint.activate([
            gutterView.leadingAnchor.constraint(equalTo: leadingAnchor),
            gutterView.topAnchor.constraint(equalTo: topAnchor),
            gutterView.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthConstraint,

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

        let hoverHosting = NSHostingView(rootView: HoverPopupView(state: hoverState))
        hoverHosting.wantsLayer = true
        hoverHosting.layer?.zPosition = 490
        hoverHosting.sizingOptions = []
        hoverHosting.isHidden = true
        addSubview(hoverHosting, positioned: .above, relativeTo: scrollView)
        self.hoverHostingView = hoverHosting
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
                self.updateGutterWidthIfNeeded()
                if self.needsHighlightAfterIME && !self.textView.hasMarkedText() {
                    self.needsHighlightAfterIME = false
                    self.scheduleViewportHighlight(debounceMs: 12)
                }
                if let inserted = self.pendingCompletionInsertedString {
                    self.pendingCompletionInsertedString = nil
                    self.textView.layoutManager.layoutLines()
                    self.handleTypingForCompletion(insertedString: inserted)
                }
            }
        }
        resourceBag.addObserver(textDidChangeObs)

        let scrollObs = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.gutterView.needsDisplay = true
                // Stored in non-@Published tab view state so scrolling causes zero SwiftUI redraws.
                if let tabID = self.currentTabID {
                    self.workspace?.updateTabScroll(tabID: tabID, y: self.scrollView.documentVisibleRect.origin.y)
                }
                self.scheduleViewportHighlight(debounceMs: 12)
                if self.workspace?.findState.isFindBarVisible == true {
                    self.updateFindEmphases()
                }
                if self.completionState.isVisible {
                    self.completionState.dismiss()
                    self.completionHostingView?.isHidden = true
                }
                if self.hoverState.isVisible {
                    self.dismissHover()
                }
            }
        }
        resourceBag.addObserver(scrollObs)

        let selObs = NotificationCenter.default.addObserver(
            forName: TextSelectionManager.selectionChangedNotification,
            object: textView.selectionManager,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.updateCursorStatus()
                if self.needsHighlightAfterIME && !self.textView.hasMarkedText() {
                    self.needsHighlightAfterIME = false
                    self.scheduleViewportHighlight(debounceMs: 12)
                }
            }
        }
        resourceBag.addObserver(selObs)

        let monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] event in
            guard let self,
                  self.workspace?.activeOverlay == OverlayPanelMode.none,
                  let window = self.window,
                  event.window === window else {
                return event
            }

            if event.type == .leftMouseDown {
                let ptInContainer = self.convert(event.locationInWindow, from: nil)
                if self.bounds.contains(ptInContainer) {
                    if self.workspace?.focusedEditorPane != self.pane {
                        self.workspace?.focusPane(self.pane)
                    }
                }
                if let hosting = self.completionHostingView, !hosting.isHidden {
                    if !hosting.frame.contains(ptInContainer) {
                        self.dismissCompletion()
                    }
                }
                if let hoverHost = self.hoverHostingView, !hoverHost.isHidden {
                    if !hoverHost.frame.contains(ptInContainer) {
                        self.dismissHover()
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
            if self.hoverState.isVisible && Int(event.keyCode) == 53 {
                self.dismissHover()
                return nil
            }
            if self.hoverState.isVisible {
                self.dismissHover()
            }

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

            // F12 (111): Go to Definition | Shift+F12: Find References
            if Int(event.keyCode) == 111 {
                let offset = self.textView.selectionManager.textSelections.first?.range.location ?? 0
                if modifiers == [.shift] {
                    self.findReferences(atOffset: offset)
                    return nil
                } else if modifiers.isEmpty {
                    self.goToDefinition(atOffset: offset)
                    return nil
                }
            }

            // Option+Up (126) / Option+Down (125): Move lines; Option+Shift+Up/Down: Duplicate lines
            if Int(event.keyCode) == 126 || Int(event.keyCode) == 125 {
                let isUp = (Int(event.keyCode) == 126)
                if modifiers == [.option] {
                    self.textView.moveSelectedLines(up: isUp)
                    return nil
                }
                if modifiers == [.option, .shift] {
                    self.textView.duplicateSelectedLines(up: isUp)
                    return nil
                }
            }

            // Cmd+Enter / Cmd+Shift+Enter: Insert line below / above
            if Int(event.keyCode) == 36 {
                if modifiers == [.command] {
                    self.textView.insertLine(above: false)
                    return nil
                }
                if modifiers == [.command, .shift] {
                    self.textView.insertLine(above: true)
                    return nil
                }
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
        resourceBag.setKeyMonitor(monitor)

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

    private func updateGutterWidthIfNeeded() {
        let lineCount = max(1, textView.layoutManager.lineCount)
        let targetWidth = gutterView.requiredWidth(forLineCount: lineCount)
        if let constraint = gutterWidthConstraint, abs(constraint.constant - targetWidth) >= 2 {
            constraint.constant = targetWidth
        }
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
        updateGutterWidthIfNeeded()
        gutterView.needsDisplay = true
        scheduleViewportHighlight(debounceMs: 0)
    }

    private var displayedTab: EditorTab? {
        guard let workspace, let currentTabID else { return nil }
        return workspace.openTabs.first { $0.id == currentTabID }
    }

    func syncExternalBufferChange(tabID: UUID, newContent: String) {
        guard currentTabID == tabID, textView.string != newContent else { return }
        let savedSel = textView.selectionManager.textSelections.first?.range ?? NSRange(location: 0, length: 0)
        isProgrammaticUpdate = true
        textView.setText(newContent)
        let safeLoc = min(savedSel.location, textView.textStorage.length)
        let safeLen = min(savedSel.length, max(0, textView.textStorage.length - safeLoc))
        textView.selectionManager.setSelectedRange(NSRange(location: safeLoc, length: safeLen))
        isProgrammaticUpdate = false
        gutterView.needsDisplay = true
        scheduleViewportHighlight(debounceMs: 12)
    }

    func syncWithTab(_ tab: EditorTab?) {
        guard let tab else {
            currentTabID = nil
            currentTabURL = nil
            currentReloadRevision = 0
            return
        }

        let isReadOnly = (tab.virtualKey != nil)
        if textView.isEditable == isReadOnly {
            textView.isEditable = !isReadOnly
        }

        let tabChanged = (currentTabID != tab.id) || (currentReloadRevision != tab.externalReloadRevision)
        let languageChanged = (currentLanguage != tab.language)

        if tabChanged {
            currentTabID = tab.id
            currentTabURL = tab.url
            currentReloadRevision = tab.externalReloadRevision
            currentLanguage = tab.language
            isProgrammaticUpdate = true
            textView.currentLanguage = tab.language
            textView.typingAttributes = [
                .font: editorFont,
                .foregroundColor: ZedTheme.plainText
            ]
            textView.setText(tab.content)
            textView.updateFrameIfNeeded()

            if let jumpLine = tab.pendingJumpLine {
                jumpToLine(jumpLine, column: tab.pendingJumpColumn)
                workspace?.clearPendingJump(for: tab.id)
            } else {
                let savedRange = workspace?.selectedRange(for: tab.id) ?? NSRange(location: 0, length: 0)
                let safeLoc = min(savedRange.location, textView.textStorage.length)
                let safeLen = min(savedRange.length, max(0, textView.textStorage.length - safeLoc))
                textView.selectionManager.setSelectedRange(NSRange(location: safeLoc, length: safeLen))
                let targetY = workspace?.scrollOffsetY(for: tab.id) ?? -scrollView.contentInsets.top
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: targetY))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }

            isProgrammaticUpdate = false
            dismissCompletion()
            dismissHover()
            refreshDiagnosticsOverlay()
            applyOverlayAttributes()
            updateGutterWidthIfNeeded()
            gutterView.needsDisplay = true
            updateCursorStatus()
            scheduleViewportHighlight(debounceMs: 0)
            if workspace?.focusedEditorPane == pane || workspace?.isSplitEditorActive != true {
                focusEditor()
            }
        } else {
            currentTabURL = tab.url
            if languageChanged {
                currentLanguage = tab.language
                textView.currentLanguage = tab.language
                scheduleViewportHighlight(debounceMs: 0)
            }
            if let pendingLine = tab.pendingJumpLine {
                jumpToLine(pendingLine, column: tab.pendingJumpColumn)
                workspace?.clearPendingJump(for: tab.id)
                if workspace?.focusedEditorPane == pane || workspace?.isSplitEditorActive != true {
                    focusEditor()
                }
            }
        }
    }

    func focusEditor() {
        window?.makeFirstResponder(textView)
    }

    func jumpToLine(_ lineNumber: Int, column: Int? = nil) {
        let zeroBased = max(0, lineNumber - 1)
        if let linePos = textView.layoutManager.textLineForIndex(zeroBased) {
            let lineEnd = linePos.range.location + linePos.range.length
            let colOffset = max(0, (column ?? 1) - 1)
            let clampedOffset = min(linePos.range.location + colOffset, max(linePos.range.location, lineEnd))
            let targetRange = NSRange(location: min(clampedOffset, textView.textStorage.length), length: 0)
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
        guard textView.isEditable, let storage = textView.textStorage, range.max <= storage.length else { return }
        textView.replaceCharacters(in: range, with: replacement)
    }

    func replaceEntireDocument(with newText: String) {
        guard textView.isEditable, let storage = textView.textStorage else { return }
        textView.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: newText)
    }

    // MARK: - TextViewDelegate

    nonisolated func textView(_ textView: TextView, didReplaceContentsIn range: NSRange, with string: String) {
        MainActor.assumeIsolated {
            guard !isProgrammaticUpdate else { return }
            if let tabID = currentTabID {
                workspace?.updateTabContent(tabID: tabID, newContent: textView.string, sourcePane: pane)
            } else {
                workspace?.updateActiveTabContent(textView.string)
            }
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
            if let tabID = currentTabID {
                workspace?.updateTabCursor(tabID: tabID, line: lineNum, column: colNum, range: sel, pane: pane)
            } else {
                workspace?.updateActiveTabCursor(line: lineNum, column: colNum, range: sel)
            }
        } else {
            gutterView.activeLineIndex = 0
            if let tabID = currentTabID {
                workspace?.updateTabCursor(tabID: tabID, line: 1, column: 1, range: sel, pane: pane)
            } else {
                workspace?.updateActiveTabCursor(line: 1, column: 1, range: sel)
            }
        }
    }

    // MARK: - Async Incremental Viewport Syntax Highlighting

    private func scheduleViewportHighlight(debounceMs: UInt64) {
        highlightTask?.cancel()
        highlightRevision &+= 1
        let revision = highlightRevision

        highlightTask = Task { [weak self] in
            if debounceMs > 0 {
                try? await Task.sleep(nanoseconds: debounceMs * 1_000_000)
            }
            if Task.isCancelled { return }

            // Slice textStorage AFTER debounce sleep so superseded keystrokes allocate zero strings.
            let snapshot: (slice: String, start: Int, targetRange: NSRange, language: CodeLanguage, palette: ThemePalette)? = await MainActor.run { [weak self] in
                guard let self, self.highlightRevision == revision else { return nil }
                let totalLength = self.textView.textStorage.length
                guard totalLength > 0 else { return nil }
                let visibleRange = self.textView.visibleTextRange ?? NSRange(location: 0, length: min(totalLength, 6000))
                let buffer = 3500
                let start = max(0, visibleRange.location - buffer)
                let end = min(totalLength, visibleRange.max + buffer)
                let targetRange = NSRange(location: start, length: max(0, end - start))
                guard targetRange.length > 0 else { return nil }
                let nsString = self.textView.textStorage.string as NSString
                let slice = nsString.substring(with: targetRange)
                return (slice, start, targetRange, self.textView.currentLanguage, ZedTheme.palette)
            }
            guard let snapshot, !Task.isCancelled else { return }

            let clockStart = DispatchTime.now().uptimeNanoseconds
            let tokens = await Task.detached(priority: .userInitiated) {
                SyntaxHighlighter.shared.tokenize(
                    slice: snapshot.slice,
                    baseOffset: snapshot.start,
                    language: snapshot.language,
                    palette: snapshot.palette
                )
            }.value
            let tokenizeMs = Double(DispatchTime.now().uptimeNanoseconds - clockStart) / 1_000_000.0

            await MainActor.run { [weak self] in
                guard let self, self.highlightRevision == revision else { return }
                if self.textView.hasMarkedText() {
                    self.needsHighlightAfterIME = true
                    return
                }
                guard let storage = self.textView.textStorage else { return }
                let safeLength = storage.length
                let applyStart = min(snapshot.targetRange.location, safeLength)
                let applyLength = min(snapshot.targetRange.length, max(0, safeLength - applyStart))
                guard applyLength > 0 else { return }

                let resolved = ThemeManager.shared.resolvedColors
                let plainColor = resolved.tokenColorLookup[snapshot.palette.plainTextHex] ?? resolved.plainText
                let applyRange = NSRange(location: applyStart, length: applyLength)
                storage.beginEditing()
                storage.addAttribute(.foregroundColor, value: plainColor, range: applyRange)
                for token in tokens {
                    if token.range.location >= applyStart && token.range.max <= applyStart + applyLength {
                        let color = resolved.tokenColorLookup[token.colorHex] ?? NSColor(hex: token.colorHex)
                        storage.addAttribute(.foregroundColor, value: color, range: token.range)
                    }
                }
                storage.endEditing()

                self.workspace?.updateRenderLatency(tokenizeMs)
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
        let diags = workspace?.diagnostics(for: displayedTab) ?? []
        for diag in diags {
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
        let isTargetPane = (workspace?.isSplitEditorActive != true) || (workspace?.focusedEditorPane == pane)
        guard isTargetPane,
              let findState = workspace?.findState,
              findState.isFindBarVisible,
              !findState.matches.isEmpty else {
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
        let diags = workspace?.diagnostics(for: displayedTab) ?? []
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

    /// O(log N) UTF-16 LSP position lookup backed by CodeEditTextView's B-Tree LineStorage.
    private func lspPosition(for offset: Int) -> LSPPosition? {
        guard let storage = textView.textStorage else { return nil }
        let clamped = max(0, min(offset, storage.length))
        if let linePos = textView.layoutManager.textLineForOffset(clamped) {
            return LSPPosition(line: linePos.index, character: max(0, clamped - linePos.range.location))
        }
        return Self.computeLSPPosition(in: storage.string as NSString, at: clamped)
    }

    nonisolated static func computeLSPPosition(in nsString: NSString, at offset: Int) -> LSPPosition {
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

        guard textView.isEditable, let storage = textView.textStorage else { return }
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

        guard let workspace,
              let fileURL = workspace.activeTab?.url,
              let pos = lspPosition(for: cursor) else {
            return
        }
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
        guard textView.isEditable, let storage = textView.textStorage, range.max <= storage.length else { return }
        isProgrammaticUpdate = true
        textView.replaceCharacters(in: range, with: item.insertText)
        let newLoc = min(storage.length, range.location + (item.insertText as NSString).length)
        textView.selectionManager.setSelectedRange(NSRange(location: newLoc, length: 0))
        isProgrammaticUpdate = false
        if let tabID = currentTabID {
            workspace?.updateTabContent(tabID: tabID, newContent: textView.string, sourcePane: pane)
        } else {
            workspace?.updateActiveTabContent(textView.string)
        }
        gutterView.needsDisplay = true
        scheduleViewportHighlight(debounceMs: 0)
        focusEditor()
    }

    // MARK: - LSP Hover, Definition & References

    private func scheduleHover(atOffset offset: Int, delayMs: UInt64 = 420) {
        hoverTask?.cancel()
        hoverRevision &+= 1
        let rev = hoverRevision
        lastHoverOffset = offset

        guard let workspace,
              let tab = displayedTab,
              let fileURL = tab.url,
              let pos = lspPosition(for: offset) else {
            dismissHover()
            return
        }

        let content = tab.content
        let language = tab.language
        let root = workspace.rootURL

        hoverTask = Task { [weak self] in
            if delayMs > 0 {
                try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
            }
            guard !Task.isCancelled else { return }

            let hover = await LSPManager.shared.requestHover(
                url: fileURL,
                language: language,
                content: content,
                line: pos.line,
                character: pos.character,
                workspaceRoot: root
            )
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.hoverRevision == rev else { return }
                if let hover, !hover.contents.isEmpty {
                    self.showHoverPopup(text: hover.contents, anchorOffset: offset)
                } else {
                    self.dismissHover()
                }
            }
        }
    }

    func showHoverAtCursor() {
        let offset = textView.selectionManager.textSelections.first?.range.location ?? 0
        scheduleHover(atOffset: offset, delayMs: 0)
    }

    private func showHoverPopup(text: String, anchorOffset: Int) {
        guard let hosting = hoverHostingView else { return }
        hoverState.show(text)

        textView.layoutManager.layoutLines()
        let anchorRect: NSRect
        if let r = textView.layoutManager.rectForOffset(anchorOffset) {
            anchorRect = r
        } else if let linePos = textView.layoutManager.textLineForOffset(anchorOffset) {
            anchorRect = NSRect(x: textView.edgeInsets.left, y: linePos.yPos, width: 2, height: max(18, linePos.height))
        } else {
            anchorRect = NSRect(x: textView.edgeInsets.left, y: scrollView.documentVisibleRect.origin.y + 12, width: 2, height: 18)
        }

        let bottomPoint = textView.convert(NSPoint(x: anchorRect.minX, y: anchorRect.maxY), to: self)
        let topPoint = textView.convert(NSPoint(x: anchorRect.minX, y: anchorRect.minY), to: self)

        let lineCount = max(1, text.components(separatedBy: "\n").count)
        let popupWidth: CGFloat = min(440, max(240, bounds.width - 32))
        let popupHeight: CGFloat = min(210, max(44, CGFloat(lineCount) * 16.5 + 24))

        let x = max(8, min(bottomPoint.x, max(8, bounds.width - popupWidth - 8)))
        var y = topPoint.y + 6
        if y + popupHeight > bounds.height - 8 {
            y = bottomPoint.y - popupHeight - 6
        }
        y = max(8, min(y, max(8, bounds.height - popupHeight - 8)))

        hosting.frame = NSRect(x: x, y: y, width: popupWidth, height: popupHeight)
        hosting.isHidden = false
        hosting.needsLayout = true
        hosting.layoutSubtreeIfNeeded()
    }

    func dismissHover() {
        hoverTask?.cancel()
        hoverState.dismiss()
        hoverHostingView?.isHidden = true
    }

    func goToDefinition(atOffset offset: Int) {
        guard let workspace,
              let tab = displayedTab ?? workspace.focusedTab,
              let fileURL = tab.url,
              let pos = lspPosition(for: offset) else {
            return
        }
        let content = tab.content
        let language = tab.language
        let root = workspace.rootURL
        let targetPane = pane

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
                workspace.openFile(
                    url: targetURL.standardized,
                    atLine: first.range.start.line + 1,
                    atColumn: first.range.start.character + 1,
                    recordHistory: true,
                    targetPane: targetPane
                )
            }
        }
    }

    func findReferences(atOffset offset: Int) {
        guard let workspace,
              let tab = displayedTab ?? workspace.focusedTab,
              let pos = lspPosition(for: offset) else {
            return
        }
        let nsText = textView.textStorage.string as NSString
        let prefixRange = LocalCompletionProvider.identifierPrefixRange(in: nsText, at: min(offset + 1, nsText.length))
        let symbolName = prefixRange.length > 0 ? nsText.substring(with: prefixRange) : ""
        workspace.findReferences(for: tab, line: pos.line, character: pos.character, symbolName: symbolName)
    }
}

// MARK: - SwiftUI Bridge

struct HighPerformanceEditorRepresentable: NSViewRepresentable {
    @ObservedObject var workspace: WorkspaceState
    let activeTab: EditorTab?
    var pane: EditorPane = .primary

    func makeNSView(context: Context) -> HighPerformanceEditorContainerView {
        let view = HighPerformanceEditorContainerView(workspace: workspace, pane: pane)
        bindCallbacks(to: view)
        view.syncWithTab(activeTab)
        return view
    }

    func updateNSView(_ nsView: HighPerformanceEditorContainerView, context: Context) {
        bindCallbacks(to: nsView)
        nsView.syncWithTab(activeTab)
    }

    static func dismantleNSView(_ nsView: HighPerformanceEditorContainerView, coordinator: ()) {
        nsView.workspace?.unregisterEditorHandlers(for: nsView.pane)
        nsView.teardown()
    }

    private func bindCallbacks(to view: HighPerformanceEditorContainerView) {
        let handlers = EditorPaneHandlers(
            toggleComment: { [weak view] in
                view?.textView.toggleComment()
            },
            jumpToLocation: { [weak view] line, column in
                view?.jumpToLine(line, column: column)
            },
            focusEditor: { [weak view] in
                view?.focusEditor()
            },
            requestCompletion: { [weak view] in
                view?.triggerCompletion(forceShow: true)
            },
            goToDefinition: { [weak view] in
                guard let view else { return }
                let offset = view.textView.selectionManager.textSelections.first?.range.location ?? 0
                view.goToDefinition(atOffset: offset)
            },
            findReferences: { [weak view] in
                guard let view else { return }
                let offset = view.textView.selectionManager.textSelections.first?.range.location ?? 0
                view.findReferences(atOffset: offset)
            },
            showHover: { [weak view] in
                view?.showHoverAtCursor()
            },
            formatDocument: { [weak workspace] in
                workspace?.formatActiveDocument()
            },
            findMatchesChanged: { [weak view] in
                view?.applyOverlayAttributes()
            },
            highlightRange: { [weak view] range in
                view?.highlightAndScroll(to: range)
            },
            replaceText: { [weak view] range, replacement in
                view?.replaceRange(range, with: replacement)
            },
            replaceAllText: { [weak view] newText in
                view?.replaceEntireDocument(with: newText)
            },
            diagnosticsUpdated: { [weak view] in
                view?.refreshDiagnosticsOverlay()
            },
            selectNextOccurrence: { [weak view] in
                view?.textView.selectNextOccurrence()
            },
            moveLines: { [weak view] up in
                view?.textView.moveSelectedLines(up: up)
            },
            duplicateLines: { [weak view] up in
                view?.textView.duplicateSelectedLines(up: up)
            },
            deleteLines: { [weak view] in
                view?.textView.deleteSelectedLines()
            },
            insertLine: { [weak view] above in
                view?.textView.insertLine(above: above)
            },
            syncBufferExternally: { [weak view] tabID, newText in
                view?.syncExternalBufferChange(tabID: tabID, newContent: newText)
            }
        )
        workspace.registerEditorHandlers(handlers, for: pane)
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
