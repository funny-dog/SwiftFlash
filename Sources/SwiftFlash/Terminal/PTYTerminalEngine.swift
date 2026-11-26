import AppKit
import Combine
import CoreText
import Darwin
import Foundation
import SwiftUI

// MARK: - Terminal Color & Cell Model

enum TerminalColorSpec: Equatable, Hashable, Sendable {
    case defaultForeground
    case defaultBackground
    case ansi(UInt8)        // 0...15
    case palette256(UInt8)  // 0...255
    case rgb(UInt8, UInt8, UInt8)

    @MainActor
    func resolveNSColor(isForeground: Bool) -> NSColor {
        switch self {
        case .defaultForeground:
            return ZedTheme.plainText
        case .defaultBackground:
            return ZedTheme.background
        case .ansi(let idx):
            return Self.ansiColor(idx)
        case .palette256(let idx):
            if idx < 16 {
                return Self.ansiColor(idx)
            } else if idx < 232 {
                let n = Int(idx) - 16
                let r = (n / 36) % 6
                let g = (n / 6) % 6
                let b = n % 6
                let map: [CGFloat] = [0, 95, 135, 175, 215, 255].map { $0 / 255.0 }
                return NSColor(srgbRed: map[r], green: map[g], blue: map[b], alpha: 1.0)
            } else {
                let gray = CGFloat(8 + (Int(idx) - 232) * 10) / 255.0
                return NSColor(srgbRed: gray, green: gray, blue: gray, alpha: 1.0)
            }
        case .rgb(let r, let g, let b):
            return NSColor(
                srgbRed: CGFloat(r) / 255.0,
                green: CGFloat(g) / 255.0,
                blue: CGFloat(b) / 255.0,
                alpha: 1.0
            )
        }
    }

    @MainActor
    private static func ansiColor(_ idx: UInt8) -> NSColor {
        switch idx {
        case 0: return ZedTheme.isDark ? NSColor(hex: 0x3E4451) : NSColor(hex: 0x282828)
        case 1: return ZedTheme.attribute
        case 2: return ZedTheme.string
        case 3: return ZedTheme.typeName
        case 4: return ZedTheme.function
        case 5: return ZedTheme.keyword
        case 6: return ZedTheme.operatorColor
        case 7: return ZedTheme.secondaryText
        case 8: return ZedTheme.comment
        case 9: return ZedTheme.attribute
        case 10: return ZedTheme.string
        case 11: return ZedTheme.typeName
        case 12: return ZedTheme.function
        case 13: return ZedTheme.keyword
        case 14: return ZedTheme.operatorColor
        case 15: return ZedTheme.primaryText
        default: return ZedTheme.plainText
        }
    }
}

struct TerminalCellAttributes: Equatable, Sendable {
    var fg: TerminalColorSpec = .defaultForeground
    var bg: TerminalColorSpec = .defaultBackground
    var bold: Bool = false
    var underline: Bool = false
    var inverse: Bool = false
}

struct TerminalCell: Equatable, Sendable {
    var char: Character = " "
    var attrs: TerminalCellAttributes = TerminalCellAttributes()
    /// 1 = standard cell, 2 = lead half of wide char, 0 = trailing continuation half
    var width: UInt8 = 1

    static let blank = TerminalCell()
}

// MARK: - Incremental UTF-8 Stream Decoder

struct UTF8StreamDecoder: Sendable {
    private var pending: [UInt8] = []

    mutating func decode(_ data: Data) -> String {
        guard !data.isEmpty else { return "" }
        pending.append(contentsOf: data)
        guard !pending.isEmpty else { return "" }

        var output = ""
        output.reserveCapacity(pending.count)
        var i = 0
        let n = pending.count

        while i < n {
            let b0 = pending[i]
            if b0 < 0x80 {
                output.unicodeScalars.append(UnicodeScalar(b0))
                i += 1
            } else if b0 >= 0xC2 && b0 <= 0xDF {
                if i + 1 >= n { break }
                let b1 = pending[i + 1]
                if (b1 & 0xC0) == 0x80,
                   let scalar = UnicodeScalar((UInt32(b0 & 0x1F) << 6) | UInt32(b1 & 0x3F)) {
                    output.unicodeScalars.append(scalar)
                    i += 2
                } else {
                    output.append("\u{FFFD}")
                    i += 1
                }
            } else if b0 >= 0xE0 && b0 <= 0xEF {
                if i + 2 >= n { break }
                let b1 = pending[i + 1]
                let b2 = pending[i + 2]
                let cp = (UInt32(b0 & 0x0F) << 12) | (UInt32(b1 & 0x3F) << 6) | UInt32(b2 & 0x3F)
                if (b1 & 0xC0) == 0x80, (b2 & 0xC0) == 0x80, let scalar = UnicodeScalar(cp) {
                    output.unicodeScalars.append(scalar)
                    i += 3
                } else {
                    output.append("\u{FFFD}")
                    i += 1
                }
            } else if b0 >= 0xF0 && b0 <= 0xF4 {
                if i + 3 >= n { break }
                let b1 = pending[i + 1]
                let b2 = pending[i + 2]
                let b3 = pending[i + 3]
                let cp = (UInt32(b0 & 0x07) << 18)
                    | (UInt32(b1 & 0x3F) << 12)
                    | (UInt32(b2 & 0x3F) << 6)
                    | UInt32(b3 & 0x3F)
                if (b1 & 0xC0) == 0x80, (b2 & 0xC0) == 0x80, (b3 & 0xC0) == 0x80, let scalar = UnicodeScalar(cp) {
                    output.unicodeScalars.append(scalar)
                    i += 4
                } else {
                    output.append("\u{FFFD}")
                    i += 1
                }
            } else {
                output.append("\u{FFFD}")
                i += 1
            }
        }

        if i > 0 {
            pending.removeFirst(i)
        }
        return output
    }
}

// MARK: - VT100 / xterm Terminal Emulator Buffer

final class VT100TerminalEmulator: @unchecked Sendable {
    private enum ParseState {
        case ground
        case escape
        case csi
        case osc
        case oscEscape
        case charset
    }

    private(set) var cols: Int
    private(set) var rows: Int
    private(set) var grid: [[TerminalCell]]
    private(set) var scrollback: [[TerminalCell]] = []
    private let maxScrollback = 2500

    private var savedMainGrid: [[TerminalCell]]?
    private var savedMainCursor: (row: Int, col: Int) = (0, 0)
    private(set) var isUsingAlternateScreen: Bool = false

    private(set) var cursorRow: Int = 0
    private(set) var cursorCol: Int = 0
    private var savedCursor: (row: Int, col: Int, attrs: TerminalCellAttributes)?
    private var wrapPending: Bool = false

    private var scrollTop: Int = 0
    private var scrollBottom: Int

    private(set) var cursorVisible: Bool = true
    private(set) var applicationCursorKeys: Bool = false
    private(set) var bracketedPasteMode: Bool = false
    private(set) var title: String = ""
    private(set) var reportedWorkingDirectory: URL?

