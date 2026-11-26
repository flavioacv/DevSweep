import XCTest
import Yams
@testable import DevSweep

final class StorageSafetyTests: XCTestCase {
    private var root: URL!
    private var cache: URL!
    private let appID = "org.example.Client"

    override func setUpWithError() throws {
        TestSupport.useEnglish()
        root = try TestSupport.temporaryDirectory().resolvingSymlinksInPath()
        cache = root.appendingPathComponent("Cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try "cached".write(to: cache.appendingPathComponent("data"), atomically: true, encoding: .utf8)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func usage(_ apps: Set<String>? = [], output: String = "p42\nn/opt/unrelated\n", status: Int32 = 0) -> ApplicationUsageSnapshot {
        ApplicationUsageSnapshot(runningBundleIDs: apps, handles: ShellResult(status: status, stdout: output, stderr: ""))
    }

    private func target(_ paths: [URL]? = nil, appIDs: [String]? = nil, rules: [String: PathSpec] = [:]) -> StorageTarget {
        StorageTarget(id: "app-cache", stack: StackInfo(id: "mac", name: "Mac", icon: "desktopcomputer", order: 0),
                      title: "Cache", detail: "", risk: .redownload, paths: paths ?? [cache],
                      authorizedProjectPaths: paths ?? [cache], requiresAppsClosed: appIDs ?? [appID], pathRules: rules)
    }

    func testRunningOwnerAndHelpersProtectCacheIncludingBundleIDCaseVariants() {
        for apps: Set<String> in [[appID], [appID.lowercased()]] {
            XCTAssertEqual(StorageSafety.check(cache, target: target(), usage: usage(apps)), .inUse)
        }
        XCTAssertEqual(StorageSafety.check(cache, target: target(), usage: usage(["org.example.Other"])), .allowed)
    }

    func testUnknownOwnerOrHandlesNeverAuthorizesRemoval() {
        XCTAssertEqual(StorageSafety.check(cache, target: target()), .unverified)
        XCTAssertEqual(StorageSafety.check(cache, target: target(), usage: usage(nil)), .unverified)
        XCTAssertEqual(StorageSafety.check(cache, target: target(), usage: usage(status: 1)), .unverified)
        XCTAssertEqual(StorageSafety.check(cache, target: target(), usage: usage(output: "")), .unverified)
        XCTAssertEqual(StorageSafety.check(cache, target: target(), usage: usage(output: "n/opt/file\n")), .unverified)
    }

    func testOpenCacheFileProtectsOnlyTheExactSubtree() {
        for path in [cache.path, cache.appendingPathComponent("data").path] {
            XCTAssertEqual(StorageSafety.check(cache, target: target(), usage: usage(output: "p42\nn\(path)\n")), .inUse)
        }
        XCTAssertEqual(StorageSafety.check(cache, target: target(), usage: usage(output: "p42\nn\(cache.path)-other/data\n")), .allowed)
    }

    func testCleanerPreservesRunningCacheAndKeepsProfileDataWhenClosed() throws {
        let cookies = root.appendingPathComponent("Cookies")
        try "session".write(to: cookies, atomically: true, encoding: .utf8)
        let guarded = target()
        XCTAssertEqual(Cleaner.clean(guarded, usage: usage([appID])).count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.path))
        XCTAssertEqual(Cleaner.clean(guarded, usage: usage()), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
        XCTAssertEqual(try String(contentsOf: cookies, encoding: .utf8), "session")
        XCTAssertEqual(CleanupLog.read().last?.item, guarded.id)
    }

    func testSymlinkLeafAndAncestorArePreserved() throws {
        let leaf = root.appendingPathComponent("linked-cache")
        try FileManager.default.createSymbolicLink(at: leaf, withDestinationURL: cache)
        let parent = root.appendingPathComponent("linked-profile")
        try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: root)
        for path in [leaf, parent.appendingPathComponent("Cache")] {
            let guarded = target([path])
            XCTAssertEqual(StorageSafety.check(path, target: guarded, usage: usage()), .unverified)
            XCTAssertEqual(Cleaner.clean(guarded, usage: usage()).count, 1)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.appendingPathComponent("data").path))
    }

    func testAgeAndRegularFileRulesAreRecheckedBeforeCleaning() throws {
        let report = root.appendingPathComponent("report.ips")
        try "historical diagnostic".write(to: report, atomically: true, encoding: .utf8)
        let rule = try YAMLDecoder().decode(PathSpec.self, from: "glob: ~/Library/Logs/DiagnosticReports/*.ips\nfiles_only: true\nolder_than_days: 30")
        let guarded = target([report], appIDs: [], rules: [report.path: rule])
        let old = Date().addingTimeInterval(-40 * 86_400)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: report.path)
        XCTAssertEqual(StorageSafety.check(report, target: guarded, usage: usage(nil)), .allowed)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: report.path)
        XCTAssertEqual(StorageSafety.check(report, target: guarded, usage: usage(nil)), .recent)
        XCTAssertEqual(Cleaner.clean(guarded, usage: usage(nil)).count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: report.path))
        XCTAssertEqual(StorageSafety.check(cache, target: target(appIDs: [], rules: [cache.path: rule]), usage: usage()), .unverified)
    }

    func testSelectingPathsRetainsProtectionAndOnlyMatchingAgeRules() throws {
        let other = root.appendingPathComponent("other.log")
        let rule = try YAMLDecoder().decode(PathSpec.self, from: "glob: ~/Library/Logs/*.log\nolder_than_days: 30")
        let original = target([cache, other], rules: [cache.path: rule, other.path: rule])
        let selected = try XCTUnwrap(original.selecting(paths: [cache]))
        XCTAssertEqual(selected.requiresAppsClosed, [appID])
        XCTAssertEqual(Set(selected.pathRules.keys), [cache.path])
        XCTAssertTrue(selected.cleanupUnits[0].needsUsageCheck)
        XCTAssertEqual(selected.cleanupUnits[0].requiresAppsClosed, [appID])
    }

    func testUnguardedLegacyTargetStillWorksWithoutSnapshot() {
        XCTAssertEqual(StorageSafety.check(cache, target: target(appIDs: [])), .allowed)
        XCTAssertFalse(target(appIDs: []).needsUsageCheck)
        XCTAssertEqual(StorageSafety.check(root.appendingPathComponent("missing"), target: target()), .unverified)
    }

    func testSingletonLockGuardDetectsLiveStaleUnreadableAndMirroredLocks() throws {
        let fm = FileManager.default
        let appSupport = root.appendingPathComponent("Library/Application Support/DemoApp")
        let partitionCache = appSupport.appendingPathComponent("Partitions/work/Cache")
        try fm.createDirectory(at: partitionCache, withIntermediateDirectories: true)
        let lock = appSupport.appendingPathComponent("SingletonLock")

        XCTAssertEqual(SingletonLockGuard.inspect(lock), .none)
        XCTAssertFalse(SingletonLockGuard.isPathHeld(partitionCache, home: root))

        // Live symlink lock protects nested partition cache and blocks StorageSafety even without bundle ID match.
        try fm.createSymbolicLink(atPath: lock.path, withDestinationPath: "macbook.local-4242")
        XCTAssertEqual(SingletonLockGuard.inspect(lock, isProcessAlive: { $0 == 4242 }), .live(pid: 4242))
        XCTAssertTrue(SingletonLockGuard.isPathHeld(partitionCache, home: root, isProcessAlive: { $0 == 4242 }))
        XCTAssertEqual(
            StorageSafety.check(partitionCache, target: target([partitionCache]), usage: usage([]), home: root, isProcessAlive: { $0 == 4242 }),
            .inUse
        )

        // Stale lock (dead PID) allows cleanup.
        XCTAssertEqual(SingletonLockGuard.inspect(lock, isProcessAlive: { _ in false }), .stale)
        XCTAssertFalse(SingletonLockGuard.isPathHeld(partitionCache, home: root, isProcessAlive: { _ in false }))
        XCTAssertEqual(
            StorageSafety.check(partitionCache, target: target([partitionCache]), usage: usage([]), home: root, isProcessAlive: { _ in false }),
            .allowed
        )

        // Malformed symlink or non-symlink fails closed as unreadable.
        try fm.removeItem(at: lock)
        try fm.createSymbolicLink(atPath: lock.path, withDestinationPath: "malformed")
        XCTAssertEqual(SingletonLockGuard.inspect(lock), .unreadable)
        XCTAssertTrue(SingletonLockGuard.isPathHeld(partitionCache, home: root))

        try fm.removeItem(at: lock)
        try "not-a-symlink".write(to: lock, atomically: true, encoding: .utf8)
        XCTAssertEqual(SingletonLockGuard.inspect(lock), .unreadable)
        XCTAssertTrue(SingletonLockGuard.isPathHeld(partitionCache, home: root))
        try fm.removeItem(at: lock)

        // Mirrored Chromium layout: cache under Library/Caches, SingletonLock under Library/Application Support.
        let browserCache = root.appendingPathComponent("Library/Caches/Arc/User Data/Default/Cache")
        let browserSupport = root.appendingPathComponent("Library/Application Support/Arc/User Data")
        try fm.createDirectory(at: browserCache, withIntermediateDirectories: true)
        try fm.createDirectory(at: browserSupport, withIntermediateDirectories: true)
        let browserLock = browserSupport.appendingPathComponent("SingletonLock")
        try fm.createSymbolicLink(atPath: browserLock.path, withDestinationPath: "macbook.local-7777")
        XCTAssertTrue(SingletonLockGuard.isPathHeld(browserCache, home: root, isProcessAlive: { $0 == 7777 }))
        XCTAssertFalse(SingletonLockGuard.isPathHeld(browserCache, home: root, isProcessAlive: { _ in false }))
    }

    func testExpandedToolsPreserveCredentialsAndAuthPlugins() throws {
        let fm = FileManager.default
        let now = Date()
        let old = now.addingTimeInterval(-15 * 86_400)
        @discardableResult
        func makeOld(_ relative: String, dir: Bool = false) throws -> URL {
            let url = root.appendingPathComponent(relative)
            try fm.createDirectory(at: dir ? url : url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !dir { try "x".write(to: url, atomically: true, encoding: .utf8) }
            try fm.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
            return url
        }

        let kubeDiscovery = try makeOld(".kube/cache/discovery", dir: true)
        let kubeHttp = try makeOld(".kube/cache/http", dir: true)
        try makeOld(".kube/cache/oidc-login/token.json")
        try makeOld(".kube/cache/kubelogin/token.json")
        try makeOld(".kube/config")

        let ghCache = try makeOld(".config/gh/cache", dir: true)
        try makeOld(".config/gh/hosts.yml")
        try makeOld(".config/gh/config.yml")

        var yaml = try String(contentsOf: TestSupport.stacksDirectory.appendingPathComponent("extended-tools.yaml"), encoding: .utf8)
        yaml = yaml.replacingOccurrences(of: #"\$\{[^:}]+:-([^}]+)\}"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "~/", with: root.path + "/")
        let entries = try XCTUnwrap(YAMLDecoder().decode(StackFile.self, from: yaml).storage)

        let kubectl = try XCTUnwrap(entries.first { $0.id == "kubectl-cache" })
        let kubectlPaths = Set((kubectl.paths ?? []).flatMap { PathResolver.resolve($0, now: now) }.map(\.path))
        XCTAssertEqual(kubectlPaths, [kubeDiscovery.path, kubeHttp.path])

        let gh = try XCTUnwrap(entries.first { $0.id == "github-cli-cache" })
        let ghPaths = Set((gh.paths ?? []).flatMap { PathResolver.resolve($0, now: now) }.map(\.path))
        XCTAssertEqual(ghPaths, [ghCache.path])
    }
}

final class ApplicationUsageSnapshotTests: XCTestCase {
    func testIdentifiesRenamedAppsAndHelpersOutsideApplicationsOncePerBundle() {
        let output = """
        11 1 501 12 0.0 00:10 client
        12 11 501 12 0.0 00:10 helper
        13 1 502 12 0.0 00:10 other-user
        14 1 501 12 0.0 00:10 tool
        """
        var lookups: [String] = []
        let ids = ApplicationUsageSnapshot.bundleIDs(from: ShellResult(status: 0, stdout: output, stderr: ""), resolveExecutable: { pid, _ in
            switch pid {
            case 11: "/opt/apps/Renamed Client.app/Contents/MacOS/Client"
            case 12: "/opt/apps/Renamed Client.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper"
            case 13: "/opt/Other.app/Contents/MacOS/Other"
            default: "/opt/tool"
            }
        }, identifyBundle: { bundle in
            lookups.append(bundle)
            return "org.example.Client"
        }, uid: 501)
        XCTAssertEqual(ids, ["org.example.Client"])
        XCTAssertEqual(lookups, ["/opt/apps/Renamed Client.app"])
    }

    func testFailedMalformedAndUnknownBundleInventoriesAreUnverified() {
        for result in [ShellResult(status: 1, stdout: "", stderr: "denied"),
                       ShellResult(status: 0, stdout: "", stderr: ""),
                       ShellResult(status: 0, stdout: "invalid", stderr: ""),
                       ShellResult(status: 0, stdout: "11 1 501 12 0 00:10 tool\ninvalid", stderr: "")] {
            XCTAssertNil(ApplicationUsageSnapshot.bundleIDs(from: result))
        }
        XCTAssertNil(ApplicationUsageSnapshot.bundleIDs(from: ShellResult(status: 0, stdout: "11 1 501 12 0 00:10 client", stderr: ""),
            resolveExecutable: { _, _ in "/opt/Gone.app/Contents/MacOS/Client" }, identifyBundle: { _ in nil }, uid: 501))
    }
}

final class MacCleanupDefinitionTests: XCTestCase {
    func testCatalogRetainsAgeAndOwnerRulesForExecutionAndExcludesDirectoriesAndLinks() throws {
        let root = try TestSupport.temporaryDirectory().resolvingSymlinksInPath()
        let key = "DEVSWEEP_SAFETY_FIXTURE"
        let previous = ProcessInfo.processInfo.environment[key]
        setenv(key, root.path, 1)
        defer {
            if let previous { setenv(key, previous, 1) } else { unsetenv(key) }
            try? FileManager.default.removeItem(at: root)
        }
        let old = root.appendingPathComponent("old.ips")
        let recent = root.appendingPathComponent("recent.ips")
        let directory = root.appendingPathComponent("folder.ips")
        let link = root.appendingPathComponent("link.ips")
        try "report".write(to: old, atomically: true, encoding: .utf8)
        try "recent".write(to: recent, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: old)
        for path in [old, directory] {
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-40 * 86_400)], ofItemAtPath: path.path)
        }
        let yaml = """
        stack: {id: fixture, name: Fixture}
        storage:
          - id: reports
            name: Reports
            risk: data_loss
            requires_apps_closed: [org.example.Client]
            paths:
              - glob: ${DEVSWEEP_SAFETY_FIXTURE:-~/nonexistent}/*.ips
                files_only: true
                older_than_days: 30
        """
        try yaml.write(to: root.appendingPathComponent("fixture.yaml"), atomically: true, encoding: .utf8)
        let definitions = DefinitionLoader.load(from: [root])
        XCTAssertEqual(definitions.issues, [])
        let prefs = PrefsSnapshot(notifications: false, suggestStorageGB: 2, notifyStorageGB: 5, suggestLimboMB: 150,
                                  notifyRAMMB: 500, lowDiskGB: 30, inactiveProjectDays: 21, artifactAgeDays: 7,
                                  artifactsToTrash: true, projectRoots: [])
        let target = try XCTUnwrap(StorageCatalog.build(prefs: prefs, definitions: definitions).first)
        XCTAssertEqual(target.paths, [old])
        XCTAssertEqual(target.pathRules[old.path]?.olderThanDays, 30)
        XCTAssertEqual(target.requiresAppsClosed, ["org.example.Client"])
    }

    func testInvalidOwnerListsAndAgeFiltersAreRejected() throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for extras in ["requires_apps_closed: []", "requires_apps_closed: ['com.example.*']",
                       "requires_apps_closed: [org.example.Client]\n    stop_processes: [client]",
                       "requires_apps_closed: [org.example.Client]\n    run: [[tool, clean]]"] {
            let yaml = """
            stack: {id: fixture, name: Fixture}
            storage:
              - id: cache
                name: Cache
                risk: redownload
                paths: [~/Library/Caches/example]
                \(extras)
            """
            try yaml.write(to: root.appendingPathComponent("fixture.yaml"), atomically: true, encoding: .utf8)
            let definitions = DefinitionLoader.load(from: [root])
            XCTAssertTrue(definitions.storage.isEmpty)
            XCTAssertFalse(definitions.issues.isEmpty)
        }
        let yaml = """
        stack: {id: fixture, name: Fixture}
        storage:
          - id: logs
            name: Logs
            risk: data_loss
            paths: [{glob: ~/Library/Logs/*.log, older_than_days: 0}]
        """
        try yaml.write(to: root.appendingPathComponent("fixture.yaml"), atomically: true, encoding: .utf8)
        XCTAssertTrue(DefinitionLoader.load(from: [root]).issues.contains { $0.contains("older_than_days") })
    }

    func testMacCatalogIsManualAndHistoricalLogsRequireConfirmation() {
        let definitions = TestSupport.definitions.storage.filter { $0.stack.id == "mac" }
        XCTAssertEqual(definitions.count, 11)
        for spec in definitions {
            XCTAssertEqual(spec.definition.autoSuggest, false)
            if spec.definition.id.contains("cache") {
                XCTAssertEqual(spec.risk, .redownload)
                XCTAssertFalse((spec.definition.requiresAppsClosed ?? []).isEmpty)
            } else {
                XCTAssertEqual(spec.risk, .dataLoss)
                guard case .trash = spec.method else { return XCTFail("Historical logs must go to Trash") }
                for path in spec.definition.paths ?? [] {
                    XCTAssertEqual(path.filesOnly, true)
                    XCTAssertEqual(path.olderThanDays, 30)
                }
            }
            XCTAssertNil(spec.definition.run)
            XCTAssertNil(spec.definition.stopProcesses)
        }
    }
}
