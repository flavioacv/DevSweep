import Foundation

@MainActor
final class GeneralModel: ObservableObject {
    @Published var area: GeneralArea = .logs { didSet { invalidateFileSpaceEstimate() } }
    @Published var search = "" { didSet { invalidateFileSpaceEstimate() } }
    @Published var selected: Set<String> = [] { didSet { invalidateFileSpaceEstimate() } }
    @Published var uninstallApplication: URL?
    @Published var maintenanceFileTask: MaintenanceTask = .savedStates
    @Published private(set) var monitoringError = ""
    private var monitoringRecords: [Data] = []
    @Published private(set) var recordingMonitor = false
    private var recordingURL: URL?
    private var recordingIdentity: FileIdentity?
    @Published var explorerMode: ExplorerMode = .folders
    @Published var explorerFilter = ExplorerFilter() { didSet { invalidateFileSpaceEstimate() } }
    @Published var explorerSort: ExplorerSort = .size
    @Published private(set) var volume: VolumeSnapshot?
    @Published private(set) var fileSpaceEstimate: FileSpaceEstimate?
    @Published private(set) var calculatingFileSpace = false
    private var estimateGeneration = UUID()
    @Published private(set) var report = GeneralReport()
    @Published private(set) var measurements: [String: SizeMeasurement] = [:]
    @Published private(set) var scanning = false
    @Published private(set) var currentPath = ""
    @Published private(set) var monitor: MonitorSnapshot?
    @Published private(set) var cpu: [Double]?
    @Published private(set) var network: [NetworkRate] = []
    @Published private(set) var diskRates: [DiskIORate] = []
    @Published private(set) var smartStatus: [String: String] = [:]
    @Published private(set) var cpuHistory: [Double] = []
    @Published private(set) var sustainedCPU = false
    private var cpuTracker = CPULoadHistory()
    private var lastSMART = Date.distantPast
    @Published private(set) var maintenanceOutput = ""
    @Published private(set) var runningMaintenance: MaintenanceTask?
    @Published private(set) var roots: [GeneralArea: URL] = [:]
    private let home: URL
    private let logDirectory: URL
    private let applicationRoots: [URL]?
    private let maintenanceRunner: @Sendable (MaintenanceTask, URL, ScanControl) -> ShellResult
    init(home: URL = URL(fileURLWithPath: NSHomeDirectory()), logDirectory: URL = CleanupLog.directory, applicationRoots: [URL]? = nil,
         maintenanceRunner: @escaping @Sendable (MaintenanceTask, URL, ScanControl) -> ShellResult = { $0.run(home: $1, control: $2) }) {
        self.home = home; self.logDirectory = logDirectory; self.applicationRoots = applicationRoots; self.maintenanceRunner = maintenanceRunner
    }
    private var control = ScanControl()
    private var generation = UUID()
    private var cache: [String: (Date, GeneralReport, [String: SizeMeasurement], FileIdentity?)] = [:]

    var root: URL { roots[area] ?? home }
    var visible: [GeneralEntry] {
        report.entries.filter { entry in
            (search.isEmpty || entry.url.path.localizedCaseInsensitiveContains(search))
                && (area != .explorer || explorerFilter.accepts(entry, measurement: measurements[entry.id]))
        }.sorted { lhs, rhs in
            if area == .explorer {
                switch explorerSort {
                case .newest: if lhs.modified != rhs.modified { return (lhs.modified ?? .distantPast) > (rhs.modified ?? .distantPast) }
                case .oldest: if lhs.modified != rhs.modified { return (lhs.modified ?? .distantFuture) < (rhs.modified ?? .distantFuture) }
                case .name: return lhs.url.path.localizedStandardCompare(rhs.url.path) == .orderedAscending
                case .size: break
                }
            }
            let a = measurements[lhs.id]?.bytes ?? -1, b = measurements[rhs.id]?.bytes ?? -1
            return a == b ? lhs.url.path < rhs.url.path : a > b
        }
    }

    var measurementIssues: [String] {
        report.entries.compactMap { entry in
            guard let size = measurements[entry.id], size.state == .complete else {
                let details = measurements[entry.id]?.errors.prefix(2).joined(separator: " · ") ?? ""
                return tr("explorer.unmeasured", ["path": entry.url.path]) + (details.isEmpty ? "" : ": " + details)
            }
            return nil
        }
    }
    var fullyMeasured: Bool { measurements.count == report.entries.count && measurements.values.allSatisfy { $0.state == .complete } }

