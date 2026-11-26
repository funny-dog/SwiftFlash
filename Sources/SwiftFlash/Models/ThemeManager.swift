import AppKit
import Combine
import Foundation
import SwiftUI

// MARK: - Theme Identifiers

enum ThemeID: String, CaseIterable, Identifiable, Sendable {
    case zedOneDark = "Zed One Dark"
    case zedGruvboxLight = "Zed Gruvbox Light"
    case zedOneLight = "Zed One Light"
    case tokyoNight = "Tokyo Night"
    case catppuccinMocha = "Catppuccin Mocha"
    case githubDarkDimmed = "GitHub Dark Dimmed"

    var id: String { rawValue }
}

// MARK: - Theme Palette (Sendable Hex Definition)

struct ThemePalette: Sendable, Equatable {
    let id: ThemeID
    let isDark: Bool

    let backgroundHex: UInt32
    let sidebarBackgroundHex: UInt32
    let tabBarBackgroundHex: UInt32
    let activeTabBackgroundHex: UInt32
    let statusBarBackgroundHex: UInt32
    let gutterBackgroundHex: UInt32
    let borderHex: UInt32

    let activeLineBackgroundHex: UInt32
    let selectionBackgroundHex: UInt32
    let cursorHex: UInt32

    let primaryTextHex: UInt32
    let secondaryTextHex: UInt32
    let mutedTextHex: UInt32
    let hoverBackgroundHex: UInt32
    let pillBackgroundHex: UInt32
    let pillTextHex: UInt32

    let plainTextHex: UInt32
    let gutterTextHex: UInt32
    let gutterActiveTextHex: UInt32

    let keywordHex: UInt32
    let typeNameHex: UInt32
    let functionHex: UInt32
    let stringHex: UInt32
    let commentHex: UInt32
    let numberHex: UInt32
    let attributeHex: UInt32
    let operatorHex: UInt32

    var previewSwatches: [UInt32] {
        [backgroundHex, sidebarBackgroundHex, pillBackgroundHex, functionHex, keywordHex, stringHex]
    }

