import XCTest
@testable import DevSweep

final class SizeMeasurementTests: XCTestCase {
    func testPermissionFailureRetainsMeasuredBytesAsPartial() {
        let result = SizeCalculator.parse(ShellResult(status: 1, stdout: "12\t/p/cache\n", stderr: "permission denied"), expectedPaths: 2)
        XCTAssertEqual(result.bytes, 12 * 1024)
        XCTAssertEqual(result.state, .partial)
        XCTAssertEqual(result.errors, ["permission denied"])
    }

    func testFailedMeasurementIsUnavailableRatherThanAnEmptyFolder() {
        let failed = SizeCalculator.parse(ShellResult(status: 1, stdout: "", stderr: "unreadable"), expectedPaths: 1)
        let empty = SizeCalculator.parse(ShellResult(status: 0, stdout: "0\t/p/cache\n", stderr: ""), expectedPaths: 1)
        XCTAssertEqual(failed.bytes, empty.bytes)
        XCTAssertEqual(failed.state, .unavailable)
        XCTAssertEqual(empty.state, .complete)
    }

    func testTruncatedOrMalformedOutputCannotBeComplete() {
        for output in ["", "bad\t/p/cache\n", "-1\t/p/cache\n", "9223372036854775807\t/p/cache\n"] {
            XCTAssertEqual(SizeCalculator.parse(ShellResult(status: 0, stdout: output, stderr: ""), expectedPaths: 1).state, .unavailable)
        }
        XCTAssertEqual(SizeCalculator.parse(ShellResult(status: 0, stdout: "4\t/p/cache\n", stderr: ""), expectedPaths: 2).state, .partial)
    }

    func testCombiningChunksPreservesUnknownAndPartialStates() {
        let good = SizeMeasurement(bytes: 1024, state: .complete)
        let unknown = SizeMeasurement(bytes: 0, state: .unavailable, errors: ["denied"])
        XCTAssertEqual(SizeCalculator.combine([good, unknown]), SizeMeasurement(bytes: 1024, state: .partial, errors: ["denied"]))
        XCTAssertEqual(SizeCalculator.combine([unknown]).state, .unavailable)
        XCTAssertEqual(SizeCalculator.combine([good]).state, .complete)
        XCTAssertEqual(SizeCalculator.combine([]).state, .complete)
    }

    func testDuplicatePathsDoNotInflateMeasurements() throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(repeating: 0x41, count: 8192).write(to: directory.appendingPathComponent("output.bin"))
        let once = SizeCalculator.measure([directory])
        XCTAssertEqual(once.state, .complete)
        XCTAssertGreaterThan(once.bytes, 0)
        XCTAssertEqual(SizeCalculator.measure([directory, directory]), once)
        XCTAssertEqual(SizeCalculator.measure([directory.appendingPathComponent("missing")]), SizeMeasurement(bytes: 0, state: .complete))
    }
}

final class CleanupSelectionTests: XCTestCase {
    private func target(paths: [URL], method: CleanMethod = .delete) -> StorageTarget {
        StorageTarget(id: "builds", stack: StackInfo(id: "test", name: "Test", icon: "gear", order: 0),
                      title: "Builds", detail: "", risk: .redownload, paths: paths, method: method,
                      authorizedProjectPaths: paths)
    }

    func testSubsetCleanupPreservesUnselectedArtifactAndRejectsUnlistedPath() throws {
        let root = try TestSupport.temporaryDirectory().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("one/build")
        let second = root.appendingPathComponent("two/build")
        let unrelated = root.appendingPathComponent("source")
        for url in [first, second, unrelated] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        let selected = try XCTUnwrap(target(paths: [first, second]).selecting(paths: [first, unrelated]))
        XCTAssertEqual(selected.paths, [first])
        XCTAssertEqual(selected.authorizedProjectPaths, [first])
        XCTAssertEqual(Cleaner.clean(selected), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertNil(target(paths: [second]).selecting(paths: []))
    }

    func testCommandsCannotBePartiallySelectedOrRepeatedPerPath() {
        let paths = [URL(fileURLWithPath: "/p/one"), URL(fileURLWithPath: "/p/two")]
        let command = target(paths: paths, method: .commands([["tool", "clean"]], thenDelete: true))
        XCTAssertNil(command.selecting(paths: [paths[0]]))
        XCTAssertEqual(command.cleanupUnits.count, 1)
        XCTAssertEqual(command.cleanupUnits[0].paths, paths)
        XCTAssertEqual(target(paths: paths + [paths[0]]).cleanupUnits.count, 2)
    }
}

final class ProjectCleanupGuardTests: XCTestCase {
    private var root: URL!
    private var artifact: URL!

