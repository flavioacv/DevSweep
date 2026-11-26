import XCTest
@testable import DevSweep

final class GeneralHygieneTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        TestSupport.useEnglish()
        root = try TestSupport.temporaryDirectory().resolvingSymlinksInPath().standardizedFileURL
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }
    @discardableResult private func file(_ path: String, data: Data = Data("fixture".utf8), days: Int = 10) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-Double(days) * 86400)], ofItemAtPath: url.path)
        return url
    }

    func testTemporaryScopeRequiresAgeExtensionOwnershipAndRejectsProtectedPathsAndLinks() throws {
        let old = try file("private/older.tmp")
        try file("private/recent.temp", days: 1)
        try file("private/notes.txt")
        try file("private/.ssh/key.tmp")
        try file("private/.zshrc.tmp")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("private/link.tmp"), withDestinationURL: old)
        let report = GeneralHygiene.temporaries(root: root.appendingPathComponent("private"), home: root.appendingPathComponent("home"), control: ScanControl())
        XCTAssertTrue(report.complete); XCTAssertEqual(report.entries.map(\.url), [old])
        let entry = try XCTUnwrap(report.entries.first)
        XCTAssertTrue(entry.removable); XCTAssertFalse(entry.target.autoRecommend)
        XCTAssertEqual(entry.target.pathRules[old.path]?.olderThanDays, 7)
        XCTAssertEqual(entry.target.risk, .dataLoss)
        let usage = ApplicationUsageSnapshot(runningBundleIDs: [], handles: ShellResult(status: 0, stdout: "p42\nn\(old.path)\n", stderr: ""))
        XCTAssertEqual(StorageSafety.check(old, target: entry.target, usage: usage), .inUse)
        try Data("changed".utf8).write(to: old)
        XCTAssertEqual(StorageSafety.check(old, target: entry.target, usage: usage), .unverified)
    }

    func testTemporaryFailureAndCancellationAreExplicit() throws {
        XCTAssertFalse(GeneralHygiene.temporaries(root: root.appendingPathComponent("absent"), home: root, control: ScanControl()).complete)
        try file("private/deep/old.tmp")
        let cancelled = ScanControl(); cancelled.cancel()
        XCTAssertFalse(GeneralHygiene.temporaries(root: root.appendingPathComponent("private"), home: root, control: cancelled).complete)
    }

    func testTrashIsReviewOnlyIncludingFoldersAndDoesNotFollowLinks() throws {
        XCTAssertTrue(GeneralHygiene.trash(home: root, control: ScanControl()).entries.isEmpty)
        let trashed = try file(".Trash/old.txt")
        try file(".Trash/Folder/keep.txt")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(".Trash/link"), withDestinationURL: trashed)
        let report = GeneralHygiene.trash(home: root, control: ScanControl())
        XCTAssertTrue(report.complete); XCTAssertEqual(report.entries.count, 2)
        XCTAssertTrue(report.entries.allSatisfy { !$0.removable })
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashed.path))
        let cancelled = ScanControl(); cancelled.cancel()
        XCTAssertFalse(GeneralHygiene.trash(home: root, control: cancelled).complete)
    }

    func testExternalMetadataValidatesHeadersAndPreservesTrashBackupsAppleDoubleAndPersonalFiles() throws {
        let store = try file("volume/folder/.DS_Store", data: Data([0, 0, 0, 1, 0x42, 0x75, 0x64, 0x31]))
        let temporary = try file("volume/.TemporaryItems/old.bin")
        let apple = try file("volume/folder/._photo.jpg", data: Data([0, 5, 0x16, 7, 0, 2, 0, 0]))
        try file("volume/other/.DS_Store", data: Data("not metadata".utf8))
        try file("volume/new/.DS_Store", data: Data([0, 0, 0, 1, 0x42, 0x75, 0x64, 0x31]), days: 1)
        try file("volume/._notes.txt")
        try file("volume/.Trashes/501/keep.txt")
        try file("volume/.Trashes/501/.DS_Store", data: Data([0, 0, 0, 1, 0x42, 0x75, 0x64, 0x31]))
        try file("volume/Backups.backupdb/.DS_Store", data: Data([0, 0, 0, 1, 0x42, 0x75, 0x64, 0x31]))
        try file("volume/.TemporaryItems/.ssh/keep.tmp")
        let volume = root.appendingPathComponent("volume")
        let mounts = [VolumeSnapshot(path: volume.path, total: 1000, free: 500, readOnly: false)]
        let report = GeneralHygiene.external(root: volume, home: root.appendingPathComponent("home"), volumes: mounts, control: ScanControl())
        XCTAssertTrue(report.complete)
        XCTAssertEqual(Set(report.entries.map(\.url)), [store, temporary])
        XCTAssertEqual(Set(report.entries.filter(\.removable).map(\.url)), [store, temporary])
        XCTAssertTrue(report.entries.allSatisfy { !$0.target.autoRecommend })
        XCTAssertTrue(FileManager.default.fileExists(atPath: apple.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: volume.appendingPathComponent(".Trashes/501/keep.txt").path))
        for protected in [".Trashes", "Backups.backupdb"] {
            let nested = GeneralHygiene.external(root: volume.appendingPathComponent(protected), home: root, volumes: mounts, control: ScanControl())
            XCTAssertTrue(nested.entries.isEmpty, "Choosing a protected folder directly must not bypass exclusions")
        }
        XCTAssertFalse(GeneralHygiene.external(root: volume, home: root, volumes: [], control: ScanControl()).complete)
        XCTAssertFalse(GeneralHygiene.external(root: volume, home: root, volumes: [VolumeSnapshot(path: volume.path, total: 1000, free: 500, readOnly: true)], control: ScanControl()).complete)
        XCTAssertFalse(GeneralHygiene.external(root: nil, home: root, volumes: mounts, control: ScanControl()).complete)
        let cancelled = ScanControl(); cancelled.cancel()
        XCTAssertFalse(GeneralHygiene.external(root: volume, home: root, volumes: mounts, control: cancelled).complete)
    }

    func testDeniedTrashAccessIsPartialAndAreaKeysAreLocalized() throws {
        try file(".Trash/keep")
        let trash = root.appendingPathComponent(".Trash")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: trash.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: trash.path) }
        XCTAssertFalse(GeneralHygiene.trash(home: root, control: ScanControl()).complete)
        for area in [GeneralArea.temporaries, .trash, .external] {
            XCTAssertFalse(area.title.isEmpty); XCTAssertFalse(area.icon.isEmpty)
        }
    }

    func testGeneralScannerConnectsTrashReviewAndExternalSelectionRequirement() throws {
        try file(".Trash/review.txt")
        let trash = GeneralScanner.scan(.trash, home: root, selectedRoot: nil, prefs: PrefsSnapshot.current(), control: ScanControl())
        XCTAssertEqual(trash.entries.count, 1); XCTAssertFalse(trash.entries[0].removable)
        let external = GeneralScanner.scan(.external, home: root, selectedRoot: nil, prefs: PrefsSnapshot.current(), control: ScanControl())
        XCTAssertFalse(external.complete); XCTAssertFalse(external.issues.isEmpty)
    }
}
