import AppKit
@preconcurrency import CodeEditTextView

// MARK: - FlashTextView (Enhanced CodeEditTextView)

@MainActor
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

        let selEnd = sel.location + sel.length
        let nextChar: String? = selEnd < nsString.length
            ? nsString.substring(with: NSRange(location: selEnd, length: 1))
            : nil
        let prevChar: String? = sel.location > 0
            ? nsString.substring(with: NSRange(location: sel.location - 1, length: 1))
            : nil

        let isBetweenBrackets = sel.length == 0 && (
            (prevChar == "{" && nextChar == "}")
            || (prevChar == "[" && nextChar == "]")
            || (prevChar == "(" && nextChar == ")")
        )

        if isBetweenBrackets {
            let innerIndent = indent + "    "
            let insertion = "\n\(innerIndent)\n\(indent)"
            replaceCharacters(in: sel, with: insertion, skipUpdateSelection: true)
            let newCursor = sel.location + 1 + (innerIndent as NSString).length
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
        if isEditable,
           !hasMarkedText(),
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
        let lineEnding = block.contains("\r\n") ? "\r\n" : "\n"
        let lines = block.components(separatedBy: lineEnding)
        let hadTrailingNewline = block.hasSuffix(lineEnding)

        var newLines: [String] = []
        var firstLineDelta = 0
        for (idx, line) in lines.enumerated() {
            if idx == lines.count - 1 && line.isEmpty && hadTrailingNewline {
                newLines.append("")
                continue
            }
            if unindent {
                let removed: Int
                if line.hasPrefix("    ") {
                    removed = 4
                    newLines.append(String(line.dropFirst(4)))
                } else if line.hasPrefix("\t") {
                    removed = 1
                    newLines.append(String(line.dropFirst(1)))
                } else {
                    let leadingSpaces = line.prefix(while: { $0 == " " }).count
                    removed = min(leadingSpaces, 4)
                    newLines.append(String(line.dropFirst(removed)))
                }
                if idx == 0 { firstLineDelta = -removed }
            } else {
                newLines.append("    " + line)
                if idx == 0 { firstLineDelta = 4 }
            }
        }

        let replacement = newLines.joined(separator: lineEnding)
        replaceCharacters(in: fullLinesRange, with: replacement, skipUpdateSelection: true)

        if range.length == 0 {
            let newCursor = max(fullLinesRange.location, min(range.location + firstLineDelta, textStorage.length))
            selectionManager.setSelectedRange(NSRange(location: newCursor, length: 0))
        } else {
            let updatedRange = NSRange(location: fullLinesRange.location, length: (replacement as NSString).length)
            selectionManager.setSelectedRange(updatedRange)
        }
    }

    func toggleComment() {
        guard isEditable else { return }
        let prefix = currentLanguage.lineCommentPrefix ?? "//"
        let nsString = textStorage.string as NSString
        let sel = selectionManager.textSelections.first?.range ?? NSRange(location: 0, length: 0)
        let linesRange = nsString.lineRange(for: sel)
        let block = nsString.substring(with: linesRange)
        let lineEnding = block.contains("\r\n") ? "\r\n" : "\n"
        let lines = block.components(separatedBy: lineEnding)
        let hadTrailingNewline = block.hasSuffix(lineEnding)

        let nonEmptyLines = lines.enumerated().filter { idx, line in
            !(idx == lines.count - 1 && line.isEmpty && hadTrailingNewline) &&
            !line.trimmingCharacters(in: .whitespaces).isEmpty
        }

        let allCommented = !nonEmptyLines.isEmpty && nonEmptyLines.allSatisfy { _, line in
            line.trimmingCharacters(in: .whitespaces).hasPrefix(prefix)
        }

        var updated: [String] = []
        var firstLineDelta = 0
        for (idx, line) in lines.enumerated() {
            if idx == lines.count - 1 && line.isEmpty && hadTrailingNewline {
                updated.append("")
                continue
            }
            if allCommented {
                if let range = line.range(of: prefix + " ") {
                    var mutable = line
                    mutable.removeSubrange(range)
                    updated.append(mutable)
                    if idx == 0 { firstLineDelta = -(prefix.count + 1) }
                } else if let range = line.range(of: prefix) {
                    var mutable = line
                    mutable.removeSubrange(range)
                    updated.append(mutable)
                    if idx == 0 { firstLineDelta = -prefix.count }
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
                    if idx == 0 { firstLineDelta = prefix.count + 1 }
                }
            }
        }

        let replacement = updated.joined(separator: lineEnding)
        replaceCharacters(in: linesRange, with: replacement, skipUpdateSelection: true)
        if sel.length == 0 {
            let newCursor = max(linesRange.location, min(sel.location + firstLineDelta, textStorage.length))
            selectionManager.setSelectedRange(NSRange(location: newCursor, length: 0))
        } else {
            let updatedRange = NSRange(location: linesRange.location, length: (replacement as NSString).length)
            selectionManager.setSelectedRange(updatedRange)
        }
    }

    // MARK: - Line Editing & Multi-Cursor (⌘D, ⌥↑/↓, ⌥⇧↑/↓, ⌘⇧K, ⌘↵)

    func selectNextOccurrence() {
        let nsString = textStorage.string as NSString
        guard nsString.length > 0 else { return }

        let currentRanges = selectionManager.textSelections.map(\.range).sorted { $0.location < $1.location }
        guard let firstRange = currentRanges.first else { return }

        // If cursor has no selection, expand to the word under cursor.
        if currentRanges.count == 1 && firstRange.length == 0 {
            let wordRange = wordRangeAt(offset: firstRange.location, in: nsString)
            if wordRange.length > 0 {
                selectionManager.setSelectedRange(wordRange)
                scrollToRange(wordRange, center: false)
            }
            return
        }

        let needle = nsString.substring(with: firstRange)
        guard !needle.isEmpty else { return }

        let lastSelected = currentRanges.last ?? firstRange
        let searchStart = lastSelected.location + lastSelected.length
        var found = NSRange(location: NSNotFound, length: 0)

        if searchStart < nsString.length {
            let tail = NSRange(location: searchStart, length: nsString.length - searchStart)
            found = nsString.range(of: needle, options: [], range: tail)
        }
        // Wrap around to top of document if not found below.
        if found.location == NSNotFound && firstRange.location > 0 {
            let head = NSRange(location: 0, length: firstRange.location)
            found = nsString.range(of: needle, options: [], range: head)
        }

        guard found.location != NSNotFound else { return }
        if currentRanges.contains(where: { $0 == found }) {
            return
        }
        var updated = currentRanges
        updated.append(found)
        updated.sort { $0.location < $1.location }
        selectionManager.setSelectedRanges(updated)
        scrollToRange(found, center: false)
    }

    func moveSelectedLines(up: Bool) {
        guard isEditable else { return }
        let nsString = textStorage.string as NSString
        guard nsString.length > 0, let sel = selectionManager.textSelections.first?.range else { return }

        let blockRange = nsString.lineRange(for: sel)
        if up {
            guard blockRange.location > 0 else { return }
            let prevRange = nsString.lineRange(for: NSRange(location: blockRange.location - 1, length: 0))
            let prevText = nsString.substring(with: prevRange)
            let blockText = nsString.substring(with: blockRange)
            let combinedRange = NSRange(location: prevRange.location, length: prevRange.length + blockRange.length)

            let replacement: String
            let newSelLocation: Int
            if !blockText.hasSuffix("\n") && prevText.hasSuffix("\n") {
                let trimmedPrev = String(prevText.dropLast())
                replacement = blockText + "\n" + trimmedPrev
                newSelLocation = sel.location - prevRange.length
            } else {
                replacement = blockText + prevText
                newSelLocation = sel.location - prevRange.length
            }

            replaceCharacters(in: combinedRange, with: replacement, skipUpdateSelection: true)
            let clampedLoc = max(0, min(newSelLocation, textStorage.length))
            let clampedLen = min(sel.length, max(0, textStorage.length - clampedLoc))
            selectionManager.setSelectedRange(NSRange(location: clampedLoc, length: clampedLen))
            scrollSelectionToVisible()
        } else {
            let blockEnd = blockRange.location + blockRange.length
            guard blockEnd < nsString.length else { return }
            let nextRange = nsString.lineRange(for: NSRange(location: blockEnd, length: 0))
            let blockText = nsString.substring(with: blockRange)
            let nextText = nsString.substring(with: nextRange)
            let combinedRange = NSRange(location: blockRange.location, length: blockRange.length + nextRange.length)

            let replacement: String
            let delta: Int
            if !nextText.hasSuffix("\n") && blockText.hasSuffix("\n") {
                let trimmedBlock = String(blockText.dropLast())
                replacement = nextText + "\n" + trimmedBlock
                delta = (nextText as NSString).length + 1
            } else {
                replacement = nextText + blockText
                delta = nextRange.length
            }

            replaceCharacters(in: combinedRange, with: replacement, skipUpdateSelection: true)
            let clampedLoc = max(0, min(sel.location + delta, textStorage.length))
            let clampedLen = min(sel.length, max(0, textStorage.length - clampedLoc))
            selectionManager.setSelectedRange(NSRange(location: clampedLoc, length: clampedLen))
            scrollSelectionToVisible()
        }
    }

    func duplicateSelectedLines(up: Bool) {
        guard isEditable else { return }
        let nsString = textStorage.string as NSString
        guard let sel = selectionManager.textSelections.first?.range else { return }

        let blockRange = nsString.lineRange(for: sel)
        let blockText = nsString.substring(with: blockRange)
        let hasTrailingNewline = blockText.hasSuffix("\n")
        let normalizedBlock = hasTrailingNewline ? blockText : (blockText + "\n")

        if up {
            replaceCharacters(in: NSRange(location: blockRange.location, length: 0), with: normalizedBlock, skipUpdateSelection: true)
            selectionManager.setSelectedRange(sel)
        } else {
            let insertLoc = blockRange.location + blockRange.length
            let insertion = hasTrailingNewline ? blockText : ("\n" + blockText)
            let delta = hasTrailingNewline ? blockRange.length : ((blockText as NSString).length + 1)
            replaceCharacters(in: NSRange(location: insertLoc, length: 0), with: insertion, skipUpdateSelection: true)
            let newLoc = min(sel.location + delta, textStorage.length)
            let newLen = min(sel.length, max(0, textStorage.length - newLoc))
            selectionManager.setSelectedRange(NSRange(location: newLoc, length: newLen))
        }
        scrollSelectionToVisible()
    }

    func deleteSelectedLines() {
        guard isEditable else { return }
        let nsString = textStorage.string as NSString
        guard nsString.length > 0, let sel = selectionManager.textSelections.first?.range else { return }

        var blockRange = nsString.lineRange(for: sel)
        // If deleting the last line that has no trailing newline, also eat the preceding newline.
        if blockRange.location + blockRange.length == nsString.length,
           blockRange.location > 0,
           !nsString.substring(with: blockRange).hasSuffix("\n") {
            blockRange = NSRange(location: blockRange.location - 1, length: blockRange.length + 1)
        }

        replaceCharacters(in: blockRange, with: "", skipUpdateSelection: true)
        let newLoc = min(blockRange.location, textStorage.length)
        selectionManager.setSelectedRange(NSRange(location: newLoc, length: 0))
        scrollSelectionToVisible()
    }

    func insertLine(above: Bool) {
        guard isEditable else { return }
        let nsString = textStorage.string as NSString
        guard let sel = selectionManager.textSelections.first?.range else { return }

        let lineRange = nsString.lineRange(for: NSRange(location: sel.location, length: 0))
        let lineText = nsString.substring(with: lineRange)
        let indent = String(lineText.prefix(while: { $0 == " " || $0 == "\t" }))

        if above {
            let insertion = indent + "\n"
            replaceCharacters(in: NSRange(location: lineRange.location, length: 0), with: insertion, skipUpdateSelection: true)
            let cursorLoc = lineRange.location + (indent as NSString).length
            selectionManager.setSelectedRange(NSRange(location: cursorLoc, length: 0))
        } else {
            let hasNewline = lineText.hasSuffix("\n")
            let insertLoc = hasNewline ? (lineRange.location + lineRange.length - 1) : (lineRange.location + lineRange.length)
            let insertion = "\n" + indent
            replaceCharacters(in: NSRange(location: insertLoc, length: 0), with: insertion, skipUpdateSelection: true)
            let cursorLoc = insertLoc + 1 + (indent as NSString).length
            selectionManager.setSelectedRange(NSRange(location: cursorLoc, length: 0))
        }
        scrollSelectionToVisible()
    }

    private func wordRangeAt(offset: Int, in nsString: NSString) -> NSRange {
        let len = nsString.length
        guard len > 0 else { return NSRange(location: 0, length: 0) }
        var pos = min(max(0, offset), len)
        if pos == len || !LocalCompletionProvider.isIdentifierChar(nsString.character(at: pos)) {
            if pos > 0 && LocalCompletionProvider.isIdentifierChar(nsString.character(at: pos - 1)) {
                pos -= 1
            } else {
                return NSRange(location: offset, length: 0)
            }
        }
        var start = pos
        while start > 0 && LocalCompletionProvider.isIdentifierChar(nsString.character(at: start - 1)) {
            start -= 1
        }
        var end = pos + 1
        while end < len && LocalCompletionProvider.isIdentifierChar(nsString.character(at: end)) {
            end += 1
        }
        return NSRange(location: start, length: end - start)
    }
}
