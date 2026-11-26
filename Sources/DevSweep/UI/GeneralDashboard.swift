import AppKit
import SwiftUI

struct GeneralDashboard: View {
    @EnvironmentObject private var app: AppModel
    @StateObject private var model = GeneralModel()
    @State private var review: [GeneralEntry] = []
    @State private var showingReview = false
    @State private var exportError: String?

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("DevSweep").font(.title2.bold()).padding(.bottom, 12)
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(GeneralArea.allCases) { area in
                            Button {
                                model.cancel(); model.area = area; model.search = ""; model.selected = []
                            } label: {
                                Label(area.title, systemImage: area.icon)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(9)
                                    .background(RoundedRectangle(cornerRadius: 7).fill(model.area == area ? Color.accentColor.opacity(0.15) : .clear))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Spacer()
                Button(tr("cleanup.history")) { showingHistory() }
                    .buttonStyle(.link)
            }
            .padding(16).frame(width: 190).background(.quaternary.opacity(0.35))
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                toolbar
                if model.area == .monitor {
                    GeneralMonitorView(model: model)
                } else if model.area == .maintenance {
                    maintenance
                } else {
                    results
                }
                if let error = exportError { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                if let banner = app.banner { BannerView(text: banner).frame(maxWidth: .infinity) }
                CleanupStatusView()
            }
            .padding(18).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 850, minHeight: 600)
        .task(id: model.area) {
            if model.area == .monitor {
                while !Task.isCancelled {
                    await model.refreshMonitor()
                    try? await Task.sleep(for: .seconds(5))
                }
            } else if model.area != .maintenance {
                await model.scan()
            }
        }
        .onDisappear { model.cancel() }
        .onChange(of: model.explorerMode) { _, mode in
            model.selected = []
            if mode == .largeFiles && model.explorerFilter.minimumBytes == 0 {
                model.explorerFilter.minimumBytes = 100 * 1_048_576
            } else { Task { await model.scan(force: true) } }
        }
        .onChange(of: model.explorerFilter.minimumBytes) { _, _ in
            model.selected = []
            if model.area == .explorer && model.explorerMode == .largeFiles { Task { await model.scan(force: true) } }
        }
        .onChange(of: model.explorerFilter) { _, _ in model.selected = [] }
        .onChange(of: model.search) { _, _ in model.selected = [] }
        .sheet(isPresented: $showingReview) { reviewSheet }
        .sheet(isPresented: $historyVisible) { CleanupHistoryView().environmentObject(app) }
    }

    @State private var historyVisible = false
    private func showingHistory() { historyVisible = true }

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(model.area.title).font(.title2.weight(.semibold))
                Spacer()
                if model.scanning || model.runningMaintenance != nil {
                    ProgressView().controlSize(.small)
                    Button(tr("general.cancel")) { model.cancel() }
                } else if model.area != .maintenance {
                    Button {
                        Task {
                            if model.area == .monitor { await model.refreshMonitor() }
                            else { await model.scan(force: true) }
                        }
                    } label: { Image(systemName: "arrow.clockwise") }
                    .help(tr("header.scan_now"))
                }
                if [.logs, .caches, .explorer, .installers, .projects, .external].contains(model.area) {
                    Button(tr("general.choose_folder")) { chooseFolder() }.disabled(model.scanning)
                }
                if model.area != .maintenance {
                    Button(tr("general.export")) { export() }.disabled(model.scanning)
                }
            }
            if [.logs, .caches, .explorer, .installers, .projects, .external].contains(model.area) {
                HStack {
                    if model.area == .explorer {
                        Button { model.choose(model.root.deletingLastPathComponent()); Task { await model.scan() } } label: { Image(systemName: "arrow.up") }
                    }
                    Text(model.area == .projects ? PrefsSnapshot.current().projectRoots.joined(separator: " · ")
                         : ([.logs, .caches, .installers].contains(model.area) && model.roots[model.area] == nil ? tr("general.known_roots") : model.root.path))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                }
            }
        }
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.area == .temporaries { Text(tr("hygiene.temp_notice")).font(.caption).foregroundStyle(.secondary) }
            if model.area == .trash { Text(tr("hygiene.trash_notice")).font(.caption).foregroundStyle(.secondary) }
            if model.area == .external { Text(tr("hygiene.external_notice")).font(.caption).foregroundStyle(.secondary) }
            if model.area == .explorer { explorerControls }
            TextField(tr("general.search"), text: $model.search).textFieldStyle(.roundedBorder)
            HStack {
                Text(tr("general.count", ["count": model.report.entries.count, "inspected": model.report.inspected]))
                Spacer()
                Text(model.scanning ? tr("storage.measuring") : !model.report.complete ? tr("general.partial")
                     : model.fullyMeasured ? tr("general.complete") : tr("explorer.partial_measurement"))
                    .foregroundStyle(model.report.complete && model.fullyMeasured ? Color.secondary : .orange)
            }
            .font(.caption)
            if model.scanning {
                Text(model.currentPath).font(.caption2).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
            }
            let issues = model.report.issues + (model.scanning ? [] : model.measurementIssues)
            if !issues.isEmpty {
                DisclosureGroup(tr("general.issues", ["count": issues.count])) {
                    ScrollView {
                        VStack(alignment: .leading) {
                            ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                                Text(issue).font(.caption2).textSelection(.enabled)
                            }
                        }
                    }.frame(maxHeight: 100)
                }.foregroundStyle(.orange)
            }
            if model.visible.isEmpty && !model.scanning {
                ContentUnavailableView(tr("general.no_results"), systemImage: "magnifyingglass", description: Text(tr("general.no_results_help")))
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(model.visible) { entry in row(entry) }
                    }
                }
            }
            HStack {
                Button(tr("review.select_all")) { model.selected = Set(model.visible.map(\.id)) }
                Button(tr("review.select_none")) { model.selected = [] }
                Spacer()
                Button(tr("general.review_count", ["count": model.selected.count])) {
                    review = model.report.entries.filter { model.selected.contains($0.id) }; showingReview = true
                }
                .disabled(model.selected.isEmpty || model.scanning || !model.report.complete)
            }
            .controlSize(.small)
            Text(tr("general.removal_notice")).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var explorerControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(tr("explorer.mode"), selection: $model.explorerMode) {
                ForEach(ExplorerMode.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).disabled(model.scanning)
            HStack {
                Picker(tr("explorer.minimum"), selection: $model.explorerFilter.minimumBytes) {
                    Text(tr("explorer.any_size")).tag(Int64(0))
                    Text("100 MB").tag(Int64(100 * 1_048_576))
                    Text("1 GB").tag(Int64(1_073_741_824))
                    Text("5 GB").tag(Int64(5 * 1_073_741_824))
                }.disabled(model.scanning)
                Picker(tr("explorer.age"), selection: $model.explorerFilter.olderThanDays) {
                    Text(tr("explorer.any_date")).tag(0)
                    Text(tr("explorer.days", ["count": 30])).tag(30)
                    Text(tr("explorer.days", ["count": 90])).tag(90)
                    Text(tr("explorer.days", ["count": 365])).tag(365)
                }
                Picker(tr("explorer.order"), selection: $model.explorerSort) {
                    ForEach(ExplorerSort.allCases) { Text($0.title).tag($0) }
                }
            }.controlSize(.small)
            TextField(tr("explorer.extensions"), text: $model.explorerFilter.extensions).textFieldStyle(.roundedBorder)
            Text(tr("explorer.showing", ["visible": model.visible.count, "total": model.report.entries.count]))
                .font(.caption).foregroundStyle(.secondary)
            if let volume = model.volume {
                Text(tr("explorer.volume", ["path": volume.path, "free": Fmt.disk(volume.free), "total": Fmt.disk(volume.total)]))
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if model.explorerMode == .largeFiles {
                Text(tr("explorer.recursive_notice")).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ entry: GeneralEntry) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Toggle("", isOn: Binding(get: { model.selected.contains(entry.id) }, set: {
                if $0 { model.selected.insert(entry.id) } else { model.selected.remove(entry.id) }
            })).labelsHidden().toggleStyle(.checkbox)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.target.title).font(.body.weight(.medium))
                Text(entry.url.path).font(.caption2).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                if let date = entry.modified { Text(date, format: .dateTime.day().month().year()).font(.caption2).foregroundStyle(.secondary) }
                if !entry.removable { Text(tr("general.read_only")).font(.caption2).foregroundStyle(.orange) }
            }
            Spacer()
            if let measurement = model.measurements[entry.id] { MeasurementLabel(measurement: measurement).font(.caption.monospacedDigit()) }
            else if model.scanning { ProgressView().controlSize(.mini) }
            else { Text(tr("storage.unavailable")).font(.caption).foregroundStyle(.orange) }
            Button { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) } label: { Image(systemName: "folder") }
                .buttonStyle(.borderless).help(tr("storage.show_in_finder"))
            if model.area == .explorer, (try? entry.url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                Button { model.choose(entry.url); Task { await model.scan() } } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.borderless).disabled(model.scanning)
            }
        }
        .padding(10).card()
    }

    private var reviewSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(tr("review.title")).font(.headline)
                Spacer()
                Button(tr("review.close")) { showingReview = false }
            }
            Text(tr("general.removal_notice")).font(.caption).foregroundStyle(.secondary)
            if model.area == .applications { Text(tr("general.app_data_kept")).font(.caption) }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(review) { entry in
                        HStack {
                            Text(entry.url.path).font(.caption).textSelection(.enabled)
                            Spacer()
                            if let size = model.measurements[entry.id] { MeasurementLabel(measurement: size).font(.caption) }
                        }
                    }
                }
            }
            let eligible = review.filter { $0.removable && model.measurements[$0.id]?.state == .complete }
            ActionButton(title: tr("general.trash_count", ["count": eligible.count]), symbol: "trash", confirm: true,
                         busy: app.cleanupProgress != nil) {
                showingReview = false
                Task { await app.cleanGeneral(eligible.map(\.target)); await model.scan(force: true) }
            }
            .disabled(eligible.isEmpty || !model.report.complete || app.isScanningStorage || app.isPerformingAll)
        }
        .padding(18).frame(width: 650, height: 460)
    }

    private var maintenance: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(tr("maintenance.notice")).font(.callout).foregroundStyle(.secondary)
                ForEach(MaintenanceTask.allCases) { task in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(task.title).font(.body.weight(.medium))
                            Text(task.changesState ? tr("maintenance.explicit_action") : tr("maintenance.read_only"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        ActionButton(title: task.changesState ? tr("maintenance.run") : tr("maintenance.inspect"),
                                     symbol: task.changesState ? "wrench" : "magnifyingglass", confirm: task.changesState,
                                     busy: model.runningMaintenance == task) { Task { await model.runMaintenance(task) } }
                            .disabled(model.runningMaintenance != nil)
                    }.padding(10).card()
                }
                if !model.maintenanceOutput.isEmpty {
                    Text(model.maintenanceOutput).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading).card()
                }
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = model.area == .projects
        guard panel.runModal() == .OK, let first = panel.urls.first else { return }
        if model.area == .projects {
            let roots = panel.urls.map { $0.resolvingSymlinksInPath().path }
            Prefs.defaults.set(roots.joined(separator: "\n"), forKey: Prefs.Key.projectRoots)
            Prefs.defaults.set(true, forKey: Prefs.Key.workspacesConfirmed)
            app.prefsChanged()
        } else { model.choose(first) }
        Task { await model.scan(force: true) }
    }

    private func export() {
        do {
            let data = try model.exportData()
            let panel = NSSavePanel(); panel.nameFieldStringValue = "devsweep-" + model.area.rawValue + ".json"
            if panel.runModal() == .OK, let url = panel.url { try data.write(to: url, options: .atomic) }
        } catch { exportError = error.localizedDescription }
    }
}

