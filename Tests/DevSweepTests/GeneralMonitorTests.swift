import XCTest
@testable import DevSweep

final class GeneralMonitorTests: XCTestCase {
    func testCPUAndNetworkRejectMissingSamplesResetsAndZeroIntervals() {
        XCTAssertEqual(SystemMonitor.cpuFractions(previous: [[10, 10, 10, 10]], current: [[20, 20, 20, 20]]), [0.75])
        XCTAssertNil(SystemMonitor.cpuFractions(previous: [], current: []))
        XCTAssertNil(SystemMonitor.cpuFractions(previous: [[1]], current: [[2]]))
        XCTAssertNil(SystemMonitor.cpuFractions(previous: [[10, 10, 10, 10]], current: [[9, 20, 20, 20]]))
        XCTAssertNil(SystemMonitor.cpuFractions(previous: [[1, 1, 1, 1]], current: [[1, 1, 1, 1]]))
        var first = SystemMonitor.capture()
        first.date = Date(timeIntervalSince1970: 100)
        first.network = ["en0": NetworkCounters(received: 100, sent: 50)]
        var next = first; next.date.addTimeInterval(2)
        next.network = ["en0": NetworkCounters(received: 300, sent: 150), "new": NetworkCounters(received: 10, sent: 10)]
        let rates = SystemMonitor.networkRates(previous: first, current: next)
        XCTAssertEqual(rates.count, 1); XCTAssertEqual(rates[0].received, 100); XCTAssertEqual(rates[0].sent, 50)
        XCTAssertTrue(SystemMonitor.networkRates(previous: nil, current: next).isEmpty)
        XCTAssertTrue(SystemMonitor.networkRates(previous: first, current: first).isEmpty)
        next.network["en0"] = NetworkCounters(received: 1, sent: 1)
        XCTAssertTrue(SystemMonitor.networkRates(previous: first, current: next).isEmpty)
        XCTAssertGreaterThan(first.system.memTotal, 0)
        XCTAssertGreaterThan(first.uptime, 0)
        XCTAssertFalse(first.cpuTicks.isEmpty)
        XCTAssertFalse(first.volumes.isEmpty)
    }

    func testPreferenceAuditReportsCorruptFilesWithoutChangingThem() throws {
        let home = try TestSupport.temporaryDirectory().resolvingSymlinksInPath().standardizedFileURL
        defer { try? FileManager.default.removeItem(at: home) }
        let directory = home.appendingPathComponent("Library/Preferences")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("broken.plist")
        let bytes = Data("invalid property list".utf8); try bytes.write(to: path)
        let result = MaintenanceTask.preferences.run(home: home, control: ScanControl())
        XCTAssertEqual(result.status, 1); XCTAssertTrue(result.stdout.contains(path.path))
        XCTAssertEqual(try Data(contentsOf: path), bytes)
        try FileManager.default.removeItem(at: path)
        XCTAssertEqual(MaintenanceTask.preferences.run(home: home, control: ScanControl()).status, 0)
        let agent = directory.appendingPathComponent("agent.plist")
        try PropertyListSerialization.data(fromPropertyList: ["Program": "/opt/nonexistent-devsweep-fixture"], format: .xml, options: 0).write(to: agent)
        let audit = MaintenanceTask.launchAgents.run(home: home, control: ScanControl(), searchRoots: [directory])
        XCTAssertTrue(audit.stdout.contains(agent.lastPathComponent))
        XCTAssertTrue(FileManager.default.fileExists(atPath: agent.path))
        let cancelled = ScanControl(); cancelled.cancel()
        for task in MaintenanceTask.allCases {
            XCTAssertEqual(task.run(home: home, control: cancelled).status, -2)
        }
        XCTAssertEqual(MaintenanceTask.program(["Program": "/bin/echo"]), "/bin/echo")
        XCTAssertEqual(MaintenanceTask.program(["ProgramArguments": ["/bin/echo", "a"]]), "/bin/echo")
        XCTAssertNil(MaintenanceTask.program([:]))
        for task in MaintenanceTask.allCases {
            XCTAssertFalse(task.title.isEmpty)
            if [.launchAgents, .preferences, .spotlight, .loginItems, .verifyDisk, .sensorReport, .backups].contains(task) { XCTAssertFalse(task.changesState) }
            if task.requiresAdmin { XCTAssertNotNil(task.command) }
        }
    }

    func testCancellationAndTimeoutStopDisposableCommandsAndMeasurements() throws {
        let cancelled = ScanControl(); cancelled.cancel()
        XCTAssertEqual(Shell.run("/bin/echo", ["never executed"], shouldCancel: { cancelled.isCancelled }).status, -2)
        let started = Date()
        let stopped = Shell.run("/bin/sh", ["-c", "trap '' TERM; while :; do :; done"], timeout: 0.1)
        XCTAssertNotEqual(stopped.status, 0)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(SizeCalculator.measure([root], shouldCancel: { cancelled.isCancelled }).state, .unavailable)
    }

    @MainActor func testGeneralModelScansFiltersCachesExportsAndRunsInjectedMaintenance() async throws {
        let home = try TestSupport.temporaryDirectory().resolvingSymlinksInPath().standardizedFileURL
        defer { try? FileManager.default.removeItem(at: home) }
        try Data("sample".utf8).write(to: home.appendingPathComponent("sample.txt"))
        let model = GeneralModel(home: home, logDirectory: home.appendingPathComponent("history"), maintenanceRunner: { task, _, _ in
            ShellResult(status: task == .dns ? 0 : 1, stdout: "fixture", stderr: "")
        })
        model.area = .explorer; model.choose(home)
        await model.scan(force: true)
        XCTAssertFalse(model.scanning); XCTAssertTrue(model.currentPath.isEmpty)
        XCTAssertEqual(model.visible.count, 1)
        model.search = "absent"; XCTAssertTrue(model.visible.isEmpty)
        model.search = "sample"; XCTAssertEqual(model.visible.count, 1)
        model.selected = Set(model.report.entries.map(\.id))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: model.exportData()) as? [String: Any])
        XCTAssertEqual(json["scan_complete"] as? Bool, true)
        XCTAssertEqual((json["entries"] as? [[String: Any]])?.count, 1)
        await model.scan(); XCTAssertTrue(model.selected.isEmpty)
        model.cancel()
        model.area = .maintenance; await model.scan()
        await model.runMaintenance(.dns); XCTAssertNil(model.runningMaintenance)
        XCTAssertTrue(model.maintenanceOutput.contains("fixture"))
        await model.runMaintenance(.quickLook); XCTAssertFalse(model.maintenanceOutput.isEmpty)
        model.area = .monitor; await model.scan()
        await model.refreshMonitor(); await model.refreshMonitor()
        let exported = try XCTUnwrap(JSONSerialization.jsonObject(with: model.exportData()) as? [String: Any])
        XCTAssertEqual(exported["area"] as? String, "monitor")
        XCTAssertNotNil(exported["volumes"])
    }
}
