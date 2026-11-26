import XCTest
@testable import DevSweep

final class AppUninstallTests: XCTestCase {
    private var home: URL!
    private var apps: URL { home.appendingPathComponent("Applications") }
    private let id = "org.example.Client"
    override func setUpWithError() throws {
        TestSupport.useEnglish()
        home = try TestSupport.temporaryDirectory().resolvingSymlinksInPath().standardizedFileURL
    }
    override func tearDown() { try? FileManager.default.removeItem(at: home) }
    @discardableResult private func file(_ path: String, data: Data = Data("fixture".utf8)) throws -> URL {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url); return url
    }
    @discardableResult private func application(_ name: String = "Client", identifier: String? = nil) throws -> URL {
        let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": identifier ?? id], format: .xml, options: 0)
        try file("Applications/\(name).app/Contents/Info.plist", data: data)
        return apps.appendingPathComponent(name + ".app")
    }
    private func plan(_ app: URL, control: ScanControl = ScanControl()) -> GeneralReport {
        AppUninstall.scan(application: app, home: home, control: control, roots: [apps])
    }

    func testExactAssociationDoesNotGuessNamesAndKeepsContainersAndPersonalSelectionMetadata() throws {
        let app = try application()
        for path in ["Caches/\(id)/data", "Logs/\(id)/data", "Preferences/\(id).plist", "Application Support/\(id)/data",
                     "Saved Application State/\(id).savedState/data", "Containers/\(id)/Data/keep"] { try file("Library/" + path) }
        try file("Library/Application Support/Client/keep")
        try file("Library/Group Containers/group.\(id)/keep")
        let report = plan(app)
        XCTAssertTrue(report.complete); XCTAssertEqual(report.entries.count, 7)
        XCTAssertTrue(report.entries.allSatisfy { $0.association?.bundleID == id && !$0.target.autoRecommend && $0.target.risk == .dataLoss })
        let container = try XCTUnwrap(report.entries.first { $0.association?.kind == .container })
        XCTAssertFalse(container.removable); XCTAssertTrue(container.association!.kind.personal)
        let support = try XCTUnwrap(report.entries.first { $0.association?.kind == .support })
        XCTAssertTrue(support.removable); XCTAssertTrue(support.association!.kind.personal)
        XCTAssertFalse(report.entries.contains { $0.url.path.contains("Group Containers") || $0.url.lastPathComponent == "Client" })
        for entry in report.entries {
            XCTAssertFalse(entry.association!.kind.title.isEmpty); XCTAssertFalse(entry.association!.evidence.isEmpty)
            XCTAssertEqual(entry.target.requiresAppsClosed, [id])
        }
    }

    func testSecondInstallationProtectsAssociatedDataAndFreshInventoryRejectsNewCopyAfterReview() throws {
        let app = try application()
        try file("Library/Caches/\(id)/data")
        let initial = plan(app)
        let related = try XCTUnwrap(initial.entries.first { $0.association?.kind == .cache })
        let context = try XCTUnwrap(related.target.appRemovalContext)
        XCTAssertTrue(context.validates())
        let selected = try XCTUnwrap(related.target.selecting(paths: [related.url]))
        XCTAssertNotNil(selected.cleanupUnits[0].appRemovalContext)
        try application("Copy")
        XCTAssertFalse(context.validates())
        let usage = ApplicationUsageSnapshot(runningBundleIDs: [], handles: ShellResult(status: 0, stdout: "p42\nn/opt/unrelated\n", stderr: ""))
        XCTAssertEqual(StorageSafety.check(related.url, target: selected, usage: usage), .unverified)
        let shared = plan(app)
        XCTAssertTrue(shared.complete); XCTAssertFalse(shared.issues.isEmpty)
        XCTAssertTrue(shared.entries.filter { $0.association?.kind != .application }.allSatisfy { !$0.removable })
        XCTAssertTrue(shared.entries.first!.removable)
        XCTAssertTrue(try XCTUnwrap(shared.entries.first?.target.appRemovalContext).validates(), "A separate installation does not prevent removing this app bundle")
    }

    func testIdentityChangesRunningOwnerAndUncertainInventoryProtectData() throws {
        let app = try application()
        try file("Library/Preferences/\(id).plist")
        let related = try XCTUnwrap(plan(app).entries.first { $0.association?.kind == .preferences })
        let running = ApplicationUsageSnapshot(runningBundleIDs: [id], handles: ShellResult(status: 0, stdout: "p42\nn/opt/unrelated\n", stderr: ""))
        XCTAssertEqual(StorageSafety.check(related.url, target: related.target, usage: running), .inUse)
        try file("Applications/Client.app/Contents/Info.plist", data: Data("changed".utf8))
        XCTAssertFalse(try XCTUnwrap(related.target.appRemovalContext).validates())
        XCTAssertFalse(plan(app).complete)
        let other = try application("Other")
        let report = plan(other)
        XCTAssertFalse(report.complete)
        XCTAssertTrue(report.entries.filter { $0.association?.kind != .application }.allSatisfy { !$0.removable })
    }

    func testRejectsAppleMalformedIdentifiersAndLinkedSupport() throws {
        for value in ["com.apple.Fixture", "org.example/../../outside", "org..example", ".org.example", "org.example."] {
            let app = try application("Invalid", identifier: value)
            XCTAssertFalse(plan(app).complete)
        }
        let app = try application()
        let actual = try file("private/keep").deletingLastPathComponent()
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Library/Caches"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent("Library/Caches/\(id)"), withDestinationURL: actual)
        let report = plan(app)
        XCTAssertFalse(try XCTUnwrap(report.entries.first { $0.association?.kind == .cache }).removable)
        let stopped = ScanControl(); stopped.cancel()
        XCTAssertFalse(plan(app, control: stopped).complete)
    }

    @MainActor func testModelLoadsPlanExportsEvidenceAndLeavesNothingSelected() async throws {
        let app = try application()
        try file("Library/Caches/\(id)/data")
        let model = GeneralModel(home: home, logDirectory: home.appendingPathComponent("history"), applicationRoots: [apps])
        model.area = .applications; model.uninstallApplication = app
        await model.scan(force: true)
        XCTAssertTrue(model.report.complete); XCTAssertTrue(model.fullyMeasured)
        XCTAssertTrue(model.selected.isEmpty); XCTAssertEqual(model.report.entries.count, 2)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: model.exportData()) as? [String: Any])
        let entries = try XCTUnwrap(json["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 2); XCTAssertNotNil(entries[0]["association"])
        model.uninstallApplication = nil; await model.scan(force: true)
        XCTAssertEqual(model.report.entries.count, 1); XCTAssertNil(model.report.entries[0].association)
    }
}