    static func palette(for id: ThemeID) -> ThemePalette {
        switch id {
        case .zedOneDark:
            return ThemePalette(
                id: .zedOneDark,
                isDark: true,
                backgroundHex: 0x181A1F,
                sidebarBackgroundHex: 0x1E2127,
                tabBarBackgroundHex: 0x1B1E23,
                activeTabBackgroundHex: 0x23272F,
                statusBarBackgroundHex: 0x1B1E23,
                gutterBackgroundHex: 0x181A1F,
                borderHex: 0x2C313A,
                activeLineBackgroundHex: 0x232730,
                selectionBackgroundHex: 0x3A4354,
                cursorHex: 0x528BFF,
                primaryTextHex: 0xECEFF4,
                secondaryTextHex: 0xABB2BF,
                mutedTextHex: 0x6B7280,
                hoverBackgroundHex: 0x282C34,
                pillBackgroundHex: 0x2B3A4E,
                pillTextHex: 0x79C0FF,
                plainTextHex: 0xABB2BF,
                gutterTextHex: 0x4B5263,
                gutterActiveTextHex: 0xC8CCD4,
                keywordHex: 0xC678DD,
                typeNameHex: 0xE5C07B,
                functionHex: 0x61AFEF,
                stringHex: 0x98C379,
                commentHex: 0x5C6370,
                numberHex: 0xD19A66,
                attributeHex: 0xE06C75,
                operatorHex: 0x56B6C2
            )

        case .zedGruvboxLight:
            return ThemePalette(
                id: .zedGruvboxLight,
                isDark: false,
                backgroundHex: 0xF2E5BC,
                sidebarBackgroundHex: 0xEDE0B8,
                tabBarBackgroundHex: 0xE7DAB0,
                activeTabBackgroundHex: 0xF2E5BC,
                statusBarBackgroundHex: 0xE7DAB0,
                gutterBackgroundHex: 0xF2E5BC,
                borderHex: 0xD5C4A1,
                activeLineBackgroundHex: 0xE7D7A9,
                selectionBackgroundHex: 0xC9B996,
                cursorHex: 0x076678,
                primaryTextHex: 0x282828,
                secondaryTextHex: 0x504945,
                mutedTextHex: 0x7C6F64,
                hoverBackgroundHex: 0xDFD0A5,
                pillBackgroundHex: 0xB5D4D8,
                pillTextHex: 0x076678,
                plainTextHex: 0x282828,
                gutterTextHex: 0x928374,
                gutterActiveTextHex: 0x3C3836,
                keywordHex: 0x9D0006,
                typeNameHex: 0xB57614,
                functionHex: 0x076678,
                stringHex: 0x79740E,
                commentHex: 0x928374,
                numberHex: 0x8F3F71,
                attributeHex: 0xAF3A03,
                operatorHex: 0x427B58
            )

        case .zedOneLight:
            return ThemePalette(
                id: .zedOneLight,
                isDark: false,
                backgroundHex: 0xFAFAFA,
                sidebarBackgroundHex: 0xF2F3F5,
                tabBarBackgroundHex: 0xEAECEF,
                activeTabBackgroundHex: 0xFAFAFA,
                statusBarBackgroundHex: 0xEAECEF,
                gutterBackgroundHex: 0xFAFAFA,
                borderHex: 0xDCDEE3,
                activeLineBackgroundHex: 0xF0F1F4,
                selectionBackgroundHex: 0xD5E2F6,
                cursorHex: 0x4078F2,
                primaryTextHex: 0x24292F,
                secondaryTextHex: 0x57606A,
                mutedTextHex: 0x8C959F,
                hoverBackgroundHex: 0xE4E7EC,
                pillBackgroundHex: 0xDCE8FC,
                pillTextHex: 0x1B5BD6,
                plainTextHex: 0x383A42,
                gutterTextHex: 0x9D9D9F,
                gutterActiveTextHex: 0x383A42,
                keywordHex: 0xA626A4,
                typeNameHex: 0xC18401,
                functionHex: 0x4078F2,
                stringHex: 0x50A14F,
                commentHex: 0xA0A1A7,
                numberHex: 0x986801,
                attributeHex: 0xE45649,
                operatorHex: 0x0184BC
            )

        case .tokyoNight:
            return ThemePalette(
                id: .tokyoNight,
                isDark: true,
                backgroundHex: 0x1A1B26,
                sidebarBackgroundHex: 0x16161E,
                tabBarBackgroundHex: 0x16161E,
                activeTabBackgroundHex: 0x1F2335,
                statusBarBackgroundHex: 0x16161E,
                gutterBackgroundHex: 0x1A1B26,
                borderHex: 0x292E42,
                activeLineBackgroundHex: 0x24283B,
                selectionBackgroundHex: 0x33467C,
                cursorHex: 0x7AA2F7,
                primaryTextHex: 0xC0CAF5,
                secondaryTextHex: 0x9AA5CE,
                mutedTextHex: 0x565F89,
                hoverBackgroundHex: 0x24283B,
                pillBackgroundHex: 0x283457,
                pillTextHex: 0x7AA2F7,
                plainTextHex: 0xC0CAF5,
                gutterTextHex: 0x444B6A,
                gutterActiveTextHex: 0xA9B1D6,
                keywordHex: 0xBB9AF7,
                typeNameHex: 0xE0AF68,
                functionHex: 0x7AA2F7,
                stringHex: 0x9ECE6A,
                commentHex: 0x565F89,
                numberHex: 0xFF9E64,
                attributeHex: 0xF7768E,
                operatorHex: 0x7DCFFF
            )

        case .catppuccinMocha:
            return ThemePalette(
                id: .catppuccinMocha,
                isDark: true,
                backgroundHex: 0x1E1E2E,
                sidebarBackgroundHex: 0x181825,
                tabBarBackgroundHex: 0x181825,
                activeTabBackgroundHex: 0x252538,
                statusBarBackgroundHex: 0x11111B,
                gutterBackgroundHex: 0x1E1E2E,
                borderHex: 0x313244,
                activeLineBackgroundHex: 0x262637,
                selectionBackgroundHex: 0x45475A,
                cursorHex: 0x89B4FA,
                primaryTextHex: 0xCDD6F4,
                secondaryTextHex: 0xBAC2DE,
                mutedTextHex: 0x6C7086,
                hoverBackgroundHex: 0x2A2B3D,
                pillBackgroundHex: 0x2E3B59,
                pillTextHex: 0x89B4FA,
                plainTextHex: 0xCDD6F4,
                gutterTextHex: 0x585B70,
                gutterActiveTextHex: 0xCDD6F4,
                keywordHex: 0xCBA6F7,
                typeNameHex: 0xF9E2AF,
                functionHex: 0x89B4FA,
                stringHex: 0xA6E3A1,
                commentHex: 0x6C7086,
                numberHex: 0xFAB387,
                attributeHex: 0xF38BA8,
                operatorHex: 0x94E2D5
            )

        case .githubDarkDimmed:
            return ThemePalette(
                id: .githubDarkDimmed,
                isDark: true,
                backgroundHex: 0x22272E,
                sidebarBackgroundHex: 0x1C2128,
                tabBarBackgroundHex: 0x1C2128,
                activeTabBackgroundHex: 0x2D333B,
                statusBarBackgroundHex: 0x1C2128,
                gutterBackgroundHex: 0x22272E,
                borderHex: 0x373E47,
                activeLineBackgroundHex: 0x2A3038,
                selectionBackgroundHex: 0x3A4A5E,
                cursorHex: 0x539BF5,
                primaryTextHex: 0xADBAC7,
                secondaryTextHex: 0x909DAB,
                mutedTextHex: 0x636E7B,
                hoverBackgroundHex: 0x2D333B,
                pillBackgroundHex: 0x293D57,
                pillTextHex: 0x6CB6FF,
                plainTextHex: 0xADBAC7,
                gutterTextHex: 0x545D68,
                gutterActiveTextHex: 0xCDD9E5,
                keywordHex: 0xF47067,
                typeNameHex: 0xF69D50,
                functionHex: 0xDCBDFB,
                stringHex: 0x96D0FF,
                commentHex: 0x768390,
                numberHex: 0x6CB6FF,
                attributeHex: 0xF47067,
                operatorHex: 0x6CB6FF
            )
        }
    }
}