    override func setUpWithError() throws {
        root = try TestSupport.temporaryDirectory().resolvingSymlinksInPath()
        artifact = root.appendingPathComponent("build")
        try FileManager.default.createDirectory(at: artifact, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    func testOpenArtifactAndProjectWorkingDirectoryAreProtected() {
        for path in [artifact.path, artifact.appendingPathComponent("output.o").path, root.path] {
            XCTAssertEqual(ProjectCleanupGuard.check(artifact, projectRoot: root) { _, _ in
                ShellResult(status: 0, stdout: "p42\nn\(path)\n", stderr: "")
            }, .inUse)
        }
    }

    func testUnrelatedSiblingIsNotMistakenForAnOpenArtifact() {
        XCTAssertEqual(ProjectCleanupGuard.check(artifact, projectRoot: root) { _, _ in
            ShellResult(status: 0, stdout: "p42\nn\(self.artifact.path)-other/file\n", stderr: "")
        }, .allowed)
    }

    func testFailedOrEmptyProcessProbePreservesArtifact() {
        for result in [ShellResult(status: 1, stdout: "", stderr: "denied"), ShellResult(status: 0, stdout: "", stderr: "")] {
            XCTAssertEqual(ProjectCleanupGuard.check(artifact, projectRoot: root) { _, _ in result }, .unverified)
        }
    }

    func testTrackedFilesAndFailedGitProbePreserveArtifact() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        for result in [ShellResult(status: 0, stdout: "build/source.swift\0", stderr: ""),
                       ShellResult(status: 1, stdout: "", stderr: "failed")] {
            XCTAssertEqual(ProjectCleanupGuard.check(artifact, projectRoot: root) { executable, args in
                XCTAssertEqual(executable, "/usr/bin/git")
                XCTAssertTrue(args.contains("--literal-pathspecs"))
                return result
            }, result.status == 0 ? .tracked : .unverified)
        }
    }

    func testUntrackedArtifactUsesFreshProcessProbeAfterGit() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        var executables: [String] = []
        XCTAssertEqual(ProjectCleanupGuard.check(artifact, projectRoot: root) { executable, _ in
            executables.append(executable)
            return ShellResult(status: 0, stdout: executable == "/usr/bin/git" ? "" : "p42\nn/opt/unrelated\n", stderr: "")
        }, .allowed)
        XCTAssertEqual(executables, ["/usr/bin/git", "/usr/sbin/lsof"])
    }

    func testOutsideProjectAndProjectRootAreRefused() {
        for path in [root!, root.deletingLastPathComponent().appendingPathComponent("other")] {
            XCTAssertEqual(ProjectCleanupGuard.check(path, projectRoot: root) { _, _ in
                XCTFail("Invalid paths must not reach probes")
                return ShellResult(status: 0, stdout: "", stderr: "")
            }, .unverified)
        }
    }

    func testCleanerPreservesTrackedFilesAndLogsTheRefusal() throws {
        TestSupport.useEnglish()
        let authored = artifact.appendingPathComponent("authored.txt")
        try "source".write(to: authored, atomically: true, encoding: .utf8)
        XCTAssertEqual(Shell.run("/usr/bin/git", ["-C", root.path, "init", "-q"]).status, 0)
        XCTAssertEqual(Shell.run("/usr/bin/git", ["-C", root.path, "add", "--", "build/authored.txt"]).status, 0)
        let target = StorageTarget(id: "tracked-test", stack: StackInfo(id: "test", name: "Test", icon: "gear", order: 0),
                                   title: "Builds", detail: "", risk: .redownload, paths: [artifact],
                                   authorizedProjectPaths: [artifact], projectRootsByPath: [artifact.path: root])
        let errors = Cleaner.clean(target)
        XCTAssertEqual(errors.count, 1)
        XCTAssertTrue(errors[0].contains("tracked by Git"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: authored.path))
        XCTAssertEqual(CleanupLog.read().last?.errors, errors)
    }
}
