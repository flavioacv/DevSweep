import Foundation

@MainActor
final class GeneralModel: ObservableObject {
    @Published var area: GeneralArea = .logs
    @Published var search = ""
    @Published var selected: Set<String> = []
    @Published private(set) var report = GeneralReport()
    @Published private(set) var measurements: [String: SizeMeasurement] = [:]
    @Published private(set) var scanning = false
    @Published private(set) var currentPath = ""
    @Published private(set) var monitor: MonitorSnapshot?
    @Published private(set) var cpu: [Double]?
    @Published private(set) var network: [NetworkRate] = []
    @Published private(set) var maintenanceOutput = ""
    @Published private(set) var runningMaintenance: MaintenanceTask?
    @Published private(set) var roots: [GeneralArea: URL] = [:]
    private let home: URL
    private let logDirectory: URL
    private let maintenanceRunner: @Sendable (MaintenanceTask, URL, ScanControl) -> ShellResult
    init(home: URL = URL(fileURLWithPath: NSHomeDirectory()), logDirectory: URL = CleanupLog.directory,
         maintenanceRunner: @escaping @Sendable (MaintenanceTask, URL, ScanControl) -> ShellResult = { $0.run(home: $1, control: $2) }) {
        self.home = home; self.logDirectory = logDirectory; self.maintenanceRunner = maintenanceRunner
    }
    private var control = ScanControl()
    private var generation = UUID()
    private var cache: [String: (Date, GeneralReport, [String: SizeMeasurement])] = [:]

    var root: URL { roots[area] ?? home }
    var visible: [GeneralEntry] {
        report.entries.filter { search.isEmpty || $0.url.path.localizedCaseInsensitiveContains(search) }
            .sorted { (measurements[$0.id]?.bytes ?? -1) > (measurements[$1.id]?.bytes ?? -1) }
    }

    func choose(_ root: URL) { roots[area] = root.resolvingSymlinksInPath(); selected = [] }
    func cancel() { control.cancel() }

    func scan(force: Bool = false) async {
        control.cancel()
        let flag = ScanControl(); control = flag
        let run = UUID(); generation = run
        let area = area
        guard area != .monitor && area != .maintenance else { return }
        let prefs = PrefsSnapshot.current()
        let selectedRoot = roots[area]
        let home = home
        let key = area.rawValue + ":" + (selectedRoot?.path ?? "") + ":" + prefs.projectRoots.joined(separator: "|") + ":" + L10n.shared.language
        if !force, let stored = cache[key], Date().timeIntervalSince(stored.0) < 60 {
            report = stored.1; measurements = stored.2; selected = []; scanning = false; return
        }
        scanning = true; selected = []; measurements = [:]; report = GeneralReport(); currentPath = root.path
        await withTaskCancellationHandler {
            let result = await Task.detached(priority: .utility) {
                GeneralScanner.scan(area, home: home, selectedRoot: selectedRoot, prefs: prefs, control: flag)
            }.value
            guard generation == run else { return }
            report = result
            await withTaskGroup(of: (String, SizeMeasurement).self) { group in
                var pending = result.entries[...]
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
                    measurements[id] = measured
                    currentPath = result.entries.first { $0.id == id }?.url.path ?? ""
                    if flag.isCancelled { group.cancelAll(); break }
                    if let entry = pending.popFirst() { enqueue(entry) }
                }
            }
            guard generation == run else { return }
            if flag.isCancelled { report.complete = false; report.issues.append(tr("general.cancelled")) }
            scanning = false; currentPath = ""
            if report.complete && measurements.values.allSatisfy({ $0.state == .complete }) { cache[key] = (Date(), report, measurements) }
        } onCancel: { flag.cancel() }
    }

    func refreshMonitor() async {
        let next = await Task.detached(priority: .utility) { SystemMonitor.capture() }.value
        cpu = monitor.flatMap { SystemMonitor.cpuFractions(previous: $0.cpuTicks, current: next.cpuTicks) }
        network = SystemMonitor.networkRates(previous: monitor, current: next)
        monitor = next
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
            let entry = CleanupLog.Entry(date: Date(), item: "maintenance-" + task.id, risk: "safe", method: "maintenance",
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
            if let battery = monitor.battery { output["battery_fraction"] = battery } else { output["battery_fraction"] = NSNull() }
            if let swap = monitor.swap { output["swap_bytes"] = swap } else { output["swap_bytes"] = NSNull() }
            return try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
        }
        let entries = report.entries.filter { selected.isEmpty || selected.contains($0.id) }.map { entry -> [String: Any] in
            let measurement = measurements[entry.id]
            let status: String
            switch measurement?.state {
            case .complete: status = "complete"
            case .partial: status = "partial"
            default: status = "unavailable"
            }
            return ["path": entry.url.path, "bytes": measurement?.bytes ?? 0, "measurement": status,
                    "reviewable": entry.removable, "risk": entry.target.risk.rawValue]
        }
        return try JSONSerialization.data(withJSONObject: ["area": area.rawValue, "scan_complete": report.complete,
            "inspected": report.inspected, "issues": report.issues, "entries": entries], options: [.prettyPrinted, .sortedKeys])
    }
}