// MARK: - Cached NSColor Palette

@MainActor
struct ResolvedThemeColors {
    let palette: ThemePalette
    let background: NSColor
    let sidebarBackground: NSColor
    let tabBarBackground: NSColor
    let activeTabBackground: NSColor
    let statusBarBackground: NSColor
    let gutterBackground: NSColor
    let border: NSColor

    let activeLineBackground: NSColor
    let selectionBackground: NSColor
    let cursor: NSColor

    let primaryText: NSColor
    let secondaryText: NSColor
    let mutedText: NSColor
    let hoverBackground: NSColor
    let pillBackground: NSColor
    let pillText: NSColor

    let plainText: NSColor
    let gutterText: NSColor
    let gutterActiveText: NSColor

    let keyword: NSColor
    let typeName: NSColor
    let function: NSColor
    let string: NSColor
    let comment: NSColor
    let number: NSColor
    let attribute: NSColor
    let operatorColor: NSColor

    let tokenColorLookup: [UInt32: NSColor]

    init(palette: ThemePalette) {
        self.palette = palette
        self.background = NSColor(hex: palette.backgroundHex)
        self.sidebarBackground = NSColor(hex: palette.sidebarBackgroundHex)
        self.tabBarBackground = NSColor(hex: palette.tabBarBackgroundHex)
        self.activeTabBackground = NSColor(hex: palette.activeTabBackgroundHex)
        self.statusBarBackground = NSColor(hex: palette.statusBarBackgroundHex)
        self.gutterBackground = NSColor(hex: palette.gutterBackgroundHex)
        self.border = NSColor(hex: palette.borderHex)

        self.activeLineBackground = NSColor(hex: palette.activeLineBackgroundHex)
        self.selectionBackground = NSColor(hex: palette.selectionBackgroundHex)
        self.cursor = NSColor(hex: palette.cursorHex)

        self.primaryText = NSColor(hex: palette.primaryTextHex)
        self.secondaryText = NSColor(hex: palette.secondaryTextHex)
        self.mutedText = NSColor(hex: palette.mutedTextHex)
        self.hoverBackground = NSColor(hex: palette.hoverBackgroundHex)
        self.pillBackground = NSColor(hex: palette.pillBackgroundHex)
        self.pillText = NSColor(hex: palette.pillTextHex)

        self.plainText = NSColor(hex: palette.plainTextHex)
        self.gutterText = NSColor(hex: palette.gutterTextHex)
        self.gutterActiveText = NSColor(hex: palette.gutterActiveTextHex)

        self.keyword = NSColor(hex: palette.keywordHex)
        self.typeName = NSColor(hex: palette.typeNameHex)
        self.function = NSColor(hex: palette.functionHex)
        self.string = NSColor(hex: palette.stringHex)
        self.comment = NSColor(hex: palette.commentHex)
        self.number = NSColor(hex: palette.numberHex)
        self.attribute = NSColor(hex: palette.attributeHex)
        self.operatorColor = NSColor(hex: palette.operatorHex)

        self.tokenColorLookup = [
            palette.plainTextHex: plainText,
            palette.keywordHex: keyword,
            palette.typeNameHex: typeName,
            palette.functionHex: function,
            palette.stringHex: string,
            palette.commentHex: comment,
            palette.numberHex: number,
            palette.attributeHex: attribute,
            palette.operatorHex: operatorColor
        ]
    }
}