    private var currentAttrs = TerminalCellAttributes()
    private var parseState: ParseState = .ground
    private var csiBuffer: String = ""
    private var oscBuffer: String = ""
    private var utf8Decoder = UTF8StreamDecoder()

    var onWriteBack: (@Sendable (Data) -> Void)?
    var onTitleChanged: (@Sendable (String) -> Void)?
    var onWorkingDirectoryChanged: (@Sendable (URL) -> Void)?

    init(cols: Int = 100, rows: Int = 24) {
        self.cols = max(20, cols)
        self.rows = max(4, rows)
        self.scrollBottom = self.rows - 1
        self.grid = Self.makeBlankGrid(rows: self.rows, cols: self.cols)
    }

    private static func makeBlankRow(cols: Int) -> [TerminalCell] {
        Array(repeating: TerminalCell.blank, count: cols)
    }

    private static func makeBlankGrid(rows: Int, cols: Int) -> [[TerminalCell]] {
        Array(repeating: makeBlankRow(cols: cols), count: rows)
    }

    func reset() {
        isUsingAlternateScreen = false
        savedMainGrid = nil
        grid = Self.makeBlankGrid(rows: rows, cols: cols)
        scrollback.removeAll()
        cursorRow = 0
        cursorCol = 0
        wrapPending = false
        scrollTop = 0
        scrollBottom = rows - 1
        currentAttrs = TerminalCellAttributes()
        cursorVisible = true
        applicationCursorKeys = false
        bracketedPasteMode = false
        parseState = .ground
        csiBuffer = ""
        oscBuffer = ""
    }

    func resize(cols newCols: Int, rows newRows: Int) {
        let clampedCols = max(20, min(400, newCols))
        let clampedRows = max(4, min(200, newRows))
        guard clampedCols != cols || clampedRows != rows else { return }

        var resized: [[TerminalCell]] = []
        resized.reserveCapacity(clampedRows)
        for r in 0..<clampedRows {
            if r < grid.count {
                var row = grid[r]
                if row.count < clampedCols {
                    row.append(contentsOf: Array(repeating: TerminalCell.blank, count: clampedCols - row.count))
                } else if row.count > clampedCols {
                    row.removeLast(row.count - clampedCols)
                }
                resized.append(row)
            } else {
                resized.append(Self.makeBlankRow(cols: clampedCols))
            }
        }

        cols = clampedCols
        rows = clampedRows
        grid = resized
        scrollTop = 0
        scrollBottom = rows - 1
        cursorRow = min(cursorRow, rows - 1)
        cursorCol = min(cursorCol, cols - 1)
        wrapPending = false
    }

    func feed(_ data: Data) {
        let str = utf8Decoder.decode(data)
        feed(string: str)
    }

    func feed(string: String) {
        for ch in string {
            if ch == "\r\n" {
                processCharacter("\r")
                processCharacter("\n")
            } else {
                processCharacter(ch)
            }
        }
    }

    /// Returns visible plain text of the active screen (for testing & selection copy).
    func plainScreenText() -> String {
        grid.map { rowText($0) }.joined(separator: "\n")
    }

    func rowText(_ row: [TerminalCell]) -> String {
        var s = ""
        s.reserveCapacity(row.count)
        for cell in row where cell.width != 0 {
            s.append(cell.char)
        }
        while s.last == " " {
            s.removeLast()
        }
        return s
    }

    var totalHistoryRows: Int {
        scrollback.count + rows
    }

    func rowAtCombinedIndex(_ index: Int) -> [TerminalCell] {
        if index < scrollback.count {
            return scrollback[index]
        }
        let screenIdx = index - scrollback.count
        if screenIdx >= 0 && screenIdx < grid.count {
            return grid[screenIdx]
        }
        return Self.makeBlankRow(cols: cols)
    }

    // MARK: - Character State Machine

    private func processCharacter(_ ch: Character) {
        switch parseState {
        case .ground:
            handleGround(ch)
        case .escape:
            handleEscape(ch)
        case .charset:
            parseState = .ground
        case .csi:
            handleCSI(ch)
        case .osc:
            handleOSC(ch)
        case .oscEscape:
            if ch == "\\" {
                finishOSC()
            }
            parseState = .ground
        }
    }

    private func handleGround(_ ch: Character) {
        guard let scalar = ch.unicodeScalars.first, ch.unicodeScalars.count == 1 else {
            putPrintable(ch)
            return
        }
        switch scalar.value {
        case 0x1B: // ESC
            parseState = .escape
        case 0x07: // BEL
            break
        case 0x08: // BS
            wrapPending = false
            if cursorCol > 0 { cursorCol -= 1 }
        case 0x09: // TAB
            wrapPending = false
            let nextTab = ((cursorCol / 8) + 1) * 8
            cursorCol = min(cols - 1, nextTab)
        case 0x0A, 0x0B, 0x0C: // LF / VT / FF
            lineFeed()
        case 0x0D: // CR
            wrapPending = false
            cursorCol = 0
        case 0x00...0x1F, 0x7F:
            break
        default:
            putPrintable(ch)
        }
    }

    private func handleEscape(_ ch: Character) {
        switch ch {
        case "[":
            csiBuffer = ""
            parseState = .csi
        case "]":
            oscBuffer = ""
            parseState = .osc
        case "(", ")", "*", "+":
            parseState = .charset
        case "7":
            savedCursor = (cursorRow, cursorCol, currentAttrs)
            parseState = .ground
        case "8":
            if let saved = savedCursor {
                cursorRow = min(saved.row, rows - 1)
                cursorCol = min(saved.col, cols - 1)
                currentAttrs = saved.attrs
                wrapPending = false
            }
            parseState = .ground
        case "D": // IND
            lineFeed()
            parseState = .ground
        case "E": // NEL
            cursorCol = 0
            lineFeed()
            parseState = .ground
        case "M": // RI (Reverse Index)
            reverseIndex()
            parseState = .ground
        case "c": // RIS
            reset()
        default:
            parseState = .ground
        }
    }

    private func handleCSI(_ ch: Character) {
        guard let scalar = ch.unicodeScalars.first else {
            parseState = .ground
            return
        }
        let v = scalar.value
        if v >= 0x40 && v <= 0x7E {
            dispatchCSI(final: ch, paramsRaw: csiBuffer)
            csiBuffer = ""
            parseState = .ground
        } else if v == 0x1B {
            csiBuffer = ""
            parseState = .escape
        } else {
            if csiBuffer.count < 128 {
                csiBuffer.append(ch)
            }
        }
    }

    private func handleOSC(_ ch: Character) {
        if ch == "\u{07}" {
            finishOSC()
            parseState = .ground
        } else if ch == "\u{1B}" {
            parseState = .oscEscape
        } else if oscBuffer.count < 1024 {
            oscBuffer.append(ch)
        }
    }

    private func finishOSC() {
        let content = oscBuffer
        oscBuffer = ""
        guard let sep = content.firstIndex(of: ";") else { return }
        let code = String(content[..<sep])
        let value = String(content[content.index(after: sep)...])

        switch code {
        case "0", "2":
            title = value
            onTitleChanged?(value)
        case "7":
            if let url = URL(string: value), url.isFileURL {
                let resolved = url.standardized
                reportedWorkingDirectory = resolved
                onWorkingDirectoryChanged?(resolved)
            }
        default:
            break
        }
    }

