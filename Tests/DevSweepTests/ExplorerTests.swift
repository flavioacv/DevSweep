import XCTest
@testable import DevSweep

final class ExplorerTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        TestSupport.useEnglish()
        root = try TestSupport.temporaryDirectory().resolvingSymlinksInPath().standardizedFileURL
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    @discardableResult private func file(_ name: String, days: Int = 0) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 42, count: 8192).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-Double(days) * 86400)], ofItemAtPath: url.path)
        return url
    }

    func testRecursiveDiscoverySkipsLinksPackagesAndGitAndKeepsExactAuthorizations() throws {
        let expected = try file("nested/deep/archive.ZIP", days: 40)
        try file("Client.app/Contents/private.bin")
        try file("repo/.git/objects/private.bin")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: expected)
        let report = ExplorerScanner.scan(root: root, home: root, minimumBytes: 1, control: ScanControl())
        XCTAssertTrue(report.complete)
        XCTAssertEqual(report.entries.map(\.url), [expected])
        let entry = try XCTUnwrap(report.entries.first)
        XCTAssertTrue(entry.removable); XCTAssertFalse(entry.target.autoRecommend)
        XCTAssertEqual(entry.target.risk, .dataLoss)
        XCTAssertTrue(try XCTUnwrap(entry.target.pathAuthorizations[expected.path]).validates(expected))
        XCTAssertTrue(ExplorerScanner.scan(root: root, home: root, minimumBytes: 1_073_741_824, control: ScanControl()).entries.isEmpty)
    }

    func testFiltersUseAllocatedMeasurementsAgeAndNormalizedExtensions() throws {
        let url = try file("old.ZIP", days: 40)
        let entry = GeneralScanner.entry(url, root: root, area: .explorer, home: root)
        let filter = ExplorerFilter(minimumBytes: 4096, olderThanDays: 30, extensions: ".zip, MP4")
        XCTAssertTrue(filter.accepts(entry, measurement: SizeMeasurement(bytes: 8192, state: .complete)))
        XCTAssertFalse(filter.accepts(entry, measurement: SizeMeasurement(bytes: 8192, state: .partial)))
        XCTAssertFalse(filter.accepts(entry, measurement: nil))
        XCTAssertFalse(filter.accepts(entry, measurement: SizeMeasurement(bytes: 1, state: .complete)))
        var changed = filter; changed.olderThanDays = 90
        XCTAssertFalse(changed.accepts(entry, measurement: SizeMeasurement(bytes: 8192, state: .complete)))
        changed = filter; changed.extensions = "dmg"
        XCTAssertFalse(changed.accepts(entry, measurement: SizeMeasurement(bytes: 8192, state: .complete)))
        XCTAssertTrue(ExplorerFilter().accepts(entry, measurement: nil))
    }

    func testDepthBudgetCancellationAndMissingRootReportPartialDiscovery() throws {
        try file("one/two/three.bin")
        let depth = ExplorerScanner.scan(root: root, home: root, minimumBytes: 0, control: ScanControl(), depth: 0)
        XCTAssertFalse(depth.complete); XCTAssertFalse(depth.issues.isEmpty)
        XCTAssertFalse(ExplorerScanner.scan(root: root, home: root, minimumBytes: 0, control: ScanControl(), limit: 1).complete)
        XCTAssertFalse(ExplorerScanner.scan(root: root, home: root, minimumBytes: 0, control: ScanControl(), seconds: -1).complete)
        let cancelled = ScanControl(); cancelled.cancel()
        XCTAssertFalse(ExplorerScanner.scan(root: root, home: root, minimumBytes: 0, control: cancelled).complete)
        XCTAssertFalse(ExplorerScanner.scan(root: root.appendingPathComponent("absent"), home: root, minimumBytes: 0, control: ScanControl()).complete)
    }

    func testDisconnectedAndSimilarlyNamedVolumesDoNotFallBackToSystemDisk() {
        let system = VolumeSnapshot(path: "/", total: 1000, free: 100, readOnly: false)
        let disk = VolumeSnapshot(path: "/Volumes/Fixture", total: 2000, free: 900, readOnly: false)
        let path = URL(fileURLWithPath: "/Volumes/Fixture/projects")
        XCTAssertEqual(ExplorerScanner.volume(containing: path, volumes: [system, disk])?.path, disk.path)
        XCTAssertTrue(ExplorerScanner.hasLocalMount(path, volumes: [system, disk]))
        XCTAssertFalse(ExplorerScanner.hasLocalMount(path, volumes: [system]))
        XCTAssertFalse(ExplorerScanner.hasLocalMount(URL(fileURLWithPath: "/Volumes/Fixture-other"), volumes: [system, disk]))
        XCTAssertTrue(ExplorerScanner.hasLocalMount(root, volumes: []))
        XCTAssertNil(ExplorerScanner.volume(containing: root, volumes: []))
        XCTAssertFalse(ExplorerScanner.scan(root: path, home: root, minimumBytes: 0, control: ScanControl()).complete)
    }

    func testPermissionFailureIsNotAnEmptyCompleteFolder() throws {
        try file("blocked/hidden.bin")
        let blocked = root.appendingPathComponent("blocked")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: blocked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path) }
        let report = ExplorerScanner.scan(root: root, home: root, minimumBytes: 0, control: ScanControl())
        XCTAssertFalse(report.complete); XCTAssertFalse(report.issues.isEmpty)
    }

    @MainActor func testModelModeFiltersSortingExportAndStaleFileCache() async throws {
        let old = try file("nested/old.zip", days: 40)
        try file("nested/recent.dmg")
        let model = GeneralModel(home: root, logDirectory: root.appendingPathComponent("history"))
        model.area = .explorer; model.choose(root); model.explorerMode = .largeFiles
        await model.scan(force: true)
        XCTAssertEqual(model.visible.count, 2); XCTAssertTrue(model.fullyMeasured)
        for sort in ExplorerSort.allCases {
            model.explorerSort = sort; XCTAssertFalse(sort.title.isEmpty); XCTAssertEqual(model.visible.count, 2)
        }
        for mode in ExplorerMode.allCases { XCTAssertFalse(mode.title.isEmpty) }
        model.explorerSort = .oldest; XCTAssertEqual(model.visible.first?.url, old)
        model.explorerSort = .newest; XCTAssertNotEqual(model.visible.first?.url, old)
        model.explorerFilter.extensions = "zip"; model.explorerFilter.olderThanDays = 30
        XCTAssertEqual(model.visible.count, 1)
        let output = try XCTUnwrap(JSONSerialization.jsonObject(with: model.exportData()) as? [String: Any])
        XCTAssertEqual(output["mode"] as? String, "largeFiles")
        XCTAssertEqual(output["measurements_complete"] as? Bool, true)
        XCTAssertEqual((output["entries"] as? [[String: Any]])?.count, 1)
        XCTAssertTrue(model.measurementIssues.isEmpty)
        try FileManager.default.removeItem(at: old)
        await model.scan()
        XCTAssertEqual(model.report.entries.count, 1, "A removed authorized file must invalidate the cached scan")
        model.explorerFilter = ExplorerFilter(minimumBytes: 1_073_741_824)
        await model.scan()
        XCTAssertTrue(model.report.entries.isEmpty)
        model.choose(root.appendingPathComponent("absent")); await model.scan()
        XCTAssertFalse(model.report.complete)
    }

    @MainActor func testBatchedMeasurementsRetainEveryFileAndRootReplacementInvalidatesCache() async throws {
        for index in 0..<40 { try file("batch/file-\(index).bin") }
        let model = GeneralModel(home: root, logDirectory: root.appendingPathComponent("history"))
        model.area = .explorer; model.choose(root.appendingPathComponent("batch")); model.explorerMode = .largeFiles
        await model.scan(force: true)
        XCTAssertEqual(model.measurements.count, 40); XCTAssertTrue(model.fullyMeasured)
        await model.scan(); XCTAssertEqual(model.measurements.count, 40)
        try FileManager.default.moveItem(at: root.appendingPathComponent("batch"), to: root.appendingPathComponent("moved"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("batch"), withIntermediateDirectories: true)
        await model.scan()
        XCTAssertTrue(model.report.entries.isEmpty); XCTAssertTrue(model.measurements.isEmpty)
    }
}