// MARK: - Theme & Font Manager

@MainActor
final class ThemeManager: ObservableObject {
    static let shared = ThemeManager()

    private enum Keys {
        static let themeID = "swiftflash.themeID"
        static let editorFontFamily = "swiftflash.editorFontFamily"
        static let editorFontSize = "swiftflash.editorFontSize"
        static let lineHeightMultiplier = "swiftflash.lineHeightMultiplier"
        static let uiFontSize = "swiftflash.uiFontSize"
    }

    private static let preferredFontOrder = [
        "JetBrains Mono",
        "SF Mono",
        "Menlo",
        "Monaco",
        "Fira Code",
        "Hack",
        "Cascadia Code",
        "Iosevka",
        "Courier New",
        "System Monospace"
    ]

    @Published var currentThemeID: ThemeID {
        didSet {
            resolvedColors = ResolvedThemeColors(palette: ThemePalette.palette(for: currentThemeID))
            UserDefaults.standard.set(currentThemeID.rawValue, forKey: Keys.themeID)
        }
    }

    @Published var editorFontFamily: String {
        didSet {
            UserDefaults.standard.set(editorFontFamily, forKey: Keys.editorFontFamily)
        }
    }

    @Published var editorFontSize: CGFloat {
        didSet {
            let clamped = min(max(editorFontSize, 10), 24)
            if clamped != editorFontSize {
                editorFontSize = clamped
                return
            }
            UserDefaults.standard.set(Double(clamped), forKey: Keys.editorFontSize)
        }
    }

    @Published var lineHeightMultiplier: CGFloat {
        didSet {
            let clamped = min(max(lineHeightMultiplier, 1.1), 1.8)
            if clamped != lineHeightMultiplier {
                lineHeightMultiplier = clamped
                return
            }
            UserDefaults.standard.set(Double(clamped), forKey: Keys.lineHeightMultiplier)
        }
    }

    @Published var uiFontSize: CGFloat {
        didSet {
            let clamped = min(max(uiFontSize, 11), 16)
            if clamped != uiFontSize {
                uiFontSize = clamped
                return
            }
            UserDefaults.standard.set(Double(clamped), forKey: Keys.uiFontSize)
        }
    }