    private func invalidateFileSpaceEstimate() { estimateGeneration = UUID(); fileSpaceEstimate = nil; calculatingFileSpace = false }
    func estimateVisibleFiles() async {
        let run = UUID(); estimateGeneration = run
        let entries = visible.filter { selected.isEmpty || selected.contains($0.id) }
        let paths = entries.map(\.url)
        calculatingFileSpace = true; fileSpaceEstimate = nil
        let estimate = await Task.detached(priority: .utility) { FileSpaceEstimate.calculate(paths: paths) }.value
        guard run == estimateGeneration else { return }
        fileSpaceEstimate = estimate; calculatingFileSpace = false
    }

    func choose(_ root: URL) { estimateGeneration = UUID(); fileSpaceEstimate = nil; calculatingFileSpace = false; roots[area] = root.resolvingSymlinksInPath(); selected = [] }
    func cancel() { control.cancel() }

    func scan(force: Bool = false) async {
        control.cancel()
        let flag = ScanControl(); control = flag
        let run = UUID(); generation = run
        let area = area
        guard area != .monitor && area != .maintenance else { scanning = false; currentPath = ""; return }
        let prefs = PrefsSnapshot.current()
        let selectedRoot = roots[area]
        let home = home
        let maintenanceFileTask = maintenanceFileTask
        let uninstallApplication = uninstallApplication
        let applicationRoots = applicationRoots
        let scanRoot = root, mode = explorerMode, minimum = explorerFilter.minimumBytes
        let identity = FileIdentity.read(scanRoot)
        let volumes = SystemMonitor.volumes()
        let mounted = ExplorerScanner.hasLocalMount(scanRoot, volumes: volumes)
        volume = mounted ? ExplorerScanner.volume(containing: scanRoot, volumes: volumes) : nil
        let key = area.rawValue + ":" + (selectedRoot?.path ?? "") + ":" + prefs.projectRoots.joined(separator: "|") + ":" + L10n.shared.language
            + ":" + (area == .explorer ? mode.rawValue + String(minimum) : "")
            + ":" + (area == .applications ? uninstallApplication?.path ?? "" : "")
            + ":" + (area == .maintenanceFiles ? maintenanceFileTask.rawValue : "")
        if !force, let stored = cache[key], mounted, identity != nil, stored.3 == identity,
           Date().timeIntervalSince(stored.0) < 60 {
            let valid = await Task.detached(priority: .utility) {
                stored.1.entries.allSatisfy { entry in
                    !flag.isCancelled && FileIdentity.read(entry.url) != nil
                        && entry.target.pathAuthorizations.values.allSatisfy { $0.validates(entry.url) }
                }
            }.value
            guard generation == run else { return }
            if valid { report = stored.1; measurements = stored.2; selected = []; scanning = false; currentPath = ""; return }
        }
        estimateGeneration = UUID(); fileSpaceEstimate = nil; calculatingFileSpace = false
        scanning = true; selected = []; measurements = [:]; report = GeneralReport(); currentPath = root.path
        await withTaskCancellationHandler {
            let result = await Task.detached(priority: .utility) {
                if area == .maintenanceFiles { return MaintenanceFiles.scan(maintenanceFileTask, home: home, control: flag) }
                if area == .applications, let uninstallApplication {
                    return AppUninstall.scan(application: uninstallApplication, home: home, control: flag, roots: applicationRoots)
                }
                if area == .explorer && mode == .largeFiles {
                    return ExplorerScanner.scan(root: scanRoot, home: home, minimumBytes: minimum, control: flag)
                }
                return GeneralScanner.scan(area, home: home, selectedRoot: selectedRoot, prefs: prefs, control: flag, applicationRoots: applicationRoots)
            }.value
            guard generation == run else { return }
            report = result
            let pathsByID = Dictionary(uniqueKeysWithValues: result.entries.map { ($0.id, $0.url.path) })
            await withTaskGroup(of: (String, SizeMeasurement).self) { group in
                var pending = result.entries[...]
                var batch: [String: SizeMeasurement] = [:]
                func enqueue(_ entry: GeneralEntry) {
                    group.addTask(priority: .utility) {
                        let values = try? entry.url.resourceValues(forKeys: [.isRegularFileKey, .fileAllocatedSizeKey])
                        if values?.isRegularFile == true, let bytes = values?.fileAllocatedSize {
                            return (entry.id, SizeMeasurement(bytes: Int64(bytes), state: .complete))
                        }
                        return (entry.id, SizeCalculator.measure(entry.target.paths, timeout: 20, shouldCancel: { flag.isCancelled }))
                    }
                }
                for _ in 0..<4 { if let entry = pending.popFirst() { enqueue(entry) } }
                while let (id, measured) = await group.next() {
                    guard generation == run else { group.cancelAll(); break }
                    batch[id] = measured
                    if batch.count >= 32 || pending.isEmpty {
                        measurements.merge(batch) { _, new in new }; batch = [:]
                        currentPath = pathsByID[id] ?? ""
                    }
                    if flag.isCancelled { group.cancelAll(); break }
                    if let entry = pending.popFirst() { enqueue(entry) }
                }
                if generation == run { measurements.merge(batch) { _, new in new } }
            }
            guard generation == run else { return }
            if FileIdentity.read(scanRoot) != identity {
                report.complete = false; report.issues.append(tr("general.root_unavailable"))
            }
            if flag.isCancelled { report.complete = false; report.issues.append(tr("general.cancelled")) }
            scanning = false; currentPath = ""
            if report.complete && fullyMeasured { cache[key] = (Date(), report, measurements, identity) }
        } onCancel: { flag.cancel() }
    }

