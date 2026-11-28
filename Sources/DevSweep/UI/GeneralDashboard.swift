import AppKit
import Charts
import SwiftUI

struct GeneralDashboard: View {
    @EnvironmentObject private var app: AppModel
    @StateObject private var model = GeneralModel()
    @State private var review: [GeneralEntry] = []
    @State private var showingReview = false
    @State private var historyVisible = false
    @State private var exportError: String?
    @State private var copiedOutput = false

    private static let cleanupAreas: [GeneralArea] = [.logs, .caches, .temporaries, .trash, .external, .projects]
    private static let exploreAreas: [GeneralArea] = [.explorer, .installers, .applications, .orphans]
    private static let systemAreas: [GeneralArea] = [.monitor, .maintenance, .maintenanceFiles]
    private static let folderAwareAreas: Set<GeneralArea> = [.logs, .caches, .explorer, .installers, .projects, .external]

    private var sidebarSelection: Binding<GeneralArea?> {
        Binding(
            get: { model.area },
            set: { newArea in
                guard let newArea, newArea != model.area else { return }
                model.cancel()
                model.area = newArea
                model.search = ""
                model.selected = []
            }
        )
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 250)
        } detail: {
            detailContent
        }
        .frame(minWidth: 920, minHeight: 620)
        .task(id: model.area.rawValue + (model.area == .applications ? model.uninstallApplication?.path ?? "" : "") + (model.area == .maintenanceFiles ? model.maintenanceFileTask.rawValue : "")) {
            if model.area == .monitor {
                while !Task.isCancelled {
                    await model.refreshMonitor()
                    try? await Task.sleep(for: .seconds(5))
                }
            } else if model.area != .maintenance {
                await model.scan()
            }
        }
        .onDisappear { model.cancel(); model.stopMonitorRecording() }
        .onChange(of: model.area) { _, area in if area != .monitor { model.stopMonitorRecording() } }
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

    private var sidebar: some View {
        List(selection: sidebarSelection) {
            Section(tr("sidebar.section.cleanup")) {
                ForEach(Self.cleanupAreas) { area in
                    Label(area.title, systemImage: area.icon).tag(area)
                }
            }
            Section(tr("sidebar.section.explore")) {
                ForEach(Self.exploreAreas) { area in
                    Label(area.title, systemImage: area.icon).tag(area)
                }
            }
            Section(tr("sidebar.section.system")) {
                ForEach(Self.systemAreas) { area in
                    Label(area.title, systemImage: area.icon).tag(area)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 8) {
                Image(nsImage: MenuBarLabel.brandIcon)
                    .foregroundStyle(.tint)
                Text("Zelvo")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                Button {
                    historyVisible = true
                } label: {
                    Label(tr("cleanup.history"), systemImage: "clock.arrow.circlepath")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
    }

    private var detailContent: some View {
        VStack(spacing: 0) {
            if Self.folderAwareAreas.contains(model.area) {
                contextStrip
                Divider()
            }

            Group {
                if model.area == .monitor {
                    GeneralMonitorView(model: model)
                } else if model.area == .maintenance {
                    maintenance
                } else {
                    results
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let error = exportError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                    Spacer()
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 6)
            }
            if let banner = app.banner {
                BannerView(text: banner)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 8)
            }
            CleanupStatusView()
        }
        .navigationTitle(model.area.title)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if model.scanning || model.runningMaintenance != nil {
                    ProgressView().controlSize(.small)
                    Button(tr("general.cancel")) { model.cancel() }
                } else if model.area != .maintenance {
                    Button {
                        Task {
                            if model.area == .monitor { await model.refreshMonitor() }
                            else { await model.scan(force: true) }
                        }
                    } label: {
                        Label(tr("header.scan_now"), systemImage: "arrow.clockwise")
                    }
                    .help(tr("header.scan_now"))
                }

                if Self.folderAwareAreas.contains(model.area) {
                    Button {
                        chooseFolder()
                    } label: {
                        Label(tr("general.choose_folder"), systemImage: "folder.badge.plus")
                    }
                    .disabled(model.scanning)
                    .help(tr("general.choose_folder"))
                }

                if model.area != .maintenance {
                    if model.area == .monitor {
                        if model.recordingMonitor {
                            StatusBadge(text: tr("monitor.recording_badge"), systemImage: "record.circle.fill", color: .red)
                        }
                        Menu {
                            Button("JSON") { export() }
                            Button("NDJSON") { export(ndjson: true) }.disabled(!model.hasMonitorHistory)
                            Divider()
                            if model.recordingMonitor {
                                Button(tr("hardware.stop_recording")) { model.stopMonitorRecording() }
                            } else {
                                Button(tr("hardware.record")) { recordMonitor() }
                            }
                        } label: {
                            Label(tr("general.export"), systemImage: "square.and.arrow.up")
                        }
                        .disabled(model.monitor == nil)
                    } else {
                        Button {
                            export()
                        } label: {
                            Label(tr("general.export"), systemImage: "square.and.arrow.up")
                        }
                        .disabled(model.scanning)
                    }
                }

                Button {
                    historyVisible = true
                } label: {
                    Label(tr("cleanup.history"), systemImage: "clock.arrow.circlepath")
                }
                .help(tr("cleanup.history"))
            }
        }
    }

    private var contextStrip: some View {
        HStack(spacing: 8) {
            if model.area == .explorer {
                Button {
                    model.choose(model.root.deletingLastPathComponent())
                    Task { await model.scan() }
                } label: {
                    Image(systemName: "arrow.up")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.scanning)
            }
            Image(systemName: "folder")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(contextPathText)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            if model.area == .explorer, let volume = model.volume {
                MetricPill(
                    label: volume.path,
                    value: tr("header.disk_free", ["size": Fmt.disk(volume.free)]),
                    systemImage: "internaldrive"
                )
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.6))
    }

    private var contextPathText: String {
        if model.area == .projects {
            return PrefsSnapshot.current().projectRoots.joined(separator: " · ")
        }
        if [.logs, .caches, .installers].contains(model.area) && model.roots[model.area] == nil {
            return tr("general.known_roots")
        }
        return model.root.path
    }

    private var results: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                areaNotices
                filterCard

                let issues = model.report.issues + (model.scanning ? [] : model.measurementIssues)
                if !issues.isEmpty {
                    DisclosureGroup(tr("general.issues", ["count": issues.count])) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                                    Text(issue).font(.caption2.monospaced()).textSelection(.enabled)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 96)
                    }
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(10)
                    .technicalCard(cornerRadius: 8, tint: .orange)
                }

                if model.visible.isEmpty && !model.scanning {
                    ContentUnavailableView(
                        tr("general.no_results"),
                        systemImage: "magnifyingglass",
                        description: Text(tr("general.no_results_help"))
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    let maxBytes = model.visible.compactMap {
                        model.measurements[$0.id]?.state == .complete ? model.measurements[$0.id]?.bytes : nil
                    }.max() ?? 0
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(model.visible) { entry in
                                row(entry, maxBytes: maxBytes)
                            }
                        }
                        .padding(.bottom, 8)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            resultsFooter
        }
    }

    @ViewBuilder
    private var areaNotices: some View {
        if model.area == .applications {
            if model.uninstallApplication != nil {
                TechnicalCard(cornerRadius: 8, padding: 10) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Button {
                                model.uninstallApplication = nil
                            } label: {
                                Label(tr("uninstall.back"), systemImage: "chevron.left")
                            }
                            .controlSize(.small)
                            Spacer()
                        }
                        Text(tr("uninstall.notice")).font(.caption).foregroundStyle(.secondary)
                        Text(tr("references.notice")).font(.caption).foregroundStyle(.secondary)
                        if !model.report.referencesComplete {
                            Text(tr("references.partial")).font(.caption).foregroundStyle(.orange)
                        }
                        ForEach(model.report.references) { reference in
                            HStack {
                                Text(tr("references.location", ["path": reference.path, "line": reference.line]))
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                Spacer()
                                Button(tr("storage.show_in_finder")) {
                                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: reference.path)])
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                }
            } else {
                Text(tr("uninstall.open_help")).font(.caption).foregroundStyle(.secondary)
            }
        }
        if model.area == .installers {
            Text(tr("installer.notice")).font(.caption).foregroundStyle(.secondary)
        }
        if model.area == .maintenanceFiles {
            TechnicalCard(cornerRadius: 8, padding: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    Picker(tr("general.maintenance"), selection: $model.maintenanceFileTask) {
                        ForEach(MaintenanceTask.allCases.filter { $0.reviewsFiles || $0 == .launchAgents }) {
                            Text($0.title).tag($0)
                        }
                    }
                    .disabled(model.scanning)
                    Text(tr("maintenance.files_notice")).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        if model.area == .orphans { Text(tr("orphans.notice")).font(.caption).foregroundStyle(.secondary) }
        if model.area == .temporaries { Text(tr("hygiene.temp_notice")).font(.caption).foregroundStyle(.secondary) }
        if model.area == .trash { Text(tr("hygiene.trash_notice")).font(.caption).foregroundStyle(.secondary) }
        if model.area == .external { Text(tr("hygiene.external_notice")).font(.caption).foregroundStyle(.secondary) }
    }

    private var filterCard: some View {
        TechnicalCard(cornerRadius: 10, padding: 10) {
            VStack(alignment: .leading, spacing: 8) {
                if model.area == .explorer {
                    explorerControls
                    Divider()
                }

                HStack(spacing: 10) {
                    TextField(tr("general.search"), text: $model.search)
                        .textFieldStyle(.roundedBorder)

                    Text(tr("general.count", ["count": model.report.entries.count, "inspected": model.report.inspected]))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    scanStatusBadge
                }

                if model.scanning && !model.currentPath.isEmpty {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text(model.currentPath)
                            .font(.caption2.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                    }
                }

                if model.area == .installers || (model.area == .explorer && model.explorerMode == .largeFiles) {
                    HStack(spacing: 8) {
                        Button {
                            Task { await model.estimateVisibleFiles() }
                        } label: {
                            Label(tr("footprint.calculate"), systemImage: "sum")
                        }
                        .controlSize(.small)
                        .disabled(model.scanning || model.calculatingFileSpace || model.visible.isEmpty)
                        if model.calculatingFileSpace { ProgressView().controlSize(.mini) }
                        Spacer()
                    }
                    if let estimate = model.fileSpaceEstimate {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(tr("footprint.summary", [
                                "size": Fmt.disk(estimate.allocatedBytes),
                                "count": estimate.uniqueFiles,
                                "possible": Fmt.disk(estimate.potentialAfterTrashBytes),
                            ]))
                            .font(.caption.monospacedDigit().weight(.medium))
                            .textSelection(.enabled)
                            Text(tr("footprint.links", ["count": estimate.linksOutsideSelection]))
                                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            if estimate.deduplicatedClones > 0 {
                                Text(tr("footprint.clones", ["count": estimate.deduplicatedClones]))
                                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            if !estimate.complete {
                                Text(tr("footprint.partial")).font(.caption2).foregroundStyle(.orange)
                            }
                            Text(tr("footprint.notice")).font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(.top, 2)
                    }
                }
            }
        }
    }

    private var scanStatusBadge: some View {
        let label: String
        let color: Color
        if model.scanning {
            label = tr("storage.measuring")
            color = .orange
        } else if !model.report.complete {
            label = tr("general.partial_badge")
            color = .orange
        } else if model.fullyMeasured {
            label = tr("general.complete_badge")
            color = .green
        } else {
            label = tr("explorer.partial_measurement")
            color = .orange
        }
        return StatusBadge(text: label, color: color)
            .help(model.scanning ? tr("storage.measuring") : !model.report.complete ? tr("general.partial") : tr("general.complete"))
    }

    private var explorerControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(tr("explorer.mode"), selection: $model.explorerMode) {
                ForEach(ExplorerMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(model.scanning)

            HStack(spacing: 8) {
                Picker(tr("explorer.minimum"), selection: $model.explorerFilter.minimumBytes) {
                    Text(tr("explorer.any_size")).tag(Int64(0))
                    Text("100 MB").tag(Int64(100 * 1_048_576))
                    Text("1 GB").tag(Int64(1_073_741_824))
                    Text("5 GB").tag(Int64(5 * 1_073_741_824))
                }
                .disabled(model.scanning)
                Picker(tr("explorer.age"), selection: $model.explorerFilter.olderThanDays) {
                    Text(tr("explorer.any_date")).tag(0)
                    Text(tr("explorer.days", ["count": 30])).tag(30)
                    Text(tr("explorer.days", ["count": 90])).tag(90)
                    Text(tr("explorer.days", ["count": 365])).tag(365)
                }
                Picker(tr("explorer.order"), selection: $model.explorerSort) {
                    ForEach(ExplorerSort.allCases) { Text($0.title).tag($0) }
                }
            }
            .controlSize(.small)

            HStack(spacing: 10) {
                TextField(tr("explorer.extensions"), text: $model.explorerFilter.extensions)
                    .textFieldStyle(.roundedBorder)
                Text(tr("explorer.showing", ["visible": model.visible.count, "total": model.report.entries.count]))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let volume = model.volume {
                Text(tr("explorer.volume", ["path": volume.path, "free": Fmt.disk(volume.free), "total": Fmt.disk(volume.total)]))
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if model.explorerMode == .largeFiles {
                Text(tr("explorer.recursive_notice")).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ entry: GeneralEntry, maxBytes: Int64) -> some View {
        let measurement = model.measurements[entry.id]
        let fraction: Double = {
            guard maxBytes > 0, let m = measurement, m.state == .complete, m.bytes > 0 else { return 0 }
            return Double(m.bytes) / Double(maxBytes)
        }()

        return HStack(alignment: .center, spacing: 10) {
            Toggle("", isOn: Binding(get: { model.selected.contains(entry.id) }, set: {
                if $0 { model.selected.insert(entry.id) } else { model.selected.remove(entry.id) }
            }))
            .labelsHidden()
            .toggleStyle(.checkbox)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(entry.target.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    if !entry.removable {
                        StatusBadge(text: tr("general.read_only_badge"), color: .orange)
                            .help(tr("general.read_only"))
                    }
                    if let source = entry.installerSource {
                        StatusBadge(text: source.title, color: .blue)
                    }
                    if let association = entry.association {
                        StatusBadge(text: association.kind.title, color: association.kind.personal ? .orange : .secondary)
                    }
                }

                Text(entry.url.path)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)

                HStack(spacing: 8) {
                    if let date = entry.modified {
                        Text(date, format: .dateTime.day().month().year())
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    if let association = entry.association {
                        Text(association.evidence)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                if maxBytes > 0, measurement?.state == .complete {
                    ProportionalBar(
                        fraction: fraction,
                        tint: entry.removable ? Color.accentColor : Color.secondary,
                        height: 3.5
                    )
                    .padding(.top, 1)
                }
            }

            Spacer(minLength: 8)

            if model.area == .applications && model.uninstallApplication == nil && entry.removable {
                Button(tr("uninstall.inspect")) { model.uninstallApplication = entry.url }
                    .controlSize(.small)
                    .disabled(model.scanning)
            }

            Group {
                if let measurement {
                    MeasurementLabel(measurement: measurement)
                        .font(.callout.monospacedDigit().weight(.semibold))
                } else if model.scanning {
                    ProgressView().controlSize(.mini)
                } else {
                    Text(tr("storage.unavailable"))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .frame(minWidth: 72, alignment: .trailing)

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([entry.url])
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help(tr("storage.show_in_finder"))

            if model.area == .explorer, (try? entry.url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                Button {
                    model.choose(entry.url)
                    Task { await model.scan() }
                } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.borderless)
                .disabled(model.scanning)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .technicalCard(cornerRadius: 9)
    }

    private var resultsFooter: some View {
        let selectedBytes = model.visible
            .filter { model.selected.contains($0.id) }
            .reduce(Int64(0)) { $0 + (model.measurements[$1.id]?.bytes ?? 0) }

        return VStack(spacing: 0) {
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Button(tr("review.select_all")) {
                        model.selected = Set(model.visible.filter { $0.association?.kind.personal != true }.map(\.id))
                    }
                    Button(tr("review.select_none")) { model.selected = [] }
                    Spacer()
                    if !model.selected.isEmpty {
                        Text(tr("general.selected_summary", ["count": model.selected.count, "size": Fmt.disk(selectedBytes)]))
                            .font(.caption.monospacedDigit().weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    Button(tr("general.review_count", ["count": model.selected.count])) {
                        review = model.report.entries.filter { model.selected.contains($0.id) }
                        showingReview = true
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.selected.isEmpty || model.scanning || !model.report.complete)
                }
                .controlSize(.small)

                Text(tr("general.removal_notice"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(.regularMaterial)
        }
    }

    private var reviewSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(tr("review.title")).font(.headline)
                Spacer()
                Button(tr("review.close")) { showingReview = false }
            }
            Text(tr("general.removal_notice")).font(.caption).foregroundStyle(.secondary)
            if model.area == .applications {
                Text(model.uninstallApplication == nil ? tr("general.app_data_kept") : tr("uninstall.notice")).font(.caption)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(review) { entry in
                        HStack {
                            Text(entry.url.path)
                                .font(.caption.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                            if let association = entry.association {
                                StatusBadge(text: association.kind.title, color: association.kind.personal ? .orange : .secondary)
                            }
                            Spacer()
                            if let size = model.measurements[entry.id] {
                                MeasurementLabel(measurement: size)
                                    .font(.caption.monospacedDigit().weight(.medium))
                            }
                        }
                        .padding(8)
                        .technicalCard(cornerRadius: 7)
                    }
                }
            }
            let eligible = review.filter { $0.removable && model.measurements[$0.id]?.state == .complete }
            ActionButton(
                title: tr("general.trash_count", ["count": eligible.count]),
                symbol: "trash",
                confirm: true,
                busy: app.cleanupProgress != nil
            ) {
                showingReview = false
                let ordered = eligible.sorted { ($0.association?.kind == .application ? 1 : 0) < ($1.association?.kind == .application ? 1 : 0) }
                Task {
                    await app.cleanGeneral(ordered.map(\.target))
                    if model.area == .applications { model.uninstallApplication = nil }
                    await model.scan(force: true)
                }
            }
            .disabled(eligible.isEmpty || !model.report.complete || app.isScanningStorage || app.isPerformingAll)
        }
        .padding(18)
        .frame(width: 650, height: 460)
    }

    private var maintenance: some View {
        let diagnosticTasks = MaintenanceTask.allCases.filter { !$0.requiresAdmin && !$0.changesState }
        let userTasks = MaintenanceTask.allCases.filter { !$0.requiresAdmin && $0.changesState }
        let adminTasks = MaintenanceTask.allCases.filter { $0.requiresAdmin }

        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                optimizeHeroCard

                Text(tr("maintenance.notice"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                maintenanceGroup(
                    title: tr("maintenance.group.diagnostic"),
                    systemImage: "stethoscope",
                    tint: .blue,
                    tasks: diagnosticTasks
                )
                maintenanceGroup(
                    title: tr("maintenance.group.user"),
                    systemImage: "wrench.and.screwdriver",
                    tint: .green,
                    tasks: userTasks
                )
                maintenanceGroup(
                    title: tr("maintenance.group.system"),
                    systemImage: "lock.shield",
                    tint: .orange,
                    tasks: adminTasks
                )

                if !model.maintenanceOutput.isEmpty {
                    maintenanceConsole
                }
            }
            .padding(18)
        }
    }

    private var optimizeHeroCard: some View {
        TechnicalCard(cornerRadius: 12, tint: .accentColor, padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "bolt.shield.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 40, height: 40)
                        .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tr("optimize.title")).font(.headline)
                        Text(tr("optimize.subtitle")).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.optimizing {
                        Button(tr("general.cancel")) { model.cancel() }.controlSize(.small)
                    } else {
                        Button {
                            Task { await model.runAutoOptimize() }
                        } label: {
                            Label(tr("optimize.run_now"), systemImage: "bolt.shield")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                        .disabled(model.runningMaintenance != nil)
                    }
                }

                if let progress = model.optimizeProgress {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: Double(progress.completed), total: Double(max(progress.total, 1)))
                        if !progress.currentTitle.isEmpty {
                            Text(tr("optimize.running_step", [
                                "current": progress.completed + 1,
                                "total": progress.total,
                                "task": progress.currentTitle,
                            ]))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        }
                    }
                }

                if !model.performanceFindings.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        Label(tr("optimize.diag_header"), systemImage: "exclamationmark.triangle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                        ForEach(model.performanceFindings) { finding in
                            Text("• \(finding.title): \(finding.detail)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .technicalCard(cornerRadius: 8, tint: .orange)
                }

                if !model.optimizeResults.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(model.optimizeResults) { step in
                            HStack(spacing: 8) {
                                Image(systemName: step.status == .succeeded ? "checkmark.circle.fill" : (step.status == .skipped ? "minus.circle.fill" : "exclamationmark.triangle.fill"))
                                    .foregroundStyle(step.status == .succeeded ? .green : (step.status == .skipped ? .secondary : .orange))
                                    .font(.caption)
                                Text(step.task.title)
                                    .font(.caption.weight(.medium))
                                Spacer(minLength: 6)
                                Text(step.summary)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                StatusBadge(
                                    text: step.status.rawValue,
                                    color: step.status == .succeeded ? .green : (step.status == .skipped ? .secondary : .orange)
                                )
                            }
                        }
                    }
                    .padding(.top, 2)
                }
            }
        }
    }

    private func maintenanceGroup(title: String, systemImage: String, tint: Color, tasks: [MaintenanceTask]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeaderView(title: title, systemImage: systemImage, tint: tint)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 10)], spacing: 10) {
                ForEach(tasks) { task in
                    maintenanceTaskCard(task)
                }
            }
        }
    }

    private func maintenanceTaskCard(_ task: MaintenanceTask) -> some View {
        let badgeText = task.requiresAdmin
            ? tr("maintenance.badge.admin")
            : task.changesState ? tr("maintenance.badge.changes_state") : tr("maintenance.badge.read_only")
        let badgeColor: Color = task.requiresAdmin ? .orange : (task.changesState ? .blue : .secondary)

        return TechnicalCard(cornerRadius: 9, padding: 10) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(task.title)
                            .font(.system(size: 12.5, weight: .medium))
                            .lineLimit(2)
                    }
                    HStack(spacing: 6) {
                        StatusBadge(text: badgeText, color: badgeColor)
                        Text(task.requiresAdmin ? tr("maintenance.admin") : task.changesState ? tr("maintenance.explicit_action") : tr("maintenance.read_only"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 4) {
                    ActionButton(
                        title: task.changesState ? tr("maintenance.run") : tr("maintenance.inspect"),
                        symbol: task.changesState ? "wrench" : "magnifyingglass",
                        confirm: task.changesState || task.requiresAdmin,
                        busy: model.runningMaintenance == task
                    ) {
                        Task { await model.runMaintenance(task) }
                    }
                    .disabled(model.runningMaintenance != nil || model.optimizing)

                    if task.reviewsFiles || task == .launchAgents {
                        Button(tr("maintenance.review_files")) {
                            model.maintenanceFileTask = task
                            model.area = .maintenanceFiles
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    private var maintenanceConsole: some View {
        TechnicalCard(cornerRadius: 10, padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeaderView(
                    title: tr("maintenance.output_title"),
                    systemImage: "terminal",
                    tint: .secondary
                ) {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.maintenanceOutput, forType: .string)
                        copiedOutput = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedOutput = false }
                    } label: {
                        Label(
                            copiedOutput ? tr("maintenance.copied") : tr("maintenance.copy_output"),
                            systemImage: copiedOutput ? "checkmark" : "doc.on.doc"
                        )
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Divider()
                Text(model.maintenanceOutput)
                    .font(.system(size: 11.5, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = model.area == .projects
        guard panel.runModal() == .OK, let first = panel.urls.first else { return }
        if model.area == .projects {
            let roots = panel.urls.map { $0.resolvingSymlinksInPath().path }
            Prefs.defaults.set(roots.joined(separator: "\n"), forKey: Prefs.Key.projectRoots)
            Prefs.defaults.set(true, forKey: Prefs.Key.workspacesConfirmed)
            app.prefsChanged()
        } else {
            model.choose(first)
        }
        Task { await model.scan(force: true) }
    }

    private func recordMonitor() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "zelvo-monitor.ndjson"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do { try await model.startMonitorRecording(to: url) }
            catch { exportError = error.localizedDescription }
        }
    }

    private func export(ndjson: Bool = false) {
        do {
            let data = ndjson ? model.exportMonitorHistory() : try model.exportData()
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "zelvo-" + model.area.rawValue + (ndjson ? ".ndjson" : ".json")
            if panel.runModal() == .OK, let url = panel.url { try data.write(to: url, options: .atomic) }
        } catch {
            exportError = error.localizedDescription
        }
    }
}

private struct GeneralMonitorView: View {
    @ObservedObject var model: GeneralModel
    @State private var pulse = false

    var body: some View {
        ScrollView {
            if let snapshot = model.monitor {
                VStack(alignment: .leading, spacing: 14) {
                    if !model.monitoringError.isEmpty {
                        TechnicalCard(cornerRadius: 8, tint: .orange, padding: 10) {
                            Label(model.monitoringError, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }

                    diagnosticsCard(snapshot: snapshot)
                    cpuCard
                    primaryHardwareGrid(snapshot: snapshot)
                    volumesCard(snapshot: snapshot)
                    HardwarePanel(model: model)
                }
                .padding(18)
            } else {
                ProgressView(tr("general.sampling"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(40)
            }
        }
    }

    private func diagnosticsCard(snapshot: MonitorSnapshot) -> some View {
        let diag = model.diagnostics
        let hasCritical = diag?.findings.contains(where: { $0.severity == .critical }) ?? false
        let tint: Color = {
            guard let diag else { return .secondary }
            switch diag.status {
            case .noAlerts: return .green
            case .incomplete: return .orange
            case .attention: return hasCritical ? .red : .orange
            }
        }()
        let thermalTint: Color = {
            switch snapshot.thermalLevel {
            case 2: return .orange
            case 3: return .red
            case 0, 1: return .green
            default: return .secondary
            }
        }()

        return TechnicalCard(cornerRadius: 11, tint: tint, padding: 12) {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeaderView(
                    title: diag?.title ?? tr("diagnostics.title"),
                    subtitle: tr("diagnostics.title"),
                    systemImage: diag?.status == .noAlerts ? "checkmark.shield.fill" : "exclamationmark.shield.fill",
                    tint: tint
                ) {
                    HStack(spacing: 6) {
                        if model.recordingMonitor {
                            StatusBadge(text: tr("monitor.recording_badge"), systemImage: "record.circle.fill", color: .red)
                                .opacity(pulse ? 0.5 : 1.0)
                                .onAppear {
                                    withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
                                }
                                .onDisappear { pulse = false }
                        }
                        Text(snapshot.date, format: .dateTime.hour().minute().second())
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 155), spacing: 8)], spacing: 8) {
                    TelemetryStatTile(
                        title: tr("monitor.uptime_short"),
                        value: Fmt.duration(snapshot.uptime),
                        systemImage: "clock"
                    )
                    TelemetryStatTile(
                        title: tr("monitor.load_short"),
                        value: snapshot.load.isEmpty
                            ? tr("storage.unavailable")
                            : snapshot.load.map { $0.formatted(.number.precision(.fractionLength(2))) }.joined(separator: " / "),
                        systemImage: "gauge.medium"
                    )
                    TelemetryStatTile(
                        title: tr("diagnostics.thermal_label"),
                        value: snapshot.thermal,
                        systemImage: "thermometer.medium",
                        tint: thermalTint
                    )
                    TelemetryStatTile(
                        title: tr("diagnostics.pressure_label"),
                        value: snapshot.system.pressureAvailable ? snapshot.system.pressure.label : tr("storage.unavailable"),
                        systemImage: "memorychip",
                        tint: snapshot.system.pressureAvailable ? snapshot.system.pressure.color : .secondary
                    )
                }

                if let diag, !diag.findings.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(diag.findings) { finding in
                            Label(
                                finding.message,
                                systemImage: finding.severity == .critical ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill"
                            )
                            .font(.caption)
                            .foregroundStyle(finding.severity == .critical ? Color.red : Color.orange)
                        }
                    }
                }

                if let diag, !diag.unavailable.isEmpty {
                    Text(tr("diagnostics.unavailable", ["metrics": diag.unavailable.map(MonitorDiagnostics.label).joined(separator: ", ")]))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Text(tr("diagnostics.notice"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var cpuCard: some View {
        let aggregate = model.cpu.flatMap { cores -> Double? in
            guard !cores.isEmpty else { return nil }
            return cores.reduce(0, +) / Double(cores.count)
        }

        return TechnicalCard(cornerRadius: 11, tint: model.sustainedCPU ? .orange : nil, padding: 12) {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeaderView(
                    title: tr("monitor.cpu_title"),
                    subtitle: tr("hardware.cpu_history"),
                    systemImage: "cpu",
                    tint: model.sustainedCPU ? .orange : .blue
                ) {
                    HStack(spacing: 8) {
                        if model.sustainedCPU {
                            StatusBadge(text: tr("hardware.cpu_alert"), systemImage: "flame.fill", color: .orange)
                        }
                        Text(aggregate.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? tr("general.sampling"))
                            .font(.title2.monospacedDigit().bold())
                            .foregroundStyle(model.sustainedCPU ? Color.orange : Color.primary)
                    }
                }

                if !model.cpuHistory.isEmpty {
                    let samples = Array(model.cpuHistory.enumerated())
                    Chart {
                        ForEach(samples, id: \.offset) { index, value in
                            AreaMark(
                                x: .value("Sample", index),
                                y: .value("CPU", value)
                            )
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [Color.accentColor.opacity(0.30), Color.accentColor.opacity(0.02)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            LineMark(
                                x: .value("Sample", index),
                                y: .value("CPU", value)
                            )
                            .foregroundStyle(Color.accentColor)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                        }
                        RuleMark(y: .value("Alert", 0.9))
                            .foregroundStyle(.orange.opacity(0.85))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    }
                    .chartYScale(domain: 0...1)
                    .chartXAxis(.hidden)
                    .chartYAxis {
                        AxisMarks(values: [0, 0.5, 0.9, 1.0]) { value in
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                            AxisValueLabel {
                                if let v = value.as(Double.self) {
                                    Text(v.formatted(.percent.precision(.fractionLength(0))))
                                        .font(.caption2.monospacedDigit())
                                }
                            }
                        }
                    }
                    .frame(height: 110)
                    .accessibilityLabel(tr("hardware.cpu_history"))
                    .accessibilityValue(aggregate.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? tr("general.sampling"))
                } else {
                    Text(tr("general.sampling"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                }

                if let cores = model.cpu, !cores.isEmpty {
                    Divider()
                    Text(tr("monitor.cores_title"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 8)], spacing: 6) {
                        ForEach(Array(cores.enumerated()), id: \.offset) { index, fraction in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(tr("general.core", ["number": index + 1]))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    Spacer(minLength: 2)
                                    Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                                        .font(.caption2.monospacedDigit().weight(.medium))
                                }
                                ProportionalBar(
                                    fraction: fraction,
                                    tint: fraction > 0.9 ? .red : (fraction > 0.7 ? .orange : .blue),
                                    height: 4
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    private func primaryHardwareGrid(snapshot: MonitorSnapshot) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 12)], spacing: 12) {
            memoryCard(snapshot: snapshot)
            gpuAndBatteryCard(snapshot: snapshot)
        }
    }

    private func memoryCard(snapshot: MonitorSnapshot) -> some View {
        let system = snapshot.system
        return TechnicalCard(cornerRadius: 11, padding: 12) {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeaderView(
                    title: tr("monitor.memory_title"),
                    systemImage: "memorychip",
                    tint: .purple
                ) {
                    StatusBadge(
                        text: system.pressureAvailable ? system.pressure.label : tr("storage.unavailable"),
                        color: system.pressureAvailable ? system.pressure.color : .secondary
                    )
                }

                if system.memoryAvailable {
                    MeterView(
                        title: tr("general.memory"),
                        fraction: system.memFraction,
                        caption: "\(Fmt.memory(system.memUsed)) / \(Fmt.memory(system.memTotal))",
                        tint: system.memoryTight ? system.pressure.color : .purple
                    )
                } else {
                    HStack {
                        Text(tr("general.memory")).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(tr("storage.unavailable")).font(.caption).foregroundStyle(.orange)
                    }
                }

                FlowLayout(spacing: 8) {
                    MetricPill(
                        label: tr("monitor.cache_label"),
                        value: system.memCache.map { Fmt.memory($0) } ?? tr("storage.unavailable"),
                        systemImage: "tray.full"
                    )
                    MetricPill(
                        label: tr("monitor.swap_label"),
                        value: snapshot.swap.map { Fmt.memory(Int64(clamping: $0)) } ?? tr("storage.unavailable"),
                        systemImage: "arrow.left.arrow.right"
                    )
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private func gpuAndBatteryCard(snapshot: MonitorSnapshot) -> some View {
        let hardware = snapshot.hardware
        return TechnicalCard(cornerRadius: 11, padding: 12) {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeaderView(
                    title: tr("monitor.gpu_battery_title"),
                    systemImage: "bolt.batteryblock",
                    tint: .green
                )

                if hardware.gpus.isEmpty {
                    Text(tr("hardware.gpu_unavailable"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(hardware.gpus) { gpu in
                        if let fraction = gpu.utilization {
                            MeterView(
                                title: gpu.name,
                                fraction: fraction,
                                caption: fraction.formatted(.percent.precision(.fractionLength(0))),
                                tint: .green
                            )
                        } else {
                            HStack {
                                Text(gpu.name).font(.caption).lineLimit(1)
                                Spacer()
                                Text(tr("hardware.gpu_unavailable")).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Divider()

                if let batteryFraction = snapshot.battery {
                    let ratio = hardware.battery?.capacityRatio
                    let healthTint: Color = (ratio ?? 1) < 0.8 ? .orange : .green
                    MeterView(
                        title: tr("general.battery"),
                        fraction: batteryFraction,
                        caption: batteryFraction.formatted(.percent.precision(.fractionLength(0))),
                        tint: batteryFraction < 0.2 ? .orange : .green
                    )
                    FlowLayout(spacing: 6) {
                        if snapshot.charging == true {
                            StatusBadge(text: tr("monitor.battery_charging"), systemImage: "bolt.fill", color: .green)
                        }
                        if let cycles = hardware.battery?.cycles {
                            Text(tr("hardware.cycles", ["count": cycles]))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        if let ratio {
                            StatusBadge(
                                text: tr("hardware.capacity", ["value": ratio.formatted(.percent.precision(.fractionLength(0)))]),
                                color: healthTint
                            )
                        }
                    }
                } else if let battery = hardware.battery {
                    FlowLayout(spacing: 6) {
                        if let cycles = battery.cycles {
                            Text(tr("hardware.cycles", ["count": cycles]))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        if let ratio = battery.capacityRatio {
                            StatusBadge(
                                text: tr("hardware.capacity", ["value": ratio.formatted(.percent.precision(.fractionLength(0)))]),
                                color: ratio < 0.8 ? .orange : .green
                            )
                        }
                    }
                } else {
                    Text(tr("storage.unavailable"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private func volumesCard(snapshot: MonitorSnapshot) -> some View {
        TechnicalCard(cornerRadius: 11, padding: 12) {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeaderView(
                    title: tr("general.volumes"),
                    systemImage: "internaldrive",
                    tint: .orange
                )

                if snapshot.volumes.isEmpty {
                    Text(tr("storage.unavailable")).font(.caption).foregroundStyle(.secondary)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 10)], spacing: 10) {
                        ForEach(snapshot.volumes) { volume in
                            let usedFraction = volume.total > 0 ? 1 - Double(volume.free) / Double(volume.total) : 0
                            let lowSpace = volume.total > 0 && Double(volume.free) / Double(volume.total) <= 0.10
                            TechnicalCard(cornerRadius: 8, padding: 10) {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(spacing: 6) {
                                        Text(volume.path)
                                            .font(.caption.monospaced().weight(.semibold))
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        if volume.readOnly {
                                            StatusBadge(text: tr("general.read_only_badge"), color: .secondary)
                                        }
                                        Spacer()
                                        Button(tr("general.explore_volume")) {
                                            model.area = .explorer
                                            model.choose(URL(fileURLWithPath: volume.path))
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.mini)
                                    }
                                    ProportionalBar(
                                        fraction: usedFraction,
                                        tint: lowSpace ? .red : .orange,
                                        height: 5
                                    )
                                    HStack {
                                        Text(tr("header.disk_free", ["size": Fmt.disk(volume.free)]))
                                            .font(.caption.monospacedDigit().weight(.medium))
                                            .foregroundStyle(lowSpace ? Color.red : Color.primary)
                                        Spacer()
                                        Text(Fmt.disk(volume.total))
                                            .font(.caption2.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }

                if !model.smartStatus.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Text("SMART")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        FlowLayout(spacing: 6) {
                            ForEach(model.smartStatus.keys.sorted(), id: \.self) { disk in
                                let status = model.smartStatus[disk] ?? tr("storage.unavailable")
                                let isFailing = status.lowercased() == "failing"
                                StatusBadge(
                                    text: "\(disk): \(status)",
                                    systemImage: isFailing ? "exclamationmark.triangle.fill" : (status.lowercased() == "verified" ? "checkmark.circle.fill" : "minus.circle"),
                                    color: isFailing ? .red : (status.lowercased() == "verified" ? .green : .secondary)
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}