    // MARK: - CSI Dispatcher

    private func dispatchCSI(final: Character, paramsRaw: String) {
        let isPrivate = paramsRaw.hasPrefix("?")
        let stripped = isPrivate ? String(paramsRaw.dropFirst()) : paramsRaw
        let cleanParams = stripped.filter { $0.isNumber || $0 == ";" }
        let params: [Int] = cleanParams.isEmpty
            ? []
            : cleanParams.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }

        func param(_ index: Int, default defaultVal: Int) -> Int {
            guard index < params.count, params[index] > 0 else { return defaultVal }
            return params[index]
        }

        if isPrivate {
            switch final {
            case "h":
                for p in params { setPrivateMode(p, enabled: true) }
            case "l":
                for p in params { setPrivateMode(p, enabled: false) }
            default:
                break
            }
            return
        }

        switch final {
        case "A": // CUU
            wrapPending = false
            cursorRow = max(scrollTop, cursorRow - param(0, default: 1))
        case "B": // CUD
            wrapPending = false
            cursorRow = min(scrollBottom, cursorRow + param(0, default: 1))
        case "C": // CUF
            wrapPending = false
            cursorCol = min(cols - 1, cursorCol + param(0, default: 1))
        case "D": // CUB
            wrapPending = false
            cursorCol = max(0, cursorCol - param(0, default: 1))
        case "E": // CNL
            wrapPending = false
            cursorCol = 0
            cursorRow = min(scrollBottom, cursorRow + param(0, default: 1))
        case "F": // CPL
            wrapPending = false
            cursorCol = 0
            cursorRow = max(scrollTop, cursorRow - param(0, default: 1))
        case "G": // CHA
            wrapPending = false
            cursorCol = max(0, min(cols - 1, param(0, default: 1) - 1))
        case "d": // VPA
            wrapPending = false
            cursorRow = max(0, min(rows - 1, param(0, default: 1) - 1))
        case "H", "f": // CUP / HVP
            wrapPending = false
            cursorRow = max(0, min(rows - 1, param(0, default: 1) - 1))
            cursorCol = max(0, min(cols - 1, param(1, default: 1) - 1))
        case "J": // ED
            let mode = params.first ?? 0
            eraseDisplay(mode: mode)
        case "K": // EL
            let mode = params.first ?? 0
            eraseLine(mode: mode)
        case "L": // IL
            insertLines(param(0, default: 1))
        case "M": // DL
            deleteLines(param(0, default: 1))
        case "P": // DCH
            deleteChars(param(0, default: 1))
        case "@": // ICH
            insertChars(param(0, default: 1))
        case "X": // ECH
            let n = param(0, default: 1)
            let end = min(cols, cursorCol + n)
            for c in cursorCol..<end {
                grid[cursorRow][c] = blankCellWithBackground()
            }
        case "S": // SU
            scrollUp(lines: param(0, default: 1))
        case "T": // SD
            scrollDown(lines: param(0, default: 1))
        case "r": // DECSTBM
            let top = max(0, param(0, default: 1) - 1)
            let bottom = min(rows - 1, param(1, default: rows) - 1)
            if top < bottom {
                scrollTop = top
                scrollBottom = bottom
            } else {
                scrollTop = 0
                scrollBottom = rows - 1
            }
            cursorRow = 0
            cursorCol = 0
            wrapPending = false
        case "s":
            savedCursor = (cursorRow, cursorCol, currentAttrs)
        case "u":
            if let saved = savedCursor {
                cursorRow = min(saved.row, rows - 1)
                cursorCol = min(saved.col, cols - 1)
                currentAttrs = saved.attrs
                wrapPending = false
            }
        case "m": // SGR
            applySGR(params.isEmpty ? [0] : params)
        case "n": // DSR
            if params.first == 6 {
                let response = "\u{1B}[\(cursorRow + 1);\(cursorCol + 1)R"
                if let data = response.data(using: .utf8) {
                    onWriteBack?(data)
                }
            }
        default:
            break
        }
    }

    private func setPrivateMode(_ mode: Int, enabled: Bool) {
        switch mode {
        case 1:
            applicationCursorKeys = enabled
        case 25:
            cursorVisible = enabled
        case 47, 1047, 1049:
            if enabled {
                if !isUsingAlternateScreen {
                    savedMainGrid = grid
                    savedMainCursor = (cursorRow, cursorCol)
                    isUsingAlternateScreen = true
                    grid = Self.makeBlankGrid(rows: rows, cols: cols)
                    cursorRow = 0
                    cursorCol = 0
                    scrollTop = 0
                    scrollBottom = rows - 1
                    wrapPending = false
                }
            } else {
                if isUsingAlternateScreen {
                    isUsingAlternateScreen = false
                    if let saved = savedMainGrid {
                        grid = saved
                        savedMainGrid = nil
                        resizeGridToCurrentDimensions()
                    }
                    cursorRow = min(savedMainCursor.row, rows - 1)
                    cursorCol = min(savedMainCursor.col, cols - 1)
                    scrollTop = 0
                    scrollBottom = rows - 1
                    wrapPending = false
                }
            }
        case 2004:
            bracketedPasteMode = enabled
        default:
            break
        }
    }

    private func resizeGridToCurrentDimensions() {
        while grid.count < rows {
            grid.append(Self.makeBlankRow(cols: cols))
        }
        if grid.count > rows {
            grid.removeLast(grid.count - rows)
        }
        for r in 0..<grid.count {
            if grid[r].count < cols {
                grid[r].append(contentsOf: Array(repeating: TerminalCell.blank, count: cols - grid[r].count))
            } else if grid[r].count > cols {
                grid[r].removeLast(grid[r].count - cols)
            }
        }
    }

    // MARK: - SGR Parsing

    private func applySGR(_ params: [Int]) {
        var i = 0
        while i < params.count {
            let code = params[i]
            switch code {
            case 0:
                currentAttrs = TerminalCellAttributes()
            case 1:
                currentAttrs.bold = true
            case 4:
                currentAttrs.underline = true
            case 7:
                currentAttrs.inverse = true
            case 22:
                currentAttrs.bold = false
            case 24:
                currentAttrs.underline = false
            case 27:
                currentAttrs.inverse = false
            case 30...37:
                currentAttrs.fg = .ansi(UInt8(code - 30))
            case 38:
                if i + 2 < params.count && params[i + 1] == 5 {
                    currentAttrs.fg = .palette256(UInt8(clamping: params[i + 2]))
                    i += 2
                } else if i + 4 < params.count && params[i + 1] == 2 {
                    currentAttrs.fg = .rgb(
                        UInt8(clamping: params[i + 2]),
                        UInt8(clamping: params[i + 3]),
                        UInt8(clamping: params[i + 4])
                    )
                    i += 4
                }
            case 39:
                currentAttrs.fg = .defaultForeground
            case 40...47:
                currentAttrs.bg = .ansi(UInt8(code - 40))
            case 48:
                if i + 2 < params.count && params[i + 1] == 5 {
                    currentAttrs.bg = .palette256(UInt8(clamping: params[i + 2]))
                    i += 2
                } else if i + 4 < params.count && params[i + 1] == 2 {
                    currentAttrs.bg = .rgb(
                        UInt8(clamping: params[i + 2]),
                        UInt8(clamping: params[i + 3]),
                        UInt8(clamping: params[i + 4])
                    )
                    i += 4
                }
            case 49:
                currentAttrs.bg = .defaultBackground
            case 90...97:
                currentAttrs.fg = .ansi(UInt8(code - 90 + 8))
            case 100...107:
                currentAttrs.bg = .ansi(UInt8(code - 100 + 8))
            default:
                break
            }
            i += 1
        }
    }

    // MARK: - Screen Operations

    private func blankCellWithBackground() -> TerminalCell {
        var attrs = TerminalCellAttributes()
        attrs.bg = currentAttrs.bg
        return TerminalCell(char: " ", attrs: attrs, width: 1)
    }

    private func putPrintable(_ ch: Character) {
        let charWidth: Int = Self.isWideCharacter(ch) ? 2 : 1

        if wrapPending {
            wrapPending = false
            cursorCol = 0
            lineFeed()
        }

        if charWidth == 2 && cursorCol >= cols - 1 {
            grid[cursorRow][cursorCol] = blankCellWithBackground()
            cursorCol = 0
            lineFeed()
        }

        // Clear broken wide-char neighbor if overwriting mid-character.
        if cursorCol < cols && grid[cursorRow][cursorCol].width == 0 && cursorCol > 0 {
            grid[cursorRow][cursorCol - 1] = TerminalCell.blank
        }
        if cursorCol < cols && grid[cursorRow][cursorCol].width == 2 && cursorCol + 1 < cols {
            grid[cursorRow][cursorCol + 1] = TerminalCell.blank
        }

        grid[cursorRow][cursorCol] = TerminalCell(char: ch, attrs: currentAttrs, width: UInt8(charWidth))
        if charWidth == 2 && cursorCol + 1 < cols {
            grid[cursorRow][cursorCol + 1] = TerminalCell(char: " ", attrs: currentAttrs, width: 0)
        }

        if cursorCol + charWidth >= cols {
            cursorCol = cols - 1
            wrapPending = true
        } else {
            cursorCol += charWidth
        }
    }

    private func lineFeed() {
        wrapPending = false
        if cursorRow == scrollBottom {
            scrollUp(lines: 1)
        } else if cursorRow < rows - 1 {
            cursorRow += 1
        }
    }

    private func reverseIndex() {
        wrapPending = false
        if cursorRow == scrollTop {
            scrollDown(lines: 1)
        } else if cursorRow > 0 {
            cursorRow -= 1
        }
    }

    private func scrollUp(lines count: Int) {
        let n = min(count, scrollBottom - scrollTop + 1)
        guard n > 0 else { return }
        for _ in 0..<n {
            let removed = grid.remove(at: scrollTop)
            if !isUsingAlternateScreen && scrollTop == 0 && scrollBottom == rows - 1 {
                scrollback.append(removed)
                if scrollback.count > maxScrollback {
                    scrollback.removeFirst(scrollback.count - maxScrollback)
                }
            }
            grid.insert(Self.makeBlankRow(cols: cols), at: scrollBottom)
        }
    }

    private func scrollDown(lines count: Int) {
        let n = min(count, scrollBottom - scrollTop + 1)
        guard n > 0 else { return }
        for _ in 0..<n {
            grid.remove(at: scrollBottom)
            grid.insert(Self.makeBlankRow(cols: cols), at: scrollTop)
        }
    }

    private func insertLines(_ count: Int) {
        guard cursorRow >= scrollTop && cursorRow <= scrollBottom else { return }
        let n = min(count, scrollBottom - cursorRow + 1)
        for _ in 0..<n {
            grid.remove(at: scrollBottom)
            grid.insert(Self.makeBlankRow(cols: cols), at: cursorRow)
        }
    }

    private func deleteLines(_ count: Int) {
        guard cursorRow >= scrollTop && cursorRow <= scrollBottom else { return }
        let n = min(count, scrollBottom - cursorRow + 1)
        for _ in 0..<n {
            grid.remove(at: cursorRow)
            grid.insert(Self.makeBlankRow(cols: cols), at: scrollBottom)
        }
    }

    private func insertChars(_ count: Int) {
        let n = min(count, cols - cursorCol)
        guard n > 0 else { return }
        grid[cursorRow].insert(contentsOf: Array(repeating: blankCellWithBackground(), count: n), at: cursorCol)
        grid[cursorRow].removeLast(n)
    }

    private func deleteChars(_ count: Int) {
        let n = min(count, cols - cursorCol)
        guard n > 0 else { return }
        grid[cursorRow].removeSubrange(cursorCol..<(cursorCol + n))
        grid[cursorRow].append(contentsOf: Array(repeating: blankCellWithBackground(), count: n))
    }

    private func eraseDisplay(mode: Int) {
        switch mode {
        case 0:
            eraseLine(mode: 0)
            if cursorRow + 1 < rows {
                for r in (cursorRow + 1)..<rows {
                    grid[r] = Array(repeating: blankCellWithBackground(), count: cols)
                }
            }
        case 1:
            for r in 0..<cursorRow {
                grid[r] = Array(repeating: blankCellWithBackground(), count: cols)
            }
            eraseLine(mode: 1)
        case 2:
            for r in 0..<rows {
                grid[r] = Array(repeating: blankCellWithBackground(), count: cols)
            }
        case 3:
            scrollback.removeAll()
            for r in 0..<rows {
                grid[r] = Array(repeating: blankCellWithBackground(), count: cols)
            }
        default:
            break
        }
    }

    private func eraseLine(mode: Int) {
        switch mode {
        case 0:
            for c in cursorCol..<cols {
                grid[cursorRow][c] = blankCellWithBackground()
            }
        case 1:
            for c in 0...min(cursorCol, cols - 1) {
                grid[cursorRow][c] = blankCellWithBackground()
            }
        case 2:
            grid[cursorRow] = Array(repeating: blankCellWithBackground(), count: cols)
        default:
            break
        }
    }

    private static func isWideCharacter(_ ch: Character) -> Bool {
        guard let scalar = ch.unicodeScalars.first else { return false }
        let v = scalar.value
        if v < 0x1100 { return false }
        return (0x1100...0x115F).contains(v)
            || (0x2E80...0x9FFF).contains(v)
            || (0xAC00...0xD7A3).contains(v)
            || (0xF900...0xFAFF).contains(v)
            || (0xFE10...0xFE19).contains(v)
            || (0xFE30...0xFE6F).contains(v)
            || (0xFF00...0xFF60).contains(v)
            || (0xFFE0...0xFFE6).contains(v)
            || (0x1F300...0x1FAFF).contains(v)
            || (0x20000...0x2FFFD).contains(v)
    }
}

