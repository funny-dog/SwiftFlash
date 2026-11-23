import SwiftUI

struct LSPSettingsView: View {
    var workspace: WorkspaceState? = nil
    @ObservedObject private var lspManager = LSPManager.shared

    private var matchedServerIDForActiveTab: String? {
        guard let tab = workspace?.activeTab else { return nil }
        return lspManager.serverDefinition(for: tab.language, url: tab.url)?.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n("settings.lsp.subtitle"))
                        .font(.system(size: 11.5))
                        .foregroundColor(Color(nsColor: ZedTheme.secondaryText))
                    Text(L10n("settings.lsp.storageHintFormat", LSPStorage.rootDirectory.path))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(Color(nsColor: ZedTheme.mutedText))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                Button {
                    lspManager.refreshStatuses()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10.5))
                        Text(L10n("settings.lsp.rescan"))
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(Color(nsColor: ZedTheme.primaryText))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color(nsColor: ZedTheme.background))
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(nsColor: ZedTheme.border), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }

            if let err = lspManager.lastErrorMessage {
                Text(err)
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
                            .stroke(Color(nsColor: ZedTheme.attribute).opacity(0.55), lineWidth: 1)
                    )
            }

            ForEach(LSPServerCatalog.all) { def in
                serverRow(def)
            }
        }
        .onAppear {
            lspManager.refreshStatuses()
        }
    }

    private func serverRow(_ def: LSPServerDefinition) -> some View {
        let status = lspManager.status(for: def.id)
        let isActive = lspManager.activeServerIDs.contains(def.id)
        let isMatched = matchedServerIDForActiveTab == def.id

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(def.displayName)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundColor(Color(nsColor: ZedTheme.primaryText))

                        Text(def.languageSummary)
                            .font(.system(size: 10.5))
                            .foregroundColor(Color(nsColor: ZedTheme.secondaryText))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Color(nsColor: ZedTheme.sidebarBackground))
                            .cornerRadius(4)

                        if isMatched {
                            Text(L10n("settings.lsp.currentFile"))
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(Color(nsColor: ZedTheme.function))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1.5)
                                .background(Color(nsColor: ZedTheme.function).opacity(0.14))
                                .cornerRadius(4)
                        }

                        if isActive {
                            Text(L10n("settings.lsp.running"))
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(Color(nsColor: ZedTheme.string))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1.5)
                                .background(Color(nsColor: ZedTheme.string).opacity(0.14))
                                .cornerRadius(4)
                        }
                    }

                    statusSubtitle(status: status, def: def)
                }

                Spacer()

                actionControls(status: status, def: def)
            }

            if case .installing(let progress) = status {
                VStack(alignment: .leading, spacing: 5) {
                    if let fraction = progress.fraction {
                        ProgressView(value: fraction, total: 1.0)
                            .progressViewStyle(.linear)
                            .tint(Color(nsColor: ZedTheme.function))
                    } else {
                        ProgressView()
                            .progressViewStyle(.linear)
                            .tint(Color(nsColor: ZedTheme.function))
                    }

                    HStack(spacing: 8) {
                        Text(progress.message)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundColor(Color(nsColor: ZedTheme.primaryText))
                        Spacer()
                        if let detail = progress.detail, !detail.isEmpty {
                            Text(detail)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundColor(Color(nsColor: ZedTheme.secondaryText))
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: ZedTheme.background))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(
                    Color(nsColor: isMatched ? ZedTheme.function : ZedTheme.border),
                    lineWidth: isMatched ? 1.5 : 1
                )
        )
    }

    @ViewBuilder
    private func statusSubtitle(status: LSPServerStatus, def: LSPServerDefinition) -> some View {
        switch status {
        case .detected(let path):
            Text("\(L10n("settings.lsp.detected")): \(path)")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(Color(nsColor: ZedTheme.string))
                .lineLimit(1)
                .truncationMode(.middle)
        case .installed(let path):
            Text("\(L10n("settings.lsp.installed")): \(path)")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(Color(nsColor: ZedTheme.function))
                .lineLimit(1)
                .truncationMode(.middle)
        case .installing(let progress):
            if let detail = progress.detail, !detail.isEmpty {
                Text("\(progress.message) • \(detail)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(Color(nsColor: ZedTheme.typeName))
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text(progress.message)
                    .font(.system(size: 10.5))
                    .foregroundColor(Color(nsColor: ZedTheme.typeName))
            }
        case .failed(let message):
            Text(message)
                .font(.system(size: 10.5))
                .foregroundColor(Color(nsColor: ZedTheme.attribute))
                .lineLimit(2)
        case .notInstalled:
            Text("\(L10n("settings.lsp.notInstalled")) • \(def.manualInstallHint)")
                .font(.system(size: 10.5))
                .foregroundColor(Color(nsColor: ZedTheme.mutedText))
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private func actionControls(status: LSPServerStatus, def: LSPServerDefinition) -> some View {
        switch status {
        case .installing(let progress):
            HStack(spacing: 5) {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.65)
                    .frame(width: 12, height: 12)
                if let fraction = progress.fraction {
                    Text("\(Int((fraction * 100).rounded()))%")
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundColor(Color(nsColor: ZedTheme.typeName))
                } else {
                    Text(L10n("settings.lsp.installingBadge"))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(Color(nsColor: ZedTheme.typeName))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3.5)
            .background(Color(nsColor: ZedTheme.sidebarBackground))
            .cornerRadius(5)
        case .installed:
            HStack(spacing: 6) {
                Button {
                    Task { await lspManager.installServer(id: def.id) }
                } label: {
                    Text(L10n("settings.lsp.update"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Color(nsColor: ZedTheme.primaryText))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Color(nsColor: ZedTheme.sidebarBackground))
                        .cornerRadius(5)
                }
                .buttonStyle(.plain)

                Button {
                    lspManager.uninstallServer(id: def.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundColor(Color(nsColor: ZedTheme.attribute))
                        .frame(width: 24, height: 24)
                        .background(Color(nsColor: ZedTheme.sidebarBackground))
                        .cornerRadius(5)
                }
                .buttonStyle(.plain)
                .help(L10n("settings.lsp.uninstallHelp"))
            }
        case .detected:
            Text(L10n("settings.lsp.readyBadge"))
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(Color(nsColor: ZedTheme.string))
                .padding(.horizontal, 8)
                .padding(.vertical, 3.5)
                .background(Color(nsColor: ZedTheme.string).opacity(0.14))
                .cornerRadius(5)
        case .notInstalled, .failed:
            Button {
                Task { await lspManager.installServer(id: def.id) }
            } label: {
                Text(installButtonLabel(for: def))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color(nsColor: ZedTheme.pillText))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4.5)
                    .background(Color(nsColor: ZedTheme.pillBackground))
                    .cornerRadius(5)
            }
            .buttonStyle(.plain)
        }
    }

    private func installButtonLabel(for def: LSPServerDefinition) -> String {
        if case .systemToolchain = def.installStrategy {
            return L10n("settings.lsp.detectButton")
        }
        return L10n("settings.lsp.installButton")
    }
}