    private(set) var resolvedColors: ResolvedThemeColors

    /// Lazily enumerates fixed-pitch system fonts on first access (e.g. when opening Settings)
    /// instead of instantiating hundreds of NSFonts synchronously during app startup.
    lazy var availableMonospacedFonts: [String] = {
        let fontManager = NSFontManager.shared
        var fontList: [String] = []
        var seen = Set<String>()

        for candidate in Self.preferredFontOrder {
            if candidate == "System Monospace" || NSFont(name: candidate, size: 13) != nil {
                if seen.insert(candidate).inserted {
                    fontList.append(candidate)
                }
            }
        }

        // Fast query: only inspect fonts matching fixedPitchFontMask instead of all system families.
        let fixedPitchPostScriptNames = fontManager.availableFontNames(with: .fixedPitchFontMask) ?? []
        var discoveredFamilies = Set<String>()
        for psName in fixedPitchPostScriptNames {
            if let family = NSFont(name: psName, size: 13)?.familyName {
                discoveredFamilies.insert(family)
            }
        }
        for family in discoveredFamilies.sorted() where seen.insert(family).inserted {
            fontList.append(family)
        }
        return fontList
    }()

    var palette: ThemePalette {
        resolvedColors.palette
    }

    var editorFont: NSFont {
        editorFont(size: editorFontSize)
    }

    func editorFont(size: CGFloat) -> NSFont {
        if editorFontFamily == "System Monospace" {
            return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }
        return NSFont(name: editorFontFamily, size: size)
            ?? NSFont(name: "SF Mono", size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    func editorSwiftUIFont(size: CGFloat) -> Font {
        if editorFontFamily == "System Monospace" {
            return .system(size: size, design: .monospaced)
        }
        if let nsFont = NSFont(name: editorFontFamily, size: size) {
            return Font(nsFont)
        }
        return .system(size: size, design: .monospaced)
    }

    private init() {
        let defaults = UserDefaults.standard
        let initialTheme: ThemeID
        if let savedTheme = defaults.string(forKey: Keys.themeID),
           let parsedTheme = ThemeID(rawValue: savedTheme) {
            initialTheme = parsedTheme
        } else {
            initialTheme = .zedOneDark
        }
        self.currentThemeID = initialTheme
        self.resolvedColors = ResolvedThemeColors(palette: ThemePalette.palette(for: initialTheme))

        if let savedFamily = defaults.string(forKey: Keys.editorFontFamily),
           savedFamily == "System Monospace" || NSFont(name: savedFamily, size: 13) != nil {
            self.editorFontFamily = savedFamily
        } else if NSFont(name: "JetBrains Mono", size: 13) != nil {
            self.editorFontFamily = "JetBrains Mono"
        } else if NSFont(name: "SF Mono", size: 13) != nil {
            self.editorFontFamily = "SF Mono"
        } else {
            self.editorFontFamily = Self.preferredFontOrder.first(where: {
                $0 == "System Monospace" || NSFont(name: $0, size: 13) != nil
            }) ?? "System Monospace"
        }

        let savedSize = defaults.double(forKey: Keys.editorFontSize)
        self.editorFontSize = savedSize >= 10 && savedSize <= 24 ? CGFloat(savedSize) : 13.0

        let savedLineHeight = defaults.double(forKey: Keys.lineHeightMultiplier)
        self.lineHeightMultiplier = savedLineHeight >= 1.1 && savedLineHeight <= 1.8 ? CGFloat(savedLineHeight) : 1.38

        let savedUIFontSize = defaults.double(forKey: Keys.uiFontSize)
        self.uiFontSize = savedUIFontSize >= 11 && savedUIFontSize <= 16 ? CGFloat(savedUIFontSize) : 12.5
    }

    func increaseFontSize() {
        editorFontSize = min(24, editorFontSize + 1)
    }

    func decreaseFontSize() {
        editorFontSize = max(10, editorFontSize - 1)
    }

    func resetFontSize() {
        editorFontSize = 13.0
    }
}