private struct GeneralMonitorView: View {
    @ObservedObject var model: GeneralModel
    var body: some View {
        ScrollView {
            if let snapshot = model.monitor {
                VStack(alignment: .leading, spacing: 15) {
                    HStack {
                        Text(tr("general.uptime", ["time": Fmt.duration(snapshot.uptime)]))
                        Spacer()
                        Text(snapshot.date, format: .dateTime.hour().minute().second())
                    }.font(.caption).foregroundStyle(.secondary)
                    if let cpu = model.cpu {
                        MeterView(title: "CPU", fraction: cpu.reduce(0, +) / Double(cpu.count),
                                  caption: (cpu.reduce(0, +) / Double(cpu.count)).formatted(.percent.precision(.fractionLength(0))), tint: .blue)
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4)) {
                            ForEach(Array(cpu.enumerated()), id: \.offset) { index, fraction in
                                MeterView(title: tr("general.core", ["number": index + 1]), fraction: fraction,
                                          caption: fraction.formatted(.percent.precision(.fractionLength(0))), tint: .blue)
                            }
                        }
                    } else { Text(tr("general.sampling")).font(.caption) }
                    MeterView(title: tr("general.memory"), fraction: snapshot.system.memFraction,
                              caption: "\(Fmt.memory(snapshot.system.memUsed)) / \(Fmt.memory(snapshot.system.memTotal))", tint: .purple)
                    Text(tr("general.swap", ["size": snapshot.swap.map { Fmt.memory(Int64(clamping: $0)) } ?? tr("storage.unavailable")]))
                        .font(.caption)
                    Text(tr("general.thermal", ["state": snapshot.thermal])).font(.caption)
                    if !snapshot.load.isEmpty {
                        Text(tr("general.load", ["value": snapshot.load.map { $0.formatted(.number.precision(.fractionLength(2))) }.joined(separator: " / ")])).font(.caption)
                    }
                    if let battery = snapshot.battery {
                        MeterView(title: tr("general.battery"), fraction: battery,
                                  caption: battery.formatted(.percent.precision(.fractionLength(0))), tint: .green)
                    }
                    Text(tr("general.volumes")).font(.headline)
                    ForEach(snapshot.volumes) { volume in
                        HStack { Text(volume.path).font(.caption); Spacer()
                            Button(tr("general.explore_volume")) {
                                model.area = .explorer; model.choose(URL(fileURLWithPath: volume.path))
                            }.controlSize(.small)
                        }
                        MeterView(title: volume.path, fraction: volume.total > 0 ? 1 - Double(volume.free) / Double(volume.total) : 0,
                                  caption: tr("header.disk_free", ["size": Fmt.disk(volume.free)]), tint: .orange)
                    }
                    Text(tr("general.network")).font(.headline)
                    Text(tr("general.network_notice")).font(.caption2).foregroundStyle(.secondary)
                    ForEach(model.network) { rate in
                        HStack {
                            Text(rate.id)
                            Spacer()
                            Text("↓ \(Fmt.memory(Int64(rate.received)))/s   ↑ \(Fmt.memory(Int64(rate.sent)))/s")
                        }.font(.caption.monospacedDigit())
                    }
                    Text(tr("general.top_processes")).font(.headline)
                    ForEach(Array(snapshot.processes.prefix(15))) { process in
                        HStack {
                            Text(process.exeName).lineLimit(1)
                            Spacer()
                            Text(String(format: "%.1f%%", process.cpu))
                            Text(Fmt.memory(process.rssBytes))
                        }.font(.caption.monospacedDigit())
                    }
                    Text(tr("general.monitor_limits")).font(.caption2).foregroundStyle(.secondary)
                }
            } else { ProgressView(tr("general.sampling")).padding(30) }
        }
    }
}
