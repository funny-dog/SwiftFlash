import AppKit
import SwiftUI

// MARK: - Theme, Font, Language & LSP Settings Modal

struct ThemeAndFontSettingsModalView: View {
    @ObservedObject var workspace: WorkspaceState
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var pluginManager = PluginManager.shared
    @ObservedObject private var localizationManager = LocalizationManager.shared
    @State private var escapeMonitor: Any?
    @State private var pendingInstallEntry: RemotePluginEntry?
    @State private var isCloseHovered = false

    private let lineHeights: [CGFloat] = [1.2, 1.38, 1.5, 1.65]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: workspace.preferredSettingsSection == .appearance ? "paintbrush.pointed.fill" : "server.rack")
                        .font(.system(size: 13))
                        .foregroundColor(Color(nsColor: ZedTheme.function))
                    Text(L10n("settings.title"))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Color(nsColor: ZedTheme.primaryText))
                }

                Spacer()

                HStack(spacing: 4) {
                    settingsTabPill(tab: .appearance, title: L10n("settings.tab.appearance"))
                    settingsTabPill(tab: .languageServers, title: L10n("settings.tab.languageServers"))
                }
                .padding(2)
                .background(Color(nsColor: ZedTheme.background))
                .cornerRadius(7)
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(Color(nsColor: ZedTheme.border), lineWidth: 1)
                )

                Spacer().frame(width: 10)

                Button {
                    workspace.dismissOverlay()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Color(nsColor: isCloseHovered ? ZedTheme.primaryText : ZedTheme.secondaryText))
                        .frame(width: 24, height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color(nsColor: isCloseHovered ? ZedTheme.hoverBackground : ZedTheme.background))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color(nsColor: ZedTheme.border), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .onHover { isCloseHovered = $0 }
                .help("\(L10n("common.close")) (ESC)")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider().overlay(Color(nsColor: ZedTheme.border))

            ScrollView {
                if workspace.preferredSettingsSection == .languageServers {
                    LSPSettingsView(workspace: workspace)
                        .padding(16)
                } else {
                    VStack(alignment: .leading, spacing: 18) {
                        languageAndPluginsSection

                        Divider().overlay(Color(nsColor: ZedTheme.border))

                        // Theme Selector Grid
                        VStack(alignment: .leading, spacing: 8) {
                            Text(L10n("settings.section.theme"))
                                .font(.system(size: 10.5, weight: .bold, design: .rounded))
                                .foregroundColor(Color(nsColor: ZedTheme.mutedText))

                            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                                ForEach(ThemeID.allCases) { themeID in
                                    themeCard(for: themeID)
                                }
                            }
                        }

                        Divider().overlay(Color(nsColor: ZedTheme.border))

                        // Font Family Selector
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(L10n("settings.section.fontFamily"))
                                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                                    .foregroundColor(Color(nsColor: ZedTheme.mutedText))
                                Spacer()
                                Picker("", selection: $themeManager.editorFontFamily) {
                                    ForEach(themeManager.availableMonospacedFonts, id: \.self) { family in
                                        Text(family).tag(family)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 210)
                            }

                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) {
                                    ForEach(themeManager.availableMonospacedFonts.prefix(6), id: \.self) { family in
                                        let selected = themeManager.editorFontFamily == family
                                        Button {
                                            themeManager.editorFontFamily = family
                                        } label: {
                                            Text(family)
                                                .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                                                .foregroundColor(Color(nsColor: selected ? ZedTheme.pillText : ZedTheme.secondaryText))
                                                .padding(.horizontal, 9)
                                                .padding(.vertical, 5)
                                                .background(
                                                    RoundedRectangle(cornerRadius: 6)
                                                        .fill(Color(nsColor: selected ? ZedTheme.pillBackground : ZedTheme.background))
                                                )
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 6)
                                                        .stroke(Color(nsColor: ZedTheme.border), lineWidth: 1)
                                                )
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }

                        // Size & Line Height Controls
                        VStack(alignment: .leading, spacing: 10) {
                            Text(L10n("settings.section.sizeSpacing"))
                                .font(.system(size: 10.5, weight: .bold, design: .rounded))
                                .foregroundColor(Color(nsColor: ZedTheme.mutedText))

                            HStack {
                                Text(L10n("settings.fontSize"))
                                    .font(.system(size: 12.5))
                                    .foregroundColor(Color(nsColor: ZedTheme.primaryText))
                                Spacer()
                                stepperControls(
                                    valueText: "\(Int(themeManager.editorFontSize)) pt",
                                    onMinus: { themeManager.decreaseFontSize() },
                                    onPlus: { themeManager.increaseFontSize() },
                                    onReset: { themeManager.resetFontSize() }
                                )
                            }

                            HStack {
                                Text(L10n("settings.lineHeight"))
                                    .font(.system(size: 12.5))
                                    .foregroundColor(Color(nsColor: ZedTheme.primaryText))
                                Spacer()
                                HStack(spacing: 4) {
                                    ForEach(lineHeights, id: \.self) { ratio in
                                        let isSelected = abs(themeManager.lineHeightMultiplier - ratio) < 0.02
                                        Button {
                                            themeManager.lineHeightMultiplier = ratio
                                        } label: {
                                            Text(String(format: "%.2gx", ratio))
                                                .font(.system(size: 11, weight: isSelected ? .semibold : .regular, design: .monospaced))
                                                .foregroundColor(Color(nsColor: isSelected ? ZedTheme.pillText : ZedTheme.secondaryText))
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 4)
                                                .background(
                                                    RoundedRectangle(cornerRadius: 5)
                                                        .fill(Color(nsColor: isSelected ? ZedTheme.pillBackground : ZedTheme.background))
                                                )
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }

                            HStack {
                                Text(L10n("settings.uiFontSize"))
                                    .font(.system(size: 12.5))
                                    .foregroundColor(Color(nsColor: ZedTheme.primaryText))
                                Spacer()
                                stepperControls(
                                    valueText: String(format: "%.1f pt", themeManager.uiFontSize),
                                    onMinus: { themeManager.uiFontSize = max(11, themeManager.uiFontSize - 0.5) },
                                    onPlus: { themeManager.uiFontSize = min(16, themeManager.uiFontSize + 0.5) },
                                    onReset: nil
                                )
                            }
                        }

                        // Live Editor Preview
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L10n("settings.section.preview"))
                                .font(.system(size: 10.5, weight: .bold, design: .rounded))
                                .foregroundColor(Color(nsColor: ZedTheme.mutedText))

                            VStack(alignment: .leading, spacing: 2) {
                                previewLine("func ", color: ZedTheme.keyword, rest: "switchWorkspace(", restColor: ZedTheme.function, tail: "path: String) {", tailColor: ZedTheme.plainText)
                                previewLine("    let ", color: ZedTheme.keyword, rest: "label = ", restColor: ZedTheme.plainText, tail: "\"SwiftFlash\"", tailColor: ZedTheme.string)
                                previewLine(L10n("settings.preview.comment"), color: ZedTheme.comment, rest: "", restColor: ZedTheme.comment, tail: "", tailColor: ZedTheme.comment)
                                previewLine("}", color: ZedTheme.plainText, rest: "", restColor: ZedTheme.plainText, tail: "", tailColor: ZedTheme.plainText)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(nsColor: ZedTheme.background))
                            .cornerRadius(7)
                            .overlay(
                                RoundedRectangle(cornerRadius: 7)
                                    .stroke(Color(nsColor: ZedTheme.border), lineWidth: 1)
                            )
                        }
                    }
                    .padding(16)
                }
            }
            .frame(maxHeight: 540)
        }
        .frame(width: 600)
        .background(Color(nsColor: ZedTheme.sidebarBackground))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(nsColor: ZedTheme.border), lineWidth: 1)
        )
        .shadow(color: .black.opacity(ZedTheme.isDark ? 0.55 : 0.22), radius: 26, y: 12)
        .onAppear {
            if pluginManager.remotePlugins.isEmpty && !pluginManager.isFetchingRegistry {
                Task {
                    await pluginManager.fetchRemoteRegistry()
                }
            }
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.window === NSApp.keyWindow,
                      !SwitcherKeyboardSupport.hasActiveMarkedText() else {
                    return event
                }
                if Int(event.keyCode) == 53 {
                    workspace.dismissOverlay()
                    return nil
                }
                return event
            }
        }
        .onDisappear {
            if let escapeMonitor {
                NSEvent.removeMonitor(escapeMonitor)
                self.escapeMonitor = nil
            }
        }
    }

    // MARK: - Language & Plugins Section

    private struct LanguageDropdownOption: Identifiable {
        let id: String
        let displayName: String
        let isInstalled: Bool
        let remoteEntry: RemotePluginEntry?
    }

    private var availableLanguageOptions: [LanguageDropdownOption] {
        var options: [LanguageDropdownOption] = []
        var seenIDs = Set<String>()

        for installed in pluginManager.installedLanguagePlugins {
            let name = installed.manifest.contributes?.localization?.nativeName ?? installed.manifest.name
            let remote = pluginManager.remoteLanguagePlugins.first { $0.id == installed.id }
            options.append(LanguageDropdownOption(
                id: installed.id,
                displayName: name,
                isInstalled: true,
                remoteEntry: remote
            ))
            seenIDs.insert(installed.id)
        }

        for remote in pluginManager.remoteLanguagePlugins where !seenIDs.contains(remote.id) {
            let name = remote.nativeName ?? remote.name
            options.append(LanguageDropdownOption(
                id: remote.id,
                displayName: name,
                isInstalled: false,
                remoteEntry: remote
            ))
            seenIDs.insert(remote.id)
        }

        return options
    }

    private var currentDropdownDisplayName: String {
        if let pending = pendingInstallEntry {
            return pending.nativeName ?? pending.name
        }
        return pendingTargetLanguageName
    }

    private var pendingTargetLanguageName: String {
        let id = localizationManager.selectedLanguagePluginID
        if id.isEmpty {
            return L10n("settings.language.builtinEnglish")
        }
        if let installed = pluginManager.installedLanguagePlugins.first(where: { $0.id == id }) {
            return installed.manifest.contributes?.localization?.nativeName ?? installed.manifest.name
        }
        return id
    }

    private var languageAndPluginsSection: some View {
        let isInstallingPending = pendingInstallEntry.map { pluginManager.installingPluginIDs.contains($0.id) } ?? false

        return VStack(alignment: .leading, spacing: 10) {
            Text(L10n("settings.section.languagePlugins"))
                .font(.system(size: 10.5, weight: .bold, design: .rounded))
                .foregroundColor(Color(nsColor: ZedTheme.mutedText))

            HStack(spacing: 8) {
                Text(L10n("settings.language.active"))
                    .font(.system(size: 12.5))
                    .foregroundColor(Color(nsColor: ZedTheme.primaryText))

                Spacer()

                Menu {
                    Button {
                        pendingInstallEntry = nil
                        localizationManager.selectLanguagePlugin(id: LocalizationManager.builtInEnglishID)
                    } label: {
                        HStack {
                            Text(L10n("settings.language.builtinEnglish"))
                            if localizationManager.selectedLanguagePluginID.isEmpty && pendingInstallEntry == nil {
                                Image(systemName: "checkmark")
                            }
                        }
                    }

                    if !availableLanguageOptions.isEmpty {
                        Divider()
                    }

                    ForEach(availableLanguageOptions) { option in
                        Button {
                            if option.isInstalled {
                                pendingInstallEntry = nil
                                localizationManager.selectLanguagePlugin(id: option.id)
                            } else if let remote = option.remoteEntry {
                                pluginManager.registryError = nil
                                pendingInstallEntry = remote
                            }
                        } label: {
                            HStack {
                                if option.isInstalled {
                                    Text(option.displayName)
                                    if localizationManager.selectedLanguagePluginID == option.id && pendingInstallEntry == nil {
                                        Image(systemName: "checkmark")
                                    }
                                } else {
                                    Text(L10n("settings.language.installOptionSuffix", option.displayName))
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "globe")
                            .font(.system(size: 11.5))
                            .foregroundColor(Color(nsColor: ZedTheme.function))

                        Text(currentDropdownDisplayName)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Color(nsColor: ZedTheme.primaryText))
                            .lineLimit(1)

                        Spacer(minLength: 8)

                        if pluginManager.isFetchingRegistry {
                            ProgressView()
                                .scaleEffect(0.42)
                                .frame(width: 11, height: 11)
                        } else {
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundColor(Color(nsColor: ZedTheme.mutedText))
                        }
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .frame(minWidth: 190, maxWidth: 230)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(nsColor: ZedTheme.background))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color(nsColor: ZedTheme.border), lineWidth: 1)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Button {
                    Task {
                        await pluginManager.fetchRemoteRegistry()
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                        .foregroundColor(Color(nsColor: ZedTheme.secondaryText))
                        .frame(width: 26, height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(Color(nsColor: ZedTheme.background))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 7)
                                .stroke(Color(nsColor: ZedTheme.border), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .disabled(pluginManager.isFetchingRegistry)
                .help(L10n("settings.plugins.refreshHelp"))

                if !localizationManager.selectedLanguagePluginID.isEmpty,
                   pluginManager.installedPlugin(id: localizationManager.selectedLanguagePluginID) != nil {
                    Button {
                        pluginManager.uninstallPlugin(id: localizationManager.selectedLanguagePluginID)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundColor(Color(nsColor: ZedTheme.attribute))
                            .frame(width: 26, height: 26)
                            .background(
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(Color(nsColor: ZedTheme.background))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 7)
                                    .stroke(Color(nsColor: ZedTheme.border), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(L10n("settings.plugins.uninstallHelp"))
                }
            }

            if let entry = pendingInstallEntry {
                let langLabel = entry.nativeName ?? entry.name
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 14))
                            .foregroundColor(Color(nsColor: ZedTheme.function))
                            .padding(.top, 1)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(L10n("settings.language.confirmTitleFormat", langLabel))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(Color(nsColor: ZedTheme.primaryText))

                            Text(L10n("settings.language.confirmBodyFormat", entry.version))
                                .font(.system(size: 11))
                                .foregroundColor(Color(nsColor: ZedTheme.secondaryText))
                        }
                    }

                    HStack(spacing: 8) {
                        Spacer()

                        Button {
                            pendingInstallEntry = nil
                        } label: {
                            Text(L10n("common.cancel"))
                                .font(.system(size: 11))
                                .foregroundColor(Color(nsColor: ZedTheme.secondaryText))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4.5)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(Color(nsColor: ZedTheme.background))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(Color(nsColor: ZedTheme.border), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(isInstallingPending)

                        Button {
                            Task {
                                let success = await pluginManager.installPlugin(entry, activateIfLanguage: true)
                                if success {
                                    pendingInstallEntry = nil
                                }
                            }
                        } label: {
                            HStack(spacing: 5) {
                                if isInstallingPending {
                                    ProgressView()
                                        .scaleEffect(0.45)
                                        .frame(width: 11, height: 11)
                                    Text(L10n("settings.plugins.downloading"))
                                } else {
                                    Text(L10n("settings.language.confirmInstallButton"))
                                }
                            }
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Color(nsColor: ZedTheme.pillText))
                            .padding(.horizontal, 11)
                            .padding(.vertical, 4.5)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color(nsColor: ZedTheme.pillBackground))
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(isInstallingPending)
                    }
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: ZedTheme.activeTabBackground))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(nsColor: ZedTheme.cursor).opacity(0.6), lineWidth: 1)
                )
            }

            if localizationManager.needsRestartToApply {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                        .font(.system(size: 13))
                        .foregroundColor(Color(nsColor: ZedTheme.typeName))

                    Text(L10n("settings.language.pendingRestartBanner", pendingTargetLanguageName))
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(Color(nsColor: ZedTheme.primaryText))

                    Spacer()

                    Button {
                        localizationManager.restartApplication()
                    } label: {
                        Text(L10n("settings.language.restartNow"))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Color(nsColor: ZedTheme.pillText))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4.5)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color(nsColor: ZedTheme.pillBackground))
                            )
                    }
                    .buttonStyle(.plain)
                }
                .padding(9)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: ZedTheme.activeTabBackground))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(nsColor: ZedTheme.typeName).opacity(0.6), lineWidth: 1)
                )
            }

            if let errorMsg = pluginManager.registryError {
                Text(errorMsg)
                    .font(.system(size: 11))
                    .foregroundColor(Color(nsColor: ZedTheme.attribute))
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(nsColor: ZedTheme.background))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(nsColor: ZedTheme.attribute).opacity(0.5), lineWidth: 1)
                    )
            }
        }
    }

    private func settingsTabPill(tab: WorkspaceState.SettingsSection, title: String) -> some View {
        let isActive = workspace.preferredSettingsSection == tab
        return Button {
            workspace.preferredSettingsSection = tab
        } label: {
            Text(title)
                .font(.system(size: 11, weight: isActive ? .semibold : .medium))
                .foregroundColor(Color(nsColor: isActive ? ZedTheme.pillText : ZedTheme.secondaryText))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isActive ? Color(nsColor: ZedTheme.pillBackground) : Color.clear)
                )
        }
        .buttonStyle(.plain)
    }

    private func themeCard(for id: ThemeID) -> some View {
        let palette = ThemePalette.palette(for: id)
        let isSelected = themeManager.currentThemeID == id
        return Button {
            themeManager.currentThemeID = id
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(id.rawValue)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(Color(nsColor: ZedTheme.primaryText))
                        .lineLimit(1)
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(Color(nsColor: ZedTheme.function))
                    }
                }

                HStack(spacing: 5) {
                    ForEach(Array(palette.previewSwatches.enumerated()), id: \.offset) { _, hex in
                        Circle()
                            .fill(Color(nsColor: NSColor(hex: hex)))
                            .frame(width: 11, height: 11)
                            .overlay(
                                Circle()
                                    .stroke(Color(nsColor: ZedTheme.border), lineWidth: 0.6)
                            )
                    }
                    Spacer()
                    Text(palette.isDark ? L10n("settings.theme.dark") : L10n("settings.theme.light"))
                        .font(.system(size: 10))
                        .foregroundColor(Color(nsColor: ZedTheme.mutedText))
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: isSelected ? ZedTheme.activeTabBackground : ZedTheme.background))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        Color(nsColor: isSelected ? ZedTheme.cursor : ZedTheme.border),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private func stepperControls(
        valueText: String,
        onMinus: @escaping () -> Void,
        onPlus: @escaping () -> Void,
        onReset: (() -> Void)?
    ) -> some View {
        HStack(spacing: 6) {
            Button(action: onMinus) {
                Image(systemName: "minus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 22)
                    .background(Color(nsColor: ZedTheme.background))
                    .cornerRadius(5)
            }
            .buttonStyle(.plain)

            Text(valueText)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(Color(nsColor: ZedTheme.primaryText))
                .frame(minWidth: 52)

            Button(action: onPlus) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 22)
                    .background(Color(nsColor: ZedTheme.background))
                    .cornerRadius(5)
            }
            .buttonStyle(.plain)

            if let onReset {
                Button(L10n("common.reset"), action: onReset)
                    .font(.system(size: 11))
                    .foregroundColor(Color(nsColor: ZedTheme.secondaryText))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color(nsColor: ZedTheme.background))
                    .cornerRadius(5)
                    .buttonStyle(.plain)
            }
        }
        .foregroundColor(Color(nsColor: ZedTheme.primaryText))
    }

    private func previewLine(
        _ first: String,
        color: NSColor,
        rest: String,
        restColor: NSColor,
        tail: String,
        tailColor: NSColor
    ) -> some View {
        HStack(spacing: 0) {
            Text(first).foregroundColor(Color(nsColor: color))
            Text(rest).foregroundColor(Color(nsColor: restColor))
            Text(tail).foregroundColor(Color(nsColor: tailColor))
        }
        .font(Font(themeManager.editorFont))
    }
}