    var diagnostics: MonitorDiagnostics? {
        monitor.map { MonitorDiagnostics.evaluate($0, cpu: cpu, sustainedCPU: sustainedCPU, smart: smartStatus) }
    }

    func refreshMonitor() async {
        let next = await Task.detached(priority: .utility) { SystemMonitor.capture() }.value
        cpu = monitor.flatMap { SystemMonitor.cpuFractions(previous: $0.cpuTicks, current: next.cpuTicks) }
        network = SystemMonitor.networkRates(previous: monitor, current: next)
        diskRates = HardwareMonitor.rates(previous: monitor?.hardware, current: next.hardware, seconds: monitor.map { next.date.timeIntervalSince($0.date) } ?? 0)
        cpuTracker.update(cpu, at: next.date)
        cpuHistory = cpuTracker.values; sustainedCPU = cpuTracker.sustained
        monitor = next
        if next.date.timeIntervalSince(lastSMART) >= 60 {
            lastSMART = next.date
            smartStatus = await Task.detached(priority: .utility) { HardwareMonitor.smart() }.value
        }
        if area == .monitor {
            do {
                let object = try JSONSerialization.jsonObject(with: exportData())
                let line = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
                monitoringRecords = Array((monitoringRecords + [line]).suffix(120)); monitoringError = ""
                if let url = recordingURL, let identity = recordingIdentity {
                    try await Task.detached(priority: .utility) {
                        guard FileIdentity.read(url) == identity else { throw CocoaError(.fileWriteUnknown) }
                        let file = try FileHandle(forWritingTo: url)
                        defer { try? file.close() }
                        try file.seekToEnd(); try file.write(contentsOf: line + Data([10]))
                    }.value
                }
            }
            catch { monitoringError = error.localizedDescription; stopMonitorRecording() }
        }
    }

    var hasMonitorHistory: Bool { !monitoringRecords.isEmpty }
    func startMonitorRecording(to url: URL) async throws {
        let initial = exportMonitorHistory()
        let identity = try await Task.detached(priority: .utility) {
            try initial.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            guard let id = FileIdentity.read(url) else { throw CocoaError(.fileWriteUnknown) }
            return id
        }.value
        recordingURL = url; recordingIdentity = identity; recordingMonitor = true
    }
    func stopMonitorRecording() { recordingURL = nil; recordingIdentity = nil; recordingMonitor = false }
    func exportMonitorHistory() -> Data {
        var result = Data()
        for record in monitoringRecords { result.append(record); result.append(10) }
        return result
    }

