import XCTest
@testable import DevSweep

final class GeneralScanTests: XCTestCase {
    private var home: URL!
    private var prefs: PrefsSnapshot {
        PrefsSnapshot(notifications: false, suggestStorageGB: 2, notifyStorageGB: 5, suggestLimboMB: 150,
                      notifyRAMMB: 500, lowDiskGB: 30, inactiveProjectDays: 21, artifactAgeDays: 7,
                      artifactsToTrash: true, projectRoots: [home.path])
    }
    override func setUpWithError() throws { TestSupport.useEnglish(); home = try TestSupport.temporaryDirectory().resolvingSymlinksInPath().standardizedFileURL }
    override func tearDown() { try? FileManager.default.removeItem(at: home) }
    @discardableResult private func make(_ relative: String, data: String = "fixture", days: Int = 40) throws -> URL {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-Double(days) * 86_400)], ofItemAtPath: url.path)
        return url
    }

    func testGenericLogsDiscoverUnregisteredAppsAndPreserveOtherContent() throws {
        let old = try make("Library/Logs/Unregistered/old.log")
        let rotated = try make("Library/Logs/Other/service.log.2")
        let support = try make("Library/Application Support/AnotherApp/Logs/old.log")
        let sandbox = try make("Library/Containers/org.example.App/Data/Library/Logs/old.log")
        try make("Library/Logs/Unregistered/recent.log", days: 1)
        try make("Library/Logs/Unregistered/notes.txt")
        try make("Library/Application Support/AnotherApp/credentials.json")
        let report = GeneralScanner.scan(.logs, home: home, selectedRoot: nil, prefs: prefs, control: ScanControl())
        XCTAssertTrue(report.complete)
        XCTAssertEqual(Set(report.entries.map { $0.url.path }), Set([old, rotated, support, sandbox].map(\.path)))
        for entry in report.entries {
            XCTAssertTrue(entry.removable)
            XCTAssertEqual(entry.target.risk, .dataLoss)
            XCTAssertFalse(entry.target.autoRecommend)
            XCTAssertEqual(entry.target.pathRules[entry.url.path]?.olderThanDays, 30)
        }
    }

    func testWalkNeverFollowsSymlinksAndReportsCancellationAndLimits() throws {
        try make("folder/file.log")
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent("link"), withDestinationURL: home.appendingPathComponent("folder"))
        let ordinary = DirectoryWalker.walk(home, depth: 3, control: ScanControl())
        XCTAssertTrue(ordinary.complete)
        XCTAssertEqual(ordinary.files.count, 1)
        let stopped = ScanControl(); stopped.cancel()
        XCTAssertFalse(DirectoryWalker.walk(home, depth: 3, control: stopped).complete)
        XCTAssertFalse(DirectoryWalker.walk(home, depth: 3, control: ScanControl(), limit: 1).complete)
        XCTAssertFalse(DirectoryWalker.walk(home.appendingPathComponent("absent"), depth: 3, control: ScanControl()).complete)
    }

    func testIdentityRejectsReplacedFilesModifiedFilesAndRedirectedAncestors() throws {
        let file = try make("root/file.log")
        let root = home.appendingPathComponent("root")
        let authorization = try XCTUnwrap(PathAuthorization.issue(file, within: root))
        XCTAssertTrue(authorization.validates(file))
        try "new data".write(to: file, atomically: false, encoding: .utf8)
        XCTAssertFalse(authorization.validates(file))
        let fresh = try XCTUnwrap(PathAuthorization.issue(file, within: root))
        try FileManager.default.moveItem(at: root, to: home.appendingPathComponent("renamed"))
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: home.appendingPathComponent("renamed"))
        XCTAssertFalse(fresh.validates(file))
        XCTAssertNil(PathAuthorization.issue(home, within: home))
        XCTAssertNil(PathAuthorization.issue(file, within: URL(fileURLWithPath: "/")))
    }

    func testCleanerPreservesChangedScanTargetsAndSelectionRetainsAuthorization() throws {
        let file = try make("Downloads/review.log")
        let entry = GeneralScanner.entry(file, root: home.appendingPathComponent("Downloads"), area: .logs, home: home)
        let selected = try XCTUnwrap(entry.target.selecting(paths: [file]))
        XCTAssertEqual(selected.pathAuthorizations.count, 1)
        XCTAssertTrue(selected.needsUsageCheck)
        try "changed after review".write(to: file, atomically: false, encoding: .utf8)
        let usage = ApplicationUsageSnapshot(runningBundleIDs: [], handles: ShellResult(status: 0, stdout: "p42\nn/opt/unrelated\n", stderr: ""))
        XCTAssertEqual(StorageSafety.check(file, target: selected, usage: usage), .unverified)
        XCTAssertFalse(Cleaner.clean(selected, usage: usage).isEmpty)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "changed after review")
    }

    func testGeneralActionsCannotAuthorizeShellCredentialsOrProtectedRoots() throws {
        let shell = try make(".zshrc")
        let key = try make(".ssh/key")
        try make("Documents/keep.txt")
        for path in [shell, key, home.appendingPathComponent("Documents")] {
            XCTAssertFalse(GeneralScanner.entry(path, root: home, area: .explorer, home: home).removable)
        }
        let ordinary = try make("Downloads/old.bin")
        XCTAssertTrue(GeneralScanner.entry(ordinary, root: home.appendingPathComponent("Downloads"), area: .explorer, home: home).removable)
    }

    func testGeneralProjectsRecognizeDifferentStacksAndRespectConfirmation() throws {
        try make("rust/Cargo.toml")
        try make("rust/target/output.bin")
        try make("python/pyproject.toml")
        try make("python/.venv/pyvenv.cfg")
        try make("unrelated/target/keep.txt")
        let report = GeneralScanner.scan(.projects, home: home, selectedRoot: home, prefs: prefs, control: ScanControl())
        XCTAssertTrue(report.complete)
        XCTAssertEqual(Set(report.entries.map { $0.url.lastPathComponent }), ["target", ".venv"])
        XCTAssertTrue(report.entries.allSatisfy { $0.target.protectNestedRepositories && !$0.target.projectRootsByPath.isEmpty })
        var unconfirmed = prefs; unconfirmed.workspacesConfirmed = false
        XCTAssertTrue(GeneralScanner.scan(.projects, home: home, selectedRoot: home, prefs: unconfirmed, control: ScanControl()).entries.isEmpty)
    }

    func testGeneralProjectRemovalProtectsNestedRepositories() throws {
        try make("app/package.json")
        let marker = try make("app/node_modules/local/.git", data: "gitdir: elsewhere")
        let report = GeneralScanner.scan(.projects, home: home, selectedRoot: home, prefs: prefs, control: ScanControl())
        let target = try XCTUnwrap(report.entries.first?.target)
        let usage = ApplicationUsageSnapshot(runningBundleIDs: [], handles: ShellResult(status: 0, stdout: "p42\nn/opt/unrelated\n", stderr: ""))
        XCTAssertEqual(StorageSafety.check(target.paths[0], target: target, usage: usage), .tracked)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    func testGeneralCachesRequireRecognizableEvidenceAndOwnerOrTag() throws {
        try make("Library/Application Support/Unknown/Code Cache/code.bin")
        try make("Library/Application Support/Unknown/Local Storage/keep")
        try make("Library/Caches/Tagged/CACHEDIR.TAG", data: "Signature: 8a477f597d28d172789f06886806bc55\n")
        try make("Library/Caches/Tagged/cached.bin")
        let report = GeneralScanner.scan(.caches, home: home, selectedRoot: nil, prefs: prefs,
                                         control: ScanControl(), applicationRoots: [])
        XCTAssertTrue(report.complete)
        XCTAssertEqual(Set(report.entries.map { $0.url.lastPathComponent }), ["Code Cache", "Tagged"])
        XCTAssertFalse(try XCTUnwrap(report.entries.first { $0.url.lastPathComponent == "Code Cache" }).removable)
        XCTAssertTrue(try XCTUnwrap(report.entries.first { $0.url.lastPathComponent == "Tagged" }).removable)
    }

    func testApplicationInventoryDoesNotAuthorizeAppleAppsAndKeepsSupportData() throws {
        let apps = home.appendingPathComponent("Applications")
        for (name, id) in [("Client", "org.example.Client"), ("System", "com.apple.Fixture")] {
            let info: [String: Any] = ["CFBundleIdentifier": id, "CFBundleName": name, "CFBundlePackageType": "APPL"]
            let path = apps.appendingPathComponent(name + ".app/Contents/Info.plist")
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: path)
        }
        let report = GeneralScanner.scan(.applications, home: home, selectedRoot: nil, prefs: prefs,
                                         control: ScanControl(), applicationRoots: [apps])
        XCTAssertEqual(report.entries.count, 2)
        let client = try XCTUnwrap(report.entries.first { $0.url.lastPathComponent == "Client.app" })
        XCTAssertTrue(client.removable)
        XCTAssertEqual(client.target.requiresAppsClosed, ["org.example.Client"])
        XCTAssertFalse(try XCTUnwrap(report.entries.first { $0.url.lastPathComponent == "System.app" }).removable)
        let owned = try make("Library/Application Support/Client/Code Cache/data")
        let caches = GeneralScanner.scan(.caches, home: home, selectedRoot: nil, prefs: prefs, control: ScanControl(), applicationRoots: [apps])
        let cache = try XCTUnwrap(caches.entries.first)
        XCTAssertTrue(cache.removable)
        XCTAssertEqual(cache.target.requiresAppsClosed, ["org.example.Client"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: owned.path))
    }

    func testInstallerDiscoveryDoesNotSelectArbitraryZipsOrDocuments() throws {
        let installer = try make("Downloads/tool.dmg")
        try make("Downloads/document.txt")
        try make("Downloads/arbitrary.zip", data: "invalid zip")
        let report = GeneralScanner.scan(.installers, home: home, selectedRoot: nil, prefs: prefs, control: ScanControl())
        XCTAssertEqual(report.entries.map { $0.url.path }, [installer.path])
        XCTAssertTrue(report.entries[0].removable)
        let absent = GeneralScanner.scan(.explorer, home: home, selectedRoot: home.appendingPathComponent("absent"), prefs: prefs, control: ScanControl())
        XCTAssertFalse(absent.complete)
    }

    func testZIPInstallerRecognitionUsesCentralDirectoryWithoutExtracting() throws {
        try make("archive/Installer.app/Contents/Info.plist")
        let archive = home.appendingPathComponent("app.zip")
        let input = home.appendingPathComponent("archive/Installer.app/Contents/Info.plist")
        let zipped = Shell.run("/usr/bin/zip", ["-q", archive.path, input.path], timeout: 5)
        XCTAssertEqual(zipped.status, 0)
        XCTAssertTrue(InstallerArchive.containsInstaller(archive))
        XCTAssertFalse(InstallerArchive.containsInstaller(try make("bad.zip", data: "not an archive")))
        XCTAssertFalse(InstallerArchive.containsInstaller(home.appendingPathComponent("missing.zip")))
    }
}