// MARK: - POSIX PTY Process Controller

final class PTYProcessController: @unchecked Sendable {
    private let lock = NSLock()
    private let ioQueue = DispatchQueue(label: "dev.swiftflash.pty.io", qos: .userInitiated)
    private var masterFD: Int32 = -1
    private var childPID: pid_t = -1
    private var readSource: DispatchSourceRead?
    private var isClosed = false

    var onOutput: (@Sendable (Data) -> Void)?
    var onExit: (@Sendable (Int32) -> Void)?

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !isClosed && masterFD >= 0 && childPID > 0
    }

    func start(workingDirectory: URL, cols: Int, rows: Int) throws {
        stop()

        var ws = winsize(
            ws_row: UInt16(clamping: max(4, rows)),
            ws_col: UInt16(clamping: max(20, cols)),
            ws_xpixel: 0,
            ws_ypixel: 0
        )

        var fd: Int32 = -1
        let shellPath = ProcessInfo.processInfo.environment["SHELL"].flatMap {
            FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil
        } ?? "/bin/zsh"

        let envDict = ToolchainEnvironment.augmentedEnvironment(extraVariables: [
            "TERM": "xterm-256color",
            "COLORTERM": "truecolor",
            "LANG": ProcessInfo.processInfo.environment["LANG"] ?? "en_US.UTF-8",
            "LC_ALL": ProcessInfo.processInfo.environment["LC_ALL"] ?? "en_US.UTF-8",
            "TERM_PROGRAM": "SwiftFlash"
        ])
        let envStrings = envDict.map { "\($0.key)=\($0.value)" }
        let shellName = URL(fileURLWithPath: shellPath).lastPathComponent
        let argvStrings = ["-\(shellName)"]

        // Pre-allocate C strings before forkpty so child never touches Swift heap/locks.
        let cShell = strdup(shellPath)
        let cDir = strdup(workingDirectory.path)
        let cArgv: [UnsafeMutablePointer<CChar>?] = argvStrings.map { strdup($0) } + [nil]
        let cEnvp: [UnsafeMutablePointer<CChar>?] = envStrings.map { strdup($0) } + [nil]

        defer {
            free(cShell)
            free(cDir)
            for ptr in cArgv { free(ptr) }
            for ptr in cEnvp { free(ptr) }
        }

        let pid = forkpty(&fd, nil, nil, &ws)
        if pid < 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        if pid == 0 {
            // Child process: async-signal-safe calls only.
            if let cDir {
                _ = chdir(cDir)
            }
            if let cShell {
                execve(cShell, cArgv, cEnvp)
            }
            _exit(127)
        }

        // Parent process
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }

        lock.lock()
        masterFD = fd
        childPID = pid
        isClosed = false
        lock.unlock()

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: ioQueue)
        source.setEventHandler { [weak self] in
            self?.readAvailableBytes()
        }
        source.setCancelHandler { [fd] in
            Darwin.close(fd)
        }

        lock.lock()
        readSource = source
        lock.unlock()

        source.resume()
    }

    func write(_ data: Data) {
        guard !data.isEmpty else { return }
        ioQueue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let fd = self.masterFD
            let closed = self.isClosed
            self.lock.unlock()
            guard !closed, fd >= 0 else { return }

            data.withUnsafeBytes { rawBuf in
                guard let base = rawBuf.baseAddress else { return }
                var written = 0
                while written < data.count {
                    let n = Darwin.write(fd, base.advanced(by: written), data.count - written)
                    if n > 0 {
                        written += n
                    } else if errno == EINTR || errno == EAGAIN {
                        usleep(1000)
                    } else {
                        break
                    }
                }
            }
        }
    }

    func resize(cols: Int, rows: Int) {
        lock.lock()
        let fd = masterFD
        let pid = childPID
        let closed = isClosed
        lock.unlock()
        guard !closed, fd >= 0 else { return }

        var ws = winsize(
            ws_row: UInt16(clamping: max(4, rows)),
            ws_col: UInt16(clamping: max(20, cols)),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        _ = ioctl(fd, TIOCSWINSZ, &ws)
        if pid > 0 {
            _ = kill(-pid, SIGWINCH)
        }
    }

    func stop() {
        lock.lock()
        let pid = childPID
        let source = readSource
        let alreadyClosed = isClosed
        isClosed = true
        childPID = -1
        masterFD = -1
        readSource = nil
        lock.unlock()

        guard !alreadyClosed || source != nil || pid > 0 else { return }
        source?.cancel()

        if pid > 0 {
            _ = kill(-pid, SIGHUP)
            ProcessRunner.terminateProcessTree(rootPID: pid)
            var status: Int32 = 0
            _ = waitpid(pid, &status, WNOHANG)
        }
    }

    private func readAvailableBytes() {
        lock.lock()
        let fd = masterFD
        let closed = isClosed
        lock.unlock()
        guard !closed, fd >= 0 else { return }

        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                let chunk = Data(buffer[0..<count])
                onOutput?(chunk)
            } else if count == 0 {
                handleProcessExit()
                return
            } else {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    return
                }
                if errno == EINTR {
                    continue
                }
                handleProcessExit()
                return
            }
        }
    }

    private func handleProcessExit() {
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            return
        }
        isClosed = true
        let pid = childPID
        let source = readSource
        childPID = -1
        masterFD = -1
        readSource = nil
        lock.unlock()

        source?.cancel()
        var exitCode: Int32 = 0
        if pid > 0 {
            var status: Int32 = 0
            if waitpid(pid, &status, 0) > 0 {
                if (status & 0x7F) == 0 {
                    exitCode = (status >> 8) & 0xFF
                } else {
                    exitCode = 128 + (status & 0x7F)
                }
            }
        }
        onExit?(exitCode)
    }

    deinit {
        stop()
    }
}

