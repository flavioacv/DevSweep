import XCTest
import Yams
@testable import DevSweep

final class ExpansionTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws { TestSupport.useEnglish(); root = try TestSupport.temporaryDirectory().resolvingSymlinksInPath().standardizedFileURL }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }
    @discardableResult private func file(_ path: String, data: Data = Data("fixture".utf8), days: Int = 100) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-Double(days) * 86400)], ofItemAtPath: url.path)
        return url
    }
    private func app(_ id: String) throws -> URL {
        try file("Applications/Client.app/Contents/Info.plist", data: PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id], format: .xml, options: 0))
        return root.appendingPathComponent("Applications")
    }

    func testOrphanEvidenceProtectsUnknownCandidatesPersonalDataContainersAndReinstalledApps() throws {
        let id = "org.example.Removed"
        let data = try file("Library/Caches/\(id)/cache")
        try file("Library/Application Support/\(id)/personal")
        try file("Library/Containers/\(id)/Data/keep")
        try file("Library/Caches/org.example.Unknown/data")
        try file("Library/Caches/com.apple.Protected/data")
        let receipt = CleanupLog.Entry(date: Date(), item: "fixture", risk: "data_loss", method: "trash", paths: [root.appendingPathComponent("Applications/Client.app").path], errors: [], bundleID: id)
        let report = OrphanScanner.scan(home: root, roots: [root.appendingPathComponent("Applications")], receipts: [receipt], control: ScanControl())
        XCTAssertTrue(report.complete); XCTAssertEqual(report.entries.count, 4)
        XCTAssertEqual(report.entries.filter(\.removable).count, 2)
        let cache = try XCTUnwrap(report.entries.first { $0.association?.bundleID == id && $0.association?.kind == .cache })
        XCTAssertTrue(try XCTUnwrap(cache.target.orphanRemovalContext).validates())
        XCTAssertNotNil(cache.target.cleanupUnits[0].orphanRemovalContext)
        _ = try app(id)
        XCTAssertFalse(try XCTUnwrap(cache.target.orphanRemovalContext).validates())
        let fresh = OrphanScanner.scan(home: root, roots: [root.appendingPathComponent("Applications")], receipts: [receipt], control: ScanControl())
        XCTAssertFalse(fresh.entries.contains { $0.association?.bundleID == id })
        XCTAssertTrue(FileManager.default.fileExists(atPath: data.path))
        XCTAssertFalse(OrphanScanner.validID("org.example/../../etc")); XCTAssertFalse(OrphanScanner.validID("com.apple.Fixture"))
    }

    func testUnknownInventoryAndFailedReceiptNeverAuthorizeOrphans() throws {
        try file("Library/Caches/org.example.Fixture/data")
        let apps = try app("org.example.Fixture")
        let stopped = ScanControl(); stopped.cancel()
        XCTAssertFalse(OrphanScanner.scan(home: root, roots: [apps], receipts: [], control: stopped).complete)
        try file("Applications/Client.app/Contents/Info.plist", data: Data("corrupt".utf8))
        XCTAssertFalse(OrphanScanner.scan(home: root, roots: [apps], receipts: [], control: ScanControl()).complete)
    }

    func testServiceGuardDistinguishesAbsentFromLoadedOrPermissionDenied() {
        let service = ServiceRemovalContext(label: "org.example.Missing", executable: "/opt/nonexistent-devsweep-fixture")
        XCTAssertTrue(service.validates(probe: { _, _ in ShellResult(status: 113, stdout: "", stderr: "Could not find service org.example.Missing") }))
        XCTAssertFalse(service.validates(probe: { _, _ in ShellResult(status: 1, stdout: "", stderr: "Operation not permitted") }))
        XCTAssertFalse(service.validates(probe: { _, _ in ShellResult(status: 0, stdout: "running", stderr: "") }))
        XCTAssertFalse(ServiceRemovalContext(label: "bad/label", executable: "/opt/missing").validates())
        XCTAssertFalse(ServiceRemovalContext(label: "org.example.Exists", executable: "/bin/sh").validates())
    }

    func testToolGuardsAreRetainedAndUnknownUsageFailsClosed() throws {
        let cache = try file("cache/data").deletingLastPathComponent()
        var target = GeneralScanner.entry(cache, root: root, area: .caches, home: root).target
        target.requiresToolsIdle = ["python", "uv"]
        XCTAssertEqual(StorageSafety.check(cache, target: target), .unverified)
        let handles = ShellResult(status: 0, stdout: "p42\nn/opt/unrelated\n", stderr: "")
        XCTAssertEqual(StorageSafety.check(cache, target: target, usage: ApplicationUsageSnapshot(runningBundleIDs: [], handles: handles, toolExecutables: ["python3.14"])), .inUse)
        XCTAssertEqual(StorageSafety.check(cache, target: target, usage: ApplicationUsageSnapshot(runningBundleIDs: [], handles: handles, toolExecutables: ["unrelated"])), .allowed)
        XCTAssertEqual(target.cleanupUnits[0].requiresToolsIdle, ["python", "uv"])
    }

    func testNewCatalogIsManualAndCachesDoNotSelectPersistentAppData() throws {
        for name in ["extended-tools", "extended-apps"] {
            var yaml = try String(contentsOf: TestSupport.stacksDirectory.appendingPathComponent(name + ".yaml"), encoding: .utf8)
            yaml = yaml.replacingOccurrences(of: #"\$\{[^:}]+:-([^}]+)\}"#, with: "$1", options: .regularExpression).replacingOccurrences(of: "~/", with: root.path + "/")
            let entries = try XCTUnwrap(YAMLDecoder().decode(StackFile.self, from: yaml).storage)
            XCTAssertFalse(entries.isEmpty)
            for entry in entries { XCTAssertEqual(entry.autoSuggest, false); XCTAssertEqual(entry.method, "trash") }
            if name == "extended-apps" {
                for entry in entries {
                    let id = try XCTUnwrap(entry.requiresAppsClosed?.first)
                    let expected = root.appendingPathComponent("Library/Caches/" + id)
                    try file("Library/Caches/\(id)/cache")
                    try file("Library/Application Support/\(id)/credentials.json")
                    try file("Library/Containers/\(id)/Data/Documents/keep")
                    let found = (entry.paths ?? []).flatMap { PathResolver.resolve($0) }
                    XCTAssertEqual(found.map(\.path), [expected.path])
                }
            }
        }
    }

    func testHardwareParsersPreserveUnavailableAndRejectCounterResets() throws {
        XCTAssertNil(HardwareMonitor.gpuUtilization([:]))
        XCTAssertEqual(HardwareMonitor.gpuUtilization(["PerformanceStatistics": ["Device Utilization %": 42]]), 0.42)
        XCTAssertNil(HardwareMonitor.gpuUtilization(["PerformanceStatistics": ["Device Utilization %": 142]]))
        XCTAssertNil(HardwareMonitor.diskCounter([:]))
        XCTAssertEqual(HardwareMonitor.diskCounter(["Statistics": ["Bytes (Read)": 100, "Bytes (Write)": 200]])?.read, 100)
        XCTAssertNil(HardwareMonitor.batteryDetails([:]))
        let battery = HardwareMonitor.batteryDetails(["CycleCount": 23, "DesignCapacity": 5000, "AppleRawMaxCapacity": 4500])
        XCTAssertEqual(battery?.capacityRatio, 0.9); XCTAssertEqual(battery?.cycles, 23)
        XCTAssertEqual(HardwareMonitor.sensor(["type": "temperature", "registryID": "1", "current-value": 50 * 65536])?.value, 50)
        XCTAssertEqual(HardwareMonitor.sensor(["type": "fanspeed", "registryID": "2", "current-value": 1000 * 65536])?.unit, "RPM")
        XCTAssertEqual(HardwareMonitor.sensor(["type": "power", "registryID": "3", "current-value": 20 * 65536])?.unit, "W")
        XCTAssertNil(HardwareMonitor.sensor(["type": "unknown", "registryID": "1", "current-value": 0]))
        XCTAssertNil(HardwareMonitor.sensor(["type": "temperature", "registryID": "1", "current-value": -1]))
        var first = HardwareSnapshot(); first.disks["disk"] = DiskIOCounter(read: 100, written: 100)
        var next = first; next.disks["disk"] = DiskIOCounter(read: 300, written: 500)
        XCTAssertEqual(HardwareMonitor.rates(previous: first, current: next, seconds: 2).first?.written, 200)
        XCTAssertTrue(HardwareMonitor.rates(previous: next, current: first, seconds: 2).isEmpty)
        XCTAssertTrue(HardwareMonitor.rates(previous: nil, current: next, seconds: 2).isEmpty)
        XCTAssertTrue(HardwareMonitor.rates(previous: first, current: next, seconds: 0).isEmpty)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["SMARTStatus": "Verified"], format: .xml, options: 0)
        XCTAssertEqual(HardwareMonitor.smartStatus(ShellResult(status: 0, stdout: String(decoding: plist, as: UTF8.self), stderr: "")), "Verified")
        XCTAssertNil(HardwareMonitor.smartStatus(ShellResult(status: 1, stdout: "", stderr: "unavailable")))
        let zombies = HardwareMonitor.zombies(ShellResult(status: 0, stdout: "1 0 S /sbin/launchd\n42 1 Z /opt/fixture\n", stderr: ""))
        XCTAssertEqual(zombies?.first?.parentName, "launchd")
        XCTAssertNil(HardwareMonitor.zombies(ShellResult(status: 0, stdout: "invalid", stderr: "")))
        XCTAssertNil(HardwareMonitor.zombies(ShellResult(status: 1, stdout: "", stderr: "")))
        XCTAssertNoThrow(try JSONEncoder().encode(HardwareMonitor.capture()))
    }

    func testMaintenanceReviewsPreserveRecentAndValidPreferencesAndFiles() throws {
        let broken = try file("Library/Preferences/org.example.Broken.plist", data: Data([0xff, 0, 0xfe]))
        try file("Library/Preferences/org.example.Valid.plist", data: PropertyListSerialization.data(fromPropertyList: ["setting": true], format: .xml, options: 0))
        let report = MaintenanceFiles.scan(.repairPreferences, home: root, control: ScanControl())
        XCTAssertEqual(report.entries.map(\.url), [broken]); XCTAssertTrue(try XCTUnwrap(report.entries.first).removable)
        try file("Library/Saved Application State/org.example.Old.savedState/state")
        let old = root.appendingPathComponent("Library/Saved Application State/org.example.Old.savedState")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-100 * 86400)], ofItemAtPath: old.path)
        XCTAssertEqual(MaintenanceFiles.scan(.savedStates, home: root, control: ScanControl()).entries.count, 1)
        let stateTarget = try XCTUnwrap(MaintenanceFiles.scan(.savedStates, home: root, control: ScanControl()).entries.first?.target)
        XCTAssertEqual(stateTarget.cleanupUnits[0].recursiveAgeDays, 30)
        try file("Library/Saved Application State/org.example.Old.savedState/state", days: 0)
        XCTAssertEqual(StorageSafety.check(old, target: stateTarget), .recent)
        XCTAssertTrue(MaintenanceFiles.scan(.savedStates, home: root, control: ScanControl()).entries.isEmpty)
        XCTAssertFalse(MaintenanceFiles.scan(.sqlite, home: root, control: ScanControl()).complete)
        try file("Library/Application Support/com.apple.sharedfilelist/recent.sfl2")
        XCTAssertEqual(MaintenanceFiles.scan(.finderLists, home: root, control: ScanControl()).entries.count, 1)
        let agent = try PropertyListSerialization.data(fromPropertyList: ["Program": "/opt/nonexistent-fixture"], format: .xml, options: 0)
        try file("Library/LaunchAgents/org.example.Missing.plist", data: agent)
        let agents = MaintenanceFiles.scan(.launchAgents, home: root, control: ScanControl())
        XCTAssertEqual(agents.entries.count, 1); XCTAssertFalse(try XCTUnwrap(agents.entries.first).removable)
    }

    func testSQLiteMaintenanceBacksUpAndPreservesRowsAndRejectsOpenOrCorruptDatabase() throws {
        let db = root.appendingPathComponent("history.sqlite")
        XCTAssertEqual(Shell.run("/usr/bin/sqlite3", [db.path, "CREATE TABLE records(value TEXT); INSERT INTO records VALUES ('keep');"]).status, 0)
        let closed = ApplicationUsageSnapshot(runningBundleIDs: [], handles: ShellResult(status: 0, stdout: "p42\nn/opt/unrelated\n", stderr: ""))
        let backup = root.appendingPathComponent("backups")
        let result = MaintenanceDatabase.compact(db, backupRoot: backup, usage: closed, control: ScanControl())
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(Shell.run("/usr/bin/sqlite3", [db.path, "SELECT value FROM records;"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines), "keep")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: backup.path).count, 1)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        let open = ApplicationUsageSnapshot(runningBundleIDs: [], handles: ShellResult(status: 0, stdout: "p42\nn\(db.path)-wal\n", stderr: ""))
        XCTAssertNotEqual(MaintenanceDatabase.compact(db, backupRoot: backup, usage: open, control: ScanControl()).status, 0)
        let bad = try file("broken.sqlite")
        XCTAssertNotEqual(MaintenanceDatabase.compact(bad, backupRoot: backup, usage: closed, control: ScanControl()).status, 0)
        let cancelled = ScanControl(); cancelled.cancel()
        XCTAssertEqual(MaintenanceDatabase.compact(db, backupRoot: backup, usage: closed, control: cancelled).status, -2)
        XCTAssertTrue(MaintenanceTask.networkReset.requiresAdmin); XCTAssertTrue(MaintenanceTask.spotlightRebuild.requiresAdmin)
        XCTAssertFalse(MaintenanceTask.backups.changesState); XCTAssertTrue(MaintenanceTask.savedStates.reviewsFiles)
    }

    func testQuarantineCleanupDeletesOnlyOldRowsAndRetainsBackup() throws {
        let db = root.appendingPathComponent("quarantine.sqlite")
        let old = Date().timeIntervalSinceReferenceDate - 120 * 86400
        let recent = Date().timeIntervalSinceReferenceDate
        XCTAssertEqual(Shell.run("/usr/bin/sqlite3", [db.path, "CREATE TABLE LSQuarantineEvent(LSQuarantineTimeStamp REAL); INSERT INTO LSQuarantineEvent VALUES (\(old)), (\(recent));"]).status, 0)
        let usage = ApplicationUsageSnapshot(runningBundleIDs: [], handles: ShellResult(status: 0, stdout: "p42\nn/opt/unrelated\n", stderr: ""))
        let result = MaintenanceDatabase.compact(db, backupRoot: root.appendingPathComponent("backups"), usage: usage, control: ScanControl(), deleteOldQuarantine: true)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(Shell.run("/usr/bin/sqlite3", [db.path, "SELECT COUNT(*) FROM LSQuarantineEvent;"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines), "1")
    }

    @MainActor func testNewModelAreasAndMonitorNDJSON() async throws {
        let apps = root.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
        let model = GeneralModel(home: root, logDirectory: root.appendingPathComponent("history"), applicationRoots: [apps])
        model.area = .orphans; await model.scan(force: true)
        XCTAssertTrue(model.report.complete)
        model.maintenanceFileTask = .repairPreferences; model.area = .maintenanceFiles
        try file("Library/Preferences/org.example.Broken.plist", data: Data([0xff, 0xfe]))
        await model.scan(force: true); XCTAssertEqual(model.report.entries.count, 1)
        model.area = .monitor; await model.refreshMonitor()
        XCTAssertTrue(model.hasMonitorHistory)
        let lines = String(decoding: model.exportMonitorHistory(), as: UTF8.self).split(separator: "\n")
        XCTAssertEqual(lines.count, 1)
        let object = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any]
        XCTAssertNotNil(object?["hardware"]); XCTAssertNotNil(object?["smart"])
        let stream = root.appendingPathComponent("monitor.ndjson")
        try await model.startMonitorRecording(to: stream)
        XCTAssertTrue(model.recordingMonitor)
        await model.refreshMonitor()
        XCTAssertEqual(try String(contentsOf: stream, encoding: .utf8).split(separator: "\n").count, 2)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: stream.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        model.stopMonitorRecording(); XCTAssertFalse(model.recordingMonitor)
    }

    func testPrivilegedTasksOnlyBuildExplicitCommandsAndNeverExecuteDuringTests() {
        for task in [MaintenanceTask.dns, .networkReset, .permissions, .spotlightRebuild, .sensorReport] {
            var commands: [(String, [String])] = []
            let result = task.run(home: root, control: ScanControl(), executor: { exe, args, _ in
                commands.append((exe, args)); return ShellResult(status: 0, stdout: args.isEmpty ? "resetUserPermissions" : "fixture", stderr: "")
            })
            XCTAssertEqual(result.status, 0)
            XCTAssertEqual(commands.last?.0, "/usr/bin/osascript")
            XCTAssertTrue(commands.last?.1.last?.contains("with administrator privileges") == true)
            XCTAssertTrue(commands.last?.1.last?.contains(task.command!.0) == true)
        }
        var calls = 0
        XCTAssertEqual(MaintenanceTask.preventDSStore.run(home: root, control: ScanControl(), executor: { _, args, _ in
            calls += 1; XCTAssertTrue(args.contains("true")); return ShellResult(status: 0, stdout: "", stderr: "")
        }).status, 0)
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(MaintenanceTask.savedStates.run(home: root, control: ScanControl()).status, 0)
        for task in [MaintenanceTask.sqlite, .gatekeeper, .notifications, .coreDuet] {
            XCTAssertNotEqual(task.run(home: root, control: ScanControl()).status, 0, "Missing fixture DBs must not create user databases")
        }
    }

    func testDockerRejectsRemoteEndpointsAndPinsLocalBuilderWithoutVolumes() throws {
        var calls: [[String]] = []
        let runner: (String, [String]) -> ShellResult = { _, args in
            calls.append(args)
            let output: String
            if args == ["context", "show"] { output = "fixture" }
            else if args.contains("inspect") && args.contains("context") { output = "\"unix:///opt/fixture.sock\"" }
            else if args.contains("inspect") { output = "{\"Name\":\"local\",\"Driver\":\"docker\",\"Nodes\":[{\"Endpoint\":\"fixture\"}]}" }
            else if args.contains("info") { output = "engine-id" }
            else { output = "fixture result" }
            return ShellResult(status: 0, stdout: output, stderr: "")
        }
        XCTAssertNotEqual(DockerMaintenance.run(execute: true, control: ScanControl(), environment: ["DOCKER_HOST": "ssh://remote"], runner: runner).status, 0)
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(DockerMaintenance.run(execute: false, control: ScanControl(), environment: [:], runner: runner).status, 0)
        XCTAssertFalse(calls.contains { $0.contains("prune") })
        calls = []
        XCTAssertEqual(DockerMaintenance.run(execute: true, control: ScanControl(), environment: [:], runner: runner).status, 0)
        XCTAssertEqual(calls.filter { $0.contains("prune") }.count, 2)
        XCTAssertFalse(calls.flatMap { $0 }.contains("--all")); XCTAssertFalse(calls.flatMap { $0 }.contains("volume"))
        XCTAssertTrue(calls.filter { $0.contains("prune") }.allSatisfy { $0.contains("until=168h") && $0.contains("--context") })
        calls = []
        var infos = 0
        let changed = DockerMaintenance.run(execute: true, control: ScanControl(), environment: [:], runner: { exe, args in
            if args.contains("info") {
                infos += 1
                if infos == 3 { return ShellResult(status: 0, stdout: "different engine", stderr: "") }
            }
            return runner(exe, args)
        })
        XCTAssertNotEqual(changed.status, 0)
        XCTAssertFalse(calls.contains { $0.contains("image") && $0.contains("prune") })
    }

    func testBackupsSkipsTmutilWhenNetworkVolumeMountedAndListsLocalSnapshotsWhenLocalOnly() {
        let entries = [
            MountTableGuard.Entry(mountPoint: "/", fsType: "apfs", isLocal: true),
            MountTableGuard.Entry(mountPoint: "/System/Volumes/Data/home", fsType: "autofs", isLocal: false),
            MountTableGuard.Entry(mountPoint: "/Volumes/NAS", fsType: "smbfs", isLocal: false),
        ]
        XCTAssertEqual(MountTableGuard.networkVolumes(in: entries), ["/Volumes/NAS"])
        XCTAssertNil(MountTableGuard.networkVolumes(in: nil))
        XCTAssertNotNil(MountTableGuard.mountedEntries())

        var invoked = false
        let skipped = MaintenanceTask.backups.run(home: root, control: ScanControl(), executor: { _, _, _ in
            invoked = true
            return ShellResult(status: 0, stdout: "", stderr: "")
        }, networkVolumesProvider: { ["/Volumes/NAS"] })
        XCTAssertEqual(skipped.status, 0)
        XCTAssertFalse(invoked)

        let unknown = MaintenanceTask.backups.run(home: root, control: ScanControl(), executor: { _, _, _ in
            invoked = true
            return ShellResult(status: 0, stdout: "", stderr: "")
        }, networkVolumesProvider: { nil })
        XCTAssertEqual(unknown.status, 0)
        XCTAssertFalse(invoked)

        var argsSeen: [[String]] = []
        let localOnly = MaintenanceTask.backups.run(home: root, control: ScanControl(), executor: { _, args, _ in
            argsSeen.append(args)
            if args.first == "listlocalsnapshots" {
                return ShellResult(status: 0, stdout: "com.apple.TimeMachine.2026-11-26-100000.local", stderr: "")
            }
            return ShellResult(status: 0, stdout: "/Volumes/Backup/2026-11-26", stderr: "")
        }, networkVolumesProvider: { [] })
        XCTAssertEqual(localOnly.status, 0)
        XCTAssertEqual(argsSeen, [["listlocalsnapshots", "/"], ["listbackups"]])
        XCTAssertTrue(localOnly.stdout.contains("com.apple.TimeMachine.2026-11-26-100000.local"))
        XCTAssertTrue(localOnly.stdout.contains("/Volumes/Backup/2026-11-26"))
    }

    func testSpotlightRulesAuditDetectsOrphanExclusionsReadOnly() throws {
        let existing = try file("ExistingFolder/keep").deletingLastPathComponent()
        let plistDict: [String: Any] = [
            "Exclusions": [existing.path, "/Volumes/Gone/OldProject", "~/MissingDir"],
            "orderedItems": [["path": "/opt/absent-tool"]]
        ]
        let xml = try PropertyListSerialization.data(fromPropertyList: plistDict, format: .xml, options: 0)
        let orphans = try XCTUnwrap(SpotlightRulesAudit.orphanPaths(from: xml, home: root))
        XCTAssertEqual(orphans, [root.appendingPathComponent("MissingDir").path, "/Volumes/Gone/OldProject", "/opt/absent-tool"].sorted())
        XCTAssertNil(SpotlightRulesAudit.orphanPaths(from: Data("not-a-plist".utf8), home: root))

        var commands: [(String, [String])] = []
        let result = MaintenanceTask.spotlightRules.run(home: root, control: ScanControl(), executor: { exe, args, _ in
            commands.append((exe, args))
            if exe == "/usr/bin/mdutil" { return ShellResult(status: 0, stdout: "/: Indexing enabled.", stderr: "") }
            return ShellResult(status: 0, stdout: String(decoding: xml, as: UTF8.self), stderr: "")
        })
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(commands.map(\.0), ["/usr/bin/mdutil", "/usr/bin/defaults"])
        XCTAssertEqual(commands[1].1, ["export", "com.apple.Spotlight", "-"])
        XCTAssertTrue(result.stdout.contains("/Volumes/Gone/OldProject"))
        XCTAssertFalse(result.stdout.contains(existing.path))
    }

    func testPerformanceDiagnosticsAndAutoOptimizeFlow() async throws {
        let ps = """
         20.5 /System/Library/Frameworks/CoreServices.framework/Frameworks/Metadata.framework/Versions/A/Support/mds_stores
         12.0 mdworker_shared
         28.4 /usr/libexec/syspolicyd
          2.0 /Applications/Zelvo.app/Contents/MacOS/DevSweep
        """
        let hdiutil = """
        image-path      : /opt/fixtures/Installer.dmg
        image-path      : /opt/fixtures/Other.iso
        """
        let findings = PerformanceDiagnostics.analyze(psOutput: ps, hdiutilOutput: hdiutil)
        XCTAssertEqual(findings.map(\.id), ["spotlight-cpu", "syspolicyd-cpu", "mounted-dmgs"])
        XCTAssertTrue(PerformanceDiagnostics.analyze(psOutput: "1.0 /bin/zsh\n", hdiutilOutput: "").isEmpty)
        XCTAssertEqual(PerformanceDiagnostics.capture(runner: { exe, _ in
            ShellResult(status: 0, stdout: exe == "/bin/ps" ? ps : hdiutil, stderr: "")
        }).count, 3)

        let logDir = root.appendingPathComponent("auto-log")
        let model = await MainActor.run {
            GeneralModel(home: root, logDirectory: logDir, maintenanceRunner: { task, _, _ in
                switch task {
                case .quickLook: ShellResult(status: 0, stdout: "refreshed", stderr: "")
                case .sqlite: ShellResult(status: 1, stdout: "", stderr: tr("maintenance.database_busy"))
                default: ShellResult(status: 1, stdout: "", stderr: "failed")
                }
            })
        }
        await model.runAutoOptimize(tasks: [.quickLook, .sqlite, .spotlightRules], diagnosticsProvider: { findings })
        let results = await MainActor.run { model.optimizeResults }
        let output = await MainActor.run { model.maintenanceOutput }
        let savedFindings = await MainActor.run { model.performanceFindings }
        XCTAssertEqual(savedFindings.count, 3)
        XCTAssertEqual(results.map(\.status), [.succeeded, .skipped, .failed])
        XCTAssertTrue(output.contains("✓"))
        XCTAssertTrue(output.contains("⊘"))
        XCTAssertTrue(output.contains("⚠"))
        XCTAssertEqual(CleanupLog.read(in: logDir).last?.item, "maintenance-auto-optimize")
    }
}
