import XCTest
@testable import DevSweep

final class WorktreeReferenceTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws { root = try TestSupport.temporaryDirectory().resolvingSymlinksInPath().standardizedFileURL }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }
    @discardableResult private func put(_ name: String, _ text: String = "") throws -> URL {
        let file = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file); return file
    }
    func testAgentFoldersAndReciprocalRegisteredWorktreesAreDiscoveredOnce() throws {
        try put("repo/package.json", "{}")
        try put("repo/.claude/worktrees/agent/package.json", "{}")
        try put("repo/.codex/worktrees/agent/package.json", "{}")
        try put("repo/.cursor/worktrees/agent/package.json", "{}")
        try put("repo/.worktrees/agent/package.json", "{}")
        let worktree = root.appendingPathComponent("deep/a/b/c/d/e/linked")
        let admin = root.appendingPathComponent("repo/.git/worktrees/linked")
        try put("repo/.git/worktrees/linked/gitdir", worktree.appendingPathComponent(".git").path)
        try put("deep/a/b/c/d/e/linked/.git", "gitdir: " + admin.path)
        try put("deep/a/b/c/d/e/linked/package.json", "{}")
        let head = try put("repo/.git/worktrees/linked/HEAD", "ref: refs/heads/topic")
        let timestamp = Date(timeIntervalSince1970: 2_000_000_000)
        try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: head.path)
        let repo = root.appendingPathComponent("repo")
        XCTAssertEqual(WorktreeDiscovery.linked(to: repo, roots: [root]).map(\.path), [worktree.path])
        let found = ProjectScanner.scan(roots: [root.path, root.path], markers: ["package.json"], activityFiles: [], skipNames: [])
        XCTAssertEqual(found.count, 6)
        XCTAssertEqual(found.filter { $0.url.path == worktree.path }.count, 1)
        XCTAssertEqual(found.first { $0.url.path == worktree.path }?.lastActivity, timestamp)
        let artifact = try put("deep/a/b/c/d/e/linked/build/result.bin")
        var prefs = PrefsSnapshot.current(); prefs.workspacesConfirmed = true; prefs.projectRoots = [root.path]
        let report = GeneralScanner.scan(.projects, home: root, selectedRoot: root, prefs: prefs, control: ScanControl())
        let target = try XCTUnwrap(report.entries.first { $0.url.path == artifact.deletingLastPathComponent().path }?.target)
        XCTAssertEqual(target.projectRootsByPath[artifact.deletingLastPathComponent().path]?.path, worktree.path)
        XCTAssertTrue(target.protectNestedRepositories)
        XCTAssertFalse(report.entries.contains { $0.url.path == worktree.path })

    }
    func testWorktreeEscapeBadBacklinkAndSymlinkAreIgnored() throws {
        let repo = root.appendingPathComponent("repo"), outside = root.appendingPathComponent("outside")
        let admin = repo.appendingPathComponent(".git/worktrees/topic")
        try put("repo/package.json", "{}")
        try put("repo/.git/worktrees/topic/gitdir", outside.appendingPathComponent(".git").path)
        try put("outside/.git", "gitdir: " + admin.path)
        XCTAssertTrue(WorktreeDiscovery.linked(to: repo, roots: [repo]).isEmpty)
        try put("outside/.git", "gitdir: /opt/unknown")
        XCTAssertTrue(WorktreeDiscovery.linked(to: repo, roots: [root]).isEmpty)
        let alias = root.appendingPathComponent("repo/.worktrees")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: outside)
        try put("outside/package.json", "{}")
        let found = ProjectScanner.scan(roots: [repo.path], markers: ["package.json"], activityFiles: [], skipNames: [])
        XCTAssertEqual(found.map(\.url.path), [repo.path])
    }
    func testReferencesUseExactTokensAndNeverExportMatchingContents() throws {
        let app = root.appendingPathComponent("Applications/Example.app")
        let shell = try put(".zshrc", "export SECRET=fixture-secret com.example.Tool\ncom.example.ToolExtra\n# " + app.path + "/Contents/MacOS/tool\n")
        try put(".cursor/mcp.json", "{\"mcpServers\": {\"sample\": {\"command\": \"com.example.Tool\", \"env\": {\"TOKEN\": \"fixture-secret\"}}}}")
        let before = try Data(contentsOf: shell)
        let result = ConfigReferences.scan(home: root, application: app, bundleID: "com.example.Tool", control: ScanControl())
        XCTAssertTrue(result.complete); XCTAssertEqual(result.references.count, 3)
        XCTAssertEqual(result.references.filter { $0.kind == "shell" }.map(\.line), [1, 3])
        let encoded = String(decoding: try JSONEncoder().encode(result.references), as: UTF8.self)
        XCTAssertFalse(encoded.contains("fixture-secret")); XCTAssertFalse(encoded.contains("export SECRET"))
        XCTAssertEqual(try Data(contentsOf: shell), before)
    }
    func testReferenceLimitsSymlinksAndCancellationAreExplicit() throws {
        let app = root.appendingPathComponent("Applications/Example.app")
        try put(".bashrc", String(repeating: "a", count: 524_289))
        let external = try put("external", "com.example.Tool")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(".zshrc"), withDestinationURL: external)
        var result = ConfigReferences.scan(home: root, application: app, bundleID: "com.example.Tool", control: ScanControl())
        XCTAssertFalse(result.complete); XCTAssertEqual(result.issues.count, 2); XCTAssertTrue(result.references.isEmpty)
        let cancelled = ScanControl(); cancelled.cancel()
        result = ConfigReferences.scan(home: root, application: app, bundleID: "com.example.Tool", control: cancelled)
        XCTAssertFalse(result.complete)
    }
    func testAssistedUninstallKeepsConfigReferencesOutsideRemovalTargets() throws {
        TestSupport.useEnglish()
        let app = root.appendingPathComponent("Applications/Example.app")
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.example.Tool"], format: .xml, options: 0)
        try put("Applications/Example.app/Contents/Info.plist", String(decoding: plist, as: UTF8.self))
        let config = try put(".profile", "com.example.Tool")
        let report = AppUninstall.scan(application: app, home: root, control: ScanControl(), roots: [root.appendingPathComponent("Applications")])
        XCTAssertTrue(report.complete); XCTAssertTrue(report.referencesComplete)
        XCTAssertEqual(report.references.map(\.path), [config.path])
        XCTAssertFalse(report.entries.contains { $0.url == config })
    }
    @MainActor func testModelExportsReferenceLocationsWithoutContents() async throws {
        let app = root.appendingPathComponent("Applications/Example.app")
        let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.example.Tool"], format: .xml, options: 0)
        try put("Applications/Example.app/Contents/Info.plist", String(decoding: data, as: UTF8.self))
        try put(".zshrc", "com.example.Tool fixture-secret")
        let model = GeneralModel(home: root, applicationRoots: [root.appendingPathComponent("Applications")])
        model.area = .applications; model.uninstallApplication = app
        await model.scan(force: true)
        let output = try model.exportData()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: output) as? [String: Any])
        XCTAssertEqual((object["config_references"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(object["config_references_complete"] as? Bool, true)
        XCTAssertFalse(String(decoding: output, as: UTF8.self).contains("fixture-secret"))
        try put(".zshrc", "unrelated")
        await model.scan()
        XCTAssertTrue(model.report.references.isEmpty)
    }

}