// MARK: - PTY Terminal Tab Session

@MainActor
final class PTYTerminalTabSession: Identifiable, ObservableObject {
    let id = UUID()
    @Published var title: String
    @Published var currentDirectory: URL
    @Published var isAlive: Bool = false
    @Published var renderTick: UInt64 = 0

    let emulator: VT100TerminalEmulator
    private let pty = PTYProcessController()
    private var hasStarted = false

    init(workingDirectory: URL, title: String? = nil) {
        self.currentDirectory = workingDirectory.standardized
        self.title = title ?? workingDirectory.lastPathComponent
        self.emulator = VT100TerminalEmulator(cols: 100, rows: 24)

        emulator.onWriteBack = { [weak pty] data in
            pty?.write(data)
        }
        emulator.onTitleChanged = { [weak self] newTitle in
            let cleaned = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return }
            Task { @MainActor [weak self] in
                self?.title = cleaned
            }
        }
        emulator.onWorkingDirectoryChanged = { [weak self] newURL in
            Task { @MainActor [weak self] in
                self?.currentDirectory = newURL
            }
        }

        pty.onOutput = { [weak self] data in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.emulator.feed(data)
                self.renderTick &+= 1
            }
        }
        pty.onExit = { [weak self] code in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isAlive = false
                let msg = "\r\n\u{1B}[33m" + L10n("terminal.exitCodeFormat", Int(code)) + "\u{1B}[0m\r\n"
                self.emulator.feed(string: msg)
                self.renderTick &+= 1
            }
        }
    }

    func startIfNeeded(cols: Int = 100, rows: Int = 24) {
        guard !hasStarted else { return }
        hasStarted = true
        restart(cols: cols, rows: rows)
    }

    func restart(in directory: URL? = nil, cols: Int? = nil, rows: Int? = nil) {
        if let directory {
            currentDirectory = directory.standardized
            title = directory.lastPathComponent
        }
        let targetCols = cols ?? emulator.cols
        let targetRows = rows ?? emulator.rows
        emulator.resize(cols: targetCols, rows: targetRows)
        do {
            try pty.start(workingDirectory: currentDirectory, cols: targetCols, rows: targetRows)
            isAlive = true
            renderTick &+= 1
        } catch {
            isAlive = false
            emulator.feed(string: "\u{1B}[31m" + L10n("terminal.failedExecuteFormat", error.localizedDescription) + "\u{1B}[0m\r\n")
            renderTick &+= 1
        }
    }

    func sendInput(_ data: Data) {
        if !isAlive {
            restart()
        }
        pty.write(data)
    }

    func sendCommand(_ command: String) {
        startIfNeeded()
        if !isAlive {
            restart()
        }
        let payload = command.hasSuffix("\n") ? command : command + "\r"
        if let data = payload.data(using: .utf8) {
            pty.write(data)
        }
    }

    func sendInterrupt() {
        pty.write(Data([0x03]))
    }

    func clearScreen() {
        emulator.reset()
        renderTick &+= 1
        if isAlive {
            pty.write(Data([0x0C])) // Ctrl+L to redraw shell prompt cleanly
        }
    }

    func resize(cols: Int, rows: Int) {
        emulator.resize(cols: cols, rows: rows)
        if isAlive {
            pty.resize(cols: cols, rows: rows)
        }
        renderTick &+= 1
    }

    func shutdown() {
        pty.stop()
        isAlive = false
    }
}

