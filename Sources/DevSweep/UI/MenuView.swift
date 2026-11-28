import SwiftUI

enum MenuTab: String, CaseIterable, Identifiable {
    case suggestions, processes, storage

    var id: String { rawValue }
}

struct MenuView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var tab: MenuTab = .suggestions
    @State private var showingSettings = false
    @AppStorage(Prefs.Key.workspacesConfirmed) private var workspacesConfirmed = false

    var body: some View {
        VStack(spacing: 0) {
            if !workspacesConfirmed {
                WelcomeView { model.prefsChanged() }
                Divider()
                workspaceUtilityBar
            } else if showingSettings {
                SettingsView {
                    showingSettings = false
                    model.prefsChanged()
                }
                Divider()
                workspaceUtilityBar
            } else {
                HeaderView { showingSettings = true }
                Picker("", selection: $tab) {
                    ForEach(MenuTab.allCases) { tab in
                        Text(label(for: tab)).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
                Divider()
                ZStack(alignment: .bottom) {
                    switch tab {
                    case .suggestions: SuggestionsView()
                    case .processes: ProcessesView()
                    case .storage: StorageView()
                    }
                    if let banner = model.banner {
                        BannerView(text: banner)
                            .padding(10)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .frame(maxHeight: .infinity)
                .animation(.easeInOut(duration: 0.2), value: model.banner)
                CleanupStatusView()
                Divider()
                FooterView(openWorkspace: openGeneralWorkspace)
            }
        }
        .frame(width: 470, height: 680)
        .id(model.languageRevision)
        .onAppear { model.popoverOpened() }
    }

    private var workspaceUtilityBar: some View {
        HStack {
            Button(action: openGeneralWorkspace) {
                Label(tr("general.open"), systemImage: "macwindow")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Spacer()
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.borderless)
            .help(tr("footer.quit"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial)
    }

    private func openGeneralWorkspace() {
        openWindow(id: "general")
        NSApp.activate(ignoringOtherApps: true)
    }

    private func label(for tab: MenuTab) -> String {
        switch tab {
        case .suggestions:
            let count = model.recommendations.count
            return count > 0 ? tr("tab.suggestions_count", ["count": count]) : tr("tab.suggestions")
        case .processes:
            return tr("tab.processes")
        case .storage:
            return tr("tab.storage")
        }
    }
}

private struct HeaderView: View {
    @EnvironmentObject private var model: AppModel
    let openSettings: () -> Void

    var body: some View {
        let system = model.system
        let lowDisk = Double(system.diskFree) < Prefs.defaults.double(forKey: Prefs.Key.lowDiskGB) * 1e9
        let diskUsedFraction = system.diskTotal > 0 ? 1 - Double(system.diskFree) / Double(system.diskTotal) : 0

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(nsImage: MenuBarLabel.brandIcon).foregroundStyle(.tint)
                Text("Zelvo").font(.headline)
                Spacer()
                if model.isScanningStorage || model.isScanningProcesses {
                    ProgressView().controlSize(.mini)
                }
                Button(action: model.refreshAll) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help(tr("header.scan_now"))
                Button(action: openSettings) { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless)
                    .help(tr("header.settings"))
            }

            HStack(spacing: 10) {
                TechnicalCard(cornerRadius: 8, padding: 8) {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 4) {
                            Text(tr("general.memory"))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            StatusBadge(
                                text: system.pressureAvailable ? system.pressure.label : tr("storage.unavailable"),
                                color: system.pressureAvailable ? system.pressure.color : .secondary
                            )
                        }
                        ProportionalBar(
                            fraction: system.memFraction,
                            tint: system.memoryTight ? (system.pressure == .critical ? .red : .orange) : .green,
                            height: 4.5
                        )
                        Text("\(Fmt.memory(system.memUsed)) / \(Fmt.memory(system.memTotal))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                TechnicalCard(cornerRadius: 8, padding: 8) {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 4) {
                            Text(tr("header.disk"))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(tr("header.disk_free", ["size": Fmt.disk(system.diskFree)]))
                                .font(.caption2.monospacedDigit().weight(.medium))
                                .foregroundStyle(lowDisk ? Color.red : Color.secondary)
                        }
                        ProportionalBar(
                            fraction: diskUsedFraction,
                            tint: lowDisk ? .red : .blue,
                            height: 4.5
                        )
                        Text(Fmt.disk(system.diskTotal))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(12)
    }
}

private struct FooterView: View {
    @EnvironmentObject private var model: AppModel
    let openWorkspace: () -> Void

    var body: some View {
        let actionable = model.recommendations.filter { $0.risk != .dataLoss }
        let disk = actionable.reduce(0) { $0 + $1.diskBytes }
        let ram = actionable.reduce(0) { $0 + $1.ramBytes }

        VStack(spacing: 8) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(tr("footer.total_freed"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(Fmt.disk(model.totalFreed))
                        .font(.caption.monospacedDigit().weight(.semibold))
                }
                Spacer()
                if !actionable.isEmpty {
                    Button {
                        Task { await model.performAllRecommended() }
                    } label: {
                        HStack(spacing: 6) {
                            if model.isPerformingAll {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: "wand.and.stars")
                            }
                            Text(tr("footer.clean_recommended"))
                            Text([disk > 0 ? Fmt.disk(disk) : nil, ram > 0 ? tr("footer.ram", ["size": Fmt.memory(ram)]) : nil]
                                .compactMap { $0 }.joined(separator: " + "))
                                .monospacedDigit()
                                .foregroundStyle(.white.opacity(0.85))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(model.isPerformingAll || model.cleanupProgress != nil || model.isScanningStorage)
                    .help(tr("footer.clean_recommended_help"))
                }
            }

            Divider()

            HStack {
                Button(action: openWorkspace) {
                    Label(tr("general.open"), systemImage: "macwindow")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                Button {
                    NSApp.terminate(nil)
                } label: {
                    Label(tr("footer.quit"), systemImage: "power")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help(tr("footer.quit"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.regularMaterial)
    }
}