    func runMaintenance(_ task: MaintenanceTask) async {
        guard runningMaintenance == nil else { return }
        let flag = ScanControl(); control = flag
        runningMaintenance = task; maintenanceOutput = ""
        let home = home, runner = maintenanceRunner
        let result = await Task.detached(priority: .utility) { runner(task, home, flag) }.value
        maintenanceOutput = [result.stdout, result.stderr, result.status == 0 ? tr("maintenance.finished") : tr("maintenance.incomplete")]
            .filter { !$0.isEmpty }.joined(separator: "\n")
        if task.changesState {
            let entry = CleanupLog.Entry(date: Date(), item: "maintenance-" + task.id, risk: [.gatekeeper, .networkReset, .permissions].contains(task) ? "data_loss" : "safe", method: "maintenance",
                                         paths: [], errors: result.status == 0 ? [] : [maintenanceOutput], title: task.title)
            let directory = logDirectory
            await Task.detached { CleanupLog.record(entry, in: directory) }.value
        }
        runningMaintenance = nil
    }

    func exportData() throws -> Data {
        if area == .monitor, let monitor {
            var output: [String: Any] = ["area": "monitor", "sampled_at": ISO8601DateFormatter().string(from: monitor.date),
                "cpu_available": cpu != nil, "cpu_per_core": cpu ?? [], "memory_used": monitor.system.memUsed,
                "memory_total": monitor.system.memTotal, "uptime_seconds": monitor.uptime, "load": monitor.load,
                "thermal_pressure": monitor.thermal,
                "volumes": monitor.volumes.map { ["path": $0.path, "total": $0.total, "free": $0.free, "read_only": $0.readOnly] as [String: Any] },
                "network": network.map { ["interface": $0.id, "received_bytes_per_second": $0.received, "sent_bytes_per_second": $0.sent] as [String: Any] },
                "processes": monitor.processes.map { ["pid": $0.pid, "name": $0.exeName, "cpu_percent": $0.cpu, "rss_bytes": $0.rssBytes] as [String: Any] }]
            if let cache = monitor.system.memCache { output["memory_cache"] = cache }
            output["memory_available"] = monitor.system.memoryAvailable
            output["memory_pressure_available"] = monitor.system.pressureAvailable
            if monitor.system.pressureAvailable { output["memory_pressure"] = monitor.system.pressure.rawValue }
            if let diagnostics { output["diagnostics"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(diagnostics)) }
            output["hardware"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(monitor.hardware))
            output["disk_rates"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(diskRates))
            output["smart"] = smartStatus; output["cpu_history"] = cpuHistory; output["sustained_cpu"] = sustainedCPU
            if let battery = monitor.battery { output["battery_fraction"] = battery } else { output["battery_fraction"] = NSNull() }
            if let swap = monitor.swap { output["swap_bytes"] = swap } else { output["swap_bytes"] = NSNull() }
            return try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
        }
        let entries = visible.filter { selected.isEmpty || selected.contains($0.id) }.map { entry -> [String: Any] in
            let measurement = measurements[entry.id]
            let status: String
            switch measurement?.state {
            case .complete: status = "complete"
            case .partial: status = "partial"
            default: status = "unavailable"
            }
            var output: [String: Any] = ["path": entry.url.path, "bytes": measurement?.bytes ?? 0, "measurement": status,
                    "reviewable": entry.removable, "risk": entry.target.risk.rawValue]
            if let source = entry.installerSource { output["source"] = source.rawValue }
            if let association = entry.association {
                output["association"] = ["bundle_id": association.bundleID, "kind": association.kind.rawValue,
                                         "personal_data": association.kind.personal, "evidence": association.evidence] as [String: Any]
            }
            return output
        }
        var output: [String: Any] = ["area": area.rawValue, "scan_complete": report.complete,
            "measurements_complete": fullyMeasured, "inspected": report.inspected,
            "issues": report.issues + measurementIssues, "entries": entries]
        if let estimate = fileSpaceEstimate {
            output["file_space_estimate"] = ["allocated_unique_bytes": estimate.allocatedBytes, "potential_after_trash_upper_bound": estimate.potentialAfterTrashBytes,
                "files": estimate.files, "unique_inodes": estimate.uniqueFiles, "inodes_with_other_links": estimate.linksOutsideSelection,
                "complete": estimate.complete, "apfs_shared_blocks_deduplicated": false] as [String: Any]
        }
        if area == .explorer {
            output["root"] = root.path; output["mode"] = explorerMode.rawValue
            output["filters"] = ["search": search, "minimum_allocated_bytes": explorerFilter.minimumBytes,
                                 "older_than_days": explorerFilter.olderThanDays, "extensions": explorerFilter.extensions] as [String: Any]
            if let volume { output["volume"] = ["path": volume.path, "free": volume.free, "total": volume.total, "read_only": volume.readOnly] as [String: Any] }
        }
        return try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
    }
}