// MARK: - Multi-Tab Terminal Manager

@MainActor
final class TerminalTabManager: ObservableObject {
    @Published var tabs: [PTYTerminalTabSession] = []
    @Published var activeTabID: UUID?

    var activeTab: PTYTerminalTabSession? {
        if let activeTabID, let found = tabs.first(where: { $0.id == activeTabID }) {
            return found
        }
        return tabs.first
    }

    init(workingDirectory: URL) {
        let initial = PTYTerminalTabSession(workingDirectory: workingDirectory)
        self.tabs = [initial]
        self.activeTabID = initial.id
    }

    @discardableResult
    func createTab(in directory: URL) -> PTYTerminalTabSession {
        let tab = PTYTerminalTabSession(workingDirectory: directory)
        tabs.append(tab)
        activeTabID = tab.id
        return tab
    }

    func closeTab(id: UUID, fallbackDirectory: URL) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[idx].shutdown()
        tabs.remove(at: idx)
        if tabs.isEmpty {
            let fresh = PTYTerminalTabSession(workingDirectory: fallbackDirectory)
            tabs = [fresh]
            activeTabID = fresh.id
        } else if activeTabID == id {
            activeTabID = tabs[min(idx, tabs.count - 1)].id
        }
    }

    func syncWorkspaceDirectory(_ url: URL) {
        guard let tab = activeTab else { return }
        let std = url.standardized
        if tab.currentDirectory.standardized.path != std.path {
            tab.currentDirectory = std
            tab.title = std.lastPathComponent
            if tab.isAlive {
                let quoted = ProjectTaskDetector.shellQuoted(std.path)
                tab.sendCommand("cd \(quoted)")
            }
        }
    }

    func shutdownAll() {
        for tab in tabs {
            tab.shutdown()
        }
    }
}

// MARK: - Native AppKit CoreText PTY View

@MainActor
final class PTYTerminalNSView: NSView, @preconcurrency NSTextInputClient {
    weak var session: PTYTerminalTabSession? {
        didSet {
            if oldValue !== session {
                scrollOffsetRows = 0
                selectionStart = nil
                selectionEnd = nil
                rebindSession()
            }
        }
    }

    private var sessionCancellable: AnyCancellable?
    private var themeCancellables: Set<AnyCancellable> = []

    private var terminalFont: NSFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private var boldTerminalFont: NSFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
    private var cellWidth: CGFloat = 7.5
    private var cellHeight: CGFloat = 17.0
    private var fontAscent: CGFloat = 11.0
    private let paddingX: CGFloat = 10
    private let paddingY: CGFloat = 6

    private var scrollOffsetRows: Int = 0
    private var selectionStart: (row: Int, col: Int)?
    private var selectionEnd: (row: Int, col: Int)?
    private var markedTextStorage = NSMutableAttributedString()

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        updateFontMetrics()
        observeTheme()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func observeTheme() {
        let tm = ThemeManager.shared
        tm.$currentThemeID
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.needsDisplay = true }
            .store(in: &themeCancellables)
        tm.$editorFontFamily
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateFontMetrics()
                self?.syncGridSizeToBounds()
                self?.needsDisplay = true
            }
            .store(in: &themeCancellables)
        tm.$editorFontSize
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateFontMetrics()
                self?.syncGridSizeToBounds()
                self?.needsDisplay = true
            }
            .store(in: &themeCancellables)
    }

    private func rebindSession() {
        sessionCancellable?.cancel()
        guard let session else { return }
        sessionCancellable = session.$renderTick
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                if self.session?.emulator.isUsingAlternateScreen == true {
                    self.scrollOffsetRows = 0
                }
                self.needsDisplay = true
            }
        syncGridSizeToBounds()
        let (cols, rows) = computedGridDimensions()
        session.startIfNeeded(cols: cols, rows: rows)
        needsDisplay = true
    }

    private func updateFontMetrics() {
        let size = max(11, ThemeManager.shared.editorFontSize - 1)
        let base = ThemeManager.shared.editorFont(size: size)
        terminalFont = base
        boldTerminalFont = NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)

        let sample = NSAttributedString(string: "W", attributes: [.font: base])
        let line = CTLineCreateWithAttributedString(sample)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        cellWidth = max(6.0, ceil(width * 2.0) / 2.0)
        fontAscent = ascent
        cellHeight = max(14.0, ceil((ascent + descent + leading) * 1.25))
    }

    private func computedGridDimensions() -> (cols: Int, rows: Int) {
        let usableW = max(120, bounds.width - paddingX * 2)
        let usableH = max(48, bounds.height - paddingY * 2)
        let cols = max(20, Int(floor(usableW / cellWidth)))
        let rows = max(4, Int(floor(usableH / cellHeight)))
        return (cols, rows)
    }

    private func syncGridSizeToBounds() {
        guard bounds.width > 40, bounds.height > 30, let session else { return }
        let (cols, rows) = computedGridDimensions()
        if cols != session.emulator.cols || rows != session.emulator.rows {
            session.resize(cols: cols, rows: rows)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        syncGridSizeToBounds()
    }

    override func layout() {
        super.layout()
        syncGridSizeToBounds()
    }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    // MARK: - Mouse & Scrollback

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let pt = convert(event.locationInWindow, from: nil)
        let coord = cellCoordinate(at: pt)
        selectionStart = coord
        selectionEnd = coord
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        selectionEnd = cellCoordinate(at: pt)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if selectionStart?.row == selectionEnd?.row && selectionStart?.col == selectionEnd?.col {
            selectionStart = nil
            selectionEnd = nil
            needsDisplay = true
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard let emulator = session?.emulator else { return }
        if emulator.isUsingAlternateScreen {
            // Forward scroll as arrow keys inside TUI apps like less/vim.
            let lines = max(1, Int(abs(event.scrollingDeltaY) / 14))
            let seq = event.scrollingDeltaY > 0 ? "\u{1B}[A" : "\u{1B}[B"
            if let data = String(repeating: seq, count: min(lines, 5)).data(using: .utf8) {
                session?.sendInput(data)
            }
            return
        }
        let maxScroll = emulator.scrollback.count
        guard maxScroll > 0 else {
            scrollOffsetRows = 0
            return
        }
        let delta = event.hasPreciseScrollingDeltas
            ? Int(round(event.scrollingDeltaY / max(4.0, cellHeight * 0.6)))
            : Int(round(event.scrollingDeltaY * 3))
        if delta != 0 {
            scrollOffsetRows = max(0, min(maxScroll, scrollOffsetRows + delta))
            needsDisplay = true
        }
    }

    private func cellCoordinate(at point: NSPoint) -> (row: Int, col: Int) {
        guard let emulator = session?.emulator else { return (0, 0) }
        let visRow = max(0, min(emulator.rows - 1, Int(floor((point.y - paddingY) / cellHeight))))
        let col = max(0, min(emulator.cols - 1, Int(floor((point.x - paddingX) / cellWidth))))
        let topCombinedRow = max(0, emulator.scrollback.count - scrollOffsetRows)
        return (topCombinedRow + visRow, col)
    }

    private func normalizedSelection() -> (start: (row: Int, col: Int), end: (row: Int, col: Int))? {
        guard let a = selectionStart, let b = selectionEnd else { return nil }
        if a.row < b.row || (a.row == b.row && a.col <= b.col) {
            return (a, b)
        }
        return (b, a)
    }

    private func selectedPlainText() -> String? {
        guard let sel = normalizedSelection(), let emulator = session?.emulator else { return nil }
        var lines: [String] = []
        for r in sel.start.row...sel.end.row {
            let row = emulator.rowAtCombinedIndex(r)
            let c0 = (r == sel.start.row) ? sel.start.col : 0
            let c1 = (r == sel.end.row) ? min(sel.end.col, row.count - 1) : row.count - 1
            guard c0 <= c1, c0 < row.count else {
                lines.append("")
                continue
            }
            var s = ""
            for c in c0...c1 where row[c].width != 0 {
                s.append(row[c].char)
            }
            while s.last == " " { s.removeLast() }
            lines.append(s)
        }
        let result = lines.joined(separator: "\n")
        return result.isEmpty ? nil : result
    }

    // MARK: - Keyboard & Clipboard

    @objc func copy(_ sender: Any?) {
        if let text = selectedPlainText() {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    @objc func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        scrollOffsetRows = 0
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r")
        let payload: String
        if session?.emulator.bracketedPasteMode == true {
            payload = "\u{1B}[200~" + normalized + "\u{1B}[201~"
        } else {
            payload = normalized
        }
        if let data = payload.data(using: .utf8) {
            session?.sendInput(data)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""

        if flags == .command {
            if chars == "c", selectedPlainText() != nil {
                copy(nil)
                return true
            }
            if chars == "v" {
                paste(nil)
                return true
            }
            if chars == "k" {
                session?.clearScreen()
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        guard let session else { return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if flags.contains(.command) {
            super.keyDown(with: event)
            return
        }

        scrollOffsetRows = 0
        selectionStart = nil
        selectionEnd = nil

        // Control key combinations (Ctrl+A..Z, Ctrl+[, Ctrl+\, Ctrl+], Ctrl+Space)
        if flags.contains(.control), let raw = event.charactersIgnoringModifiers?.first {
            if let ctrlByte = Self.controlByte(for: raw) {
                session.sendInput(Data([ctrlByte]))
                return
            }
        }

        let appCursor = session.emulator.applicationCursorKeys
        switch Int(event.keyCode) {
        case 36, 76: // Return / Enter
            session.sendInput(Data([0x0D]))
            return
        case 51: // Backspace
            session.sendInput(Data([0x7F]))
            return
        case 117: // Forward Delete
            session.sendInput(Data("\u{1B}[3~".utf8))
            return
        case 48: // Tab / Shift+Tab
            session.sendInput(flags.contains(.shift) ? Data("\u{1B}[Z".utf8) : Data([0x09]))
            return
        case 53: // Escape
            session.sendInput(Data([0x1B]))
            return
        case 126: // Up
            session.sendInput(Data((appCursor ? "\u{1B}OA" : "\u{1B}[A").utf8))
            return
        case 125: // Down
            session.sendInput(Data((appCursor ? "\u{1B}OB" : "\u{1B}[B").utf8))
            return
        case 124: // Right
            session.sendInput(Data((appCursor ? "\u{1B}OC" : "\u{1B}[C").utf8))
            return
        case 123: // Left
            session.sendInput(Data((appCursor ? "\u{1B}OD" : "\u{1B}[D").utf8))
            return
        case 115: // Home
            session.sendInput(Data((appCursor ? "\u{1B}OH" : "\u{1B}[H").utf8))
            return
        case 119: // End
            session.sendInput(Data((appCursor ? "\u{1B}OF" : "\u{1B}[F").utf8))
            return
        case 116: // PageUp
            session.sendInput(Data("\u{1B}[5~".utf8))
            return
        case 121: // PageDown
            session.sendInput(Data("\u{1B}[6~".utf8))
            return
        default:
            break
        }

        interpretKeyEvents([event])
    }

    private static func controlByte(for ch: Character) -> UInt8? {
        guard let ascii = ch.asciiValue else { return nil }
        switch ascii {
        case 0x61...0x7A: return ascii - 0x60 // a-z -> 1...26
        case 0x41...0x5A: return ascii - 0x40 // A-Z -> 1...26
        case 0x20, 0x40: return 0x00          // Space / @
        case 0x5B: return 0x1B                // [
        case 0x5C: return 0x1C                // \
        case 0x5D: return 0x1D                // ]
        case 0x5E: return 0x1E                // ^
        case 0x5F: return 0x1F                // _
        default: return nil
        }
    }

    // MARK: - NSTextInputClient (IME Support)

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text: String
        if let s = string as? String {
            text = s
        } else if let a = string as? NSAttributedString {
            text = a.string
        } else {
            return
        }
        markedTextStorage = NSMutableAttributedString()
        if let data = text.data(using: .utf8) {
            session?.sendInput(data)
        }
        needsDisplay = true
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if let s = string as? String {
            markedTextStorage = NSMutableAttributedString(string: s)
        } else if let a = string as? NSAttributedString {
            markedTextStorage = NSMutableAttributedString(attributedString: a)
        }
        needsDisplay = true
    }

    func unmarkText() {
        markedTextStorage = NSMutableAttributedString()
        needsDisplay = true
    }

    func selectedRange() -> NSRange { NSRange(location: 0, length: 0) }
    func markedRange() -> NSRange {
        markedTextStorage.length > 0 ? NSRange(location: 0, length: markedTextStorage.length) : NSRange(location: NSNotFound, length: 0)
    }
    func hasMarkedText() -> Bool { markedTextStorage.length > 0 }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func characterIndex(for point: NSPoint) -> Int { 0 }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let emulator = session?.emulator, let window else { return .zero }
        let localRect = NSRect(
            x: paddingX + CGFloat(emulator.cursorCol) * cellWidth,
            y: paddingY + CGFloat(emulator.cursorRow) * cellHeight,
            width: cellWidth,
            height: cellHeight
        )
        let inWindow = convert(localRect, to: nil)
        return window.convertToScreen(inWindow)
    }

    override func doCommand(by selector: Selector) {
        // Handled explicitly in keyDown so NSBeep does not fire.
    }

    // MARK: - CoreText Rendering

    override func draw(_ dirtyRect: NSRect) {
        let bgColor = ZedTheme.background
        bgColor.setFill()
        dirtyRect.fill()

        guard let emulator = session?.emulator,
              let ctx = NSGraphicsContext.current?.cgContext else { return }

        let topCombinedRow = max(0, emulator.scrollback.count - scrollOffsetRows)
        let sel = normalizedSelection()
        let isFocused = (window?.firstResponder === self)

        for visRow in 0..<emulator.rows {
            let combinedIdx = topCombinedRow + visRow
            let y = paddingY + CGFloat(visRow) * cellHeight
            if y + cellHeight < dirtyRect.minY || y > dirtyRect.maxY {
                continue
            }

            let rowCells = emulator.rowAtCombinedIndex(combinedIdx)
            let colCount = min(emulator.cols, rowCells.count)

            // 1. Background & Selection cells
            for col in 0..<colCount {
                let cell = rowCells[col]
                let isSelected = Self.isCellSelected(row: combinedIdx, col: col, selection: sel)
                let cellBg: NSColor
                if isSelected {
                    cellBg = ZedTheme.selectionBackground
                } else if cell.attrs.inverse {
                    cellBg = cell.attrs.fg.resolveNSColor(isForeground: true)
                } else if cell.attrs.bg != .defaultBackground {
                    cellBg = cell.attrs.bg.resolveNSColor(isForeground: false)
                } else {
                    continue
                }
                cellBg.setFill()
                let spanW = cellWidth * CGFloat(max(1, Int(cell.width)))
                NSRect(x: paddingX + CGFloat(col) * cellWidth, y: y, width: spanW, height: cellHeight).fill()
            }

            // 2. Run-batched foreground glyph drawing for fast 120Hz rendering
            var col = 0
            while col < colCount {
                let cell = rowCells[col]
                if cell.width == 0 || (cell.char == " " && !cell.attrs.underline) {
                    col += 1
                    continue
                }

                let startCol = col
                let startAttrs = cell.attrs
                let isSelected = Self.isCellSelected(row: combinedIdx, col: col, selection: sel)
                var textRun = String(cell.char)
                var advanceCols = Int(max(1, cell.width))
                col += advanceCols

                if cell.width == 1 {
                    while col < colCount {
                        let next = rowCells[col]
                        if next.width != 1 || next.attrs != startAttrs
                            || Self.isCellSelected(row: combinedIdx, col: col, selection: sel) != isSelected {
                            break
                        }
                        textRun.append(next.char)
                        advanceCols += 1
                        col += 1
                    }
                }

                let fgColor: NSColor
                if startAttrs.inverse && !isSelected {
                    fgColor = startAttrs.bg.resolveNSColor(isForeground: false)
                } else {
                    fgColor = startAttrs.fg.resolveNSColor(isForeground: true)
                }

                let font = startAttrs.bold ? boldTerminalFont : terminalFont
                var drawAttrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: fgColor
                ]
                if startAttrs.underline {
                    drawAttrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
                }

                let ctLine = CTLineCreateWithAttributedString(NSAttributedString(string: textRun, attributes: drawAttrs))
                let drawX = paddingX + CGFloat(startCol) * cellWidth
                let baselineY = y + fontAscent + (cellHeight - (fontAscent + abs(font.descender))) / 2.0

                ctx.saveGState()
                ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
                ctx.textPosition = CGPoint(x: drawX, y: baselineY)
                CTLineDraw(ctLine, ctx)
                ctx.restoreGState()
            }
        }

        // 3. Cursor rendering (only when viewing live bottom)
        if scrollOffsetRows == 0 && emulator.cursorVisible {
            let cx = paddingX + CGFloat(emulator.cursorCol) * cellWidth
            let cy = paddingY + CGFloat(emulator.cursorRow) * cellHeight
            let cursorRect = NSRect(x: cx, y: cy + 1, width: max(2, cellWidth), height: max(12, cellHeight - 2))
            if isFocused {
                ZedTheme.cursor.withAlphaComponent(0.75).setFill()
                cursorRect.fill()
            } else {
                ZedTheme.cursor.withAlphaComponent(0.6).setStroke()
                let path = NSBezierPath(rect: cursorRect.insetBy(dx: 0.5, dy: 0.5))
                path.lineWidth = 1
                path.stroke()
            }
        }

        // 4. IME composition overlay if typing CJK
        if markedTextStorage.length > 0 {
            let cx = paddingX + CGFloat(emulator.cursorCol) * cellWidth
            let cy = paddingY + CGFloat(emulator.cursorRow) * cellHeight
            let text = markedTextStorage.string
            let attrs: [NSAttributedString.Key: Any] = [
                .font: terminalFont,
                .foregroundColor: ZedTheme.primaryText,
                .backgroundColor: ZedTheme.activeTabBackground,
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ]
            (text as NSString).draw(at: NSPoint(x: cx, y: cy), withAttributes: attrs)
        }
    }

    private static func isCellSelected(
        row: Int,
        col: Int,
        selection: (start: (row: Int, col: Int), end: (row: Int, col: Int))?
    ) -> Bool {
        guard let sel = selection else { return false }
        if row < sel.start.row || row > sel.end.row { return false }
        if row == sel.start.row && col < sel.start.col { return false }
        if row == sel.end.row && col > sel.end.col { return false }
        return true
    }
}

// MARK: - SwiftUI Bridge for PTYTerminalNSView

struct PTYTerminalRepresentable: NSViewRepresentable {
    @ObservedObject var session: PTYTerminalTabSession

    func makeNSView(context: Context) -> PTYTerminalNSView {
        let view = PTYTerminalNSView()
        view.session = session
        return view
    }

    func updateNSView(_ nsView: PTYTerminalNSView, context: Context) {
        if nsView.session !== session {
            nsView.session = session
        }
    }
}
