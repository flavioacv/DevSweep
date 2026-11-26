import Darwin
import XCTest
@testable import DevSweep

final class StoragePrecisionTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        TestSupport.useEnglish()
        root = try TestSupport.temporaryDirectory().resolvingSymlinksInPath().standardizedFileURL
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }
    @discardableResult private func file(_ name: String, days: Int = 40) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 42, count: 8192).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-Double(days) * 86400)], ofItemAtPath: url.path)
        return url
    }

    func testHardlinksCountOnceAndCannotReclaimWhileOtherLinksRemain() throws {
        let first = try file("first.bin"), second = root.appendingPathComponent("second.bin")
        try FileManager.default.linkItem(at: first, to: second)
        let footprint = try XCTUnwrap(FileFootprint.read(first))
        XCTAssertEqual(footprint.links, 2)
        let one = FileSpaceEstimate.calculate(paths: [first, first])
        XCTAssertTrue(one.complete); XCTAssertEqual(one.files, 1)
        XCTAssertEqual(one.allocatedBytes, footprint.allocatedBytes)
        XCTAssertEqual(one.potentialAfterTrashBytes, 0); XCTAssertEqual(one.linksOutsideSelection, 1)
        let both = FileSpaceEstimate.calculate(paths: [first, second])
        XCTAssertTrue(both.complete); XCTAssertEqual(both.files, 2); XCTAssertEqual(both.uniqueFiles, 1)
        XCTAssertEqual(both.allocatedBytes, footprint.allocatedBytes)
        XCTAssertEqual(both.potentialAfterTrashBytes, footprint.allocatedBytes)
    }

    func testAPFSClonesAreDeduplicatedUntilCopyOnWriteDiverges() throws {
        let original = root.appendingPathComponent("original.bin")
        let cloned = root.appendingPathComponent("cloned.bin")
        try Data(repeating: 0x5A, count: 65_536).write(to: original)
        XCTAssertNil(FileFootprint.readCloneIdentity(root.appendingPathComponent("missing.bin").path))

        let rc = clonefile(original.path, cloned.path, 0)
        if rc != 0 && (errno == ENOTSUP || errno == EXDEV) {
            throw XCTSkip("Temporary directory filesystem does not support APFS clones")
        }
        XCTAssertEqual(rc, 0)

        let origFP = try XCTUnwrap(FileFootprint.read(original))
        let cloneFP = try XCTUnwrap(FileFootprint.read(cloned))
        XCTAssertNotEqual(origFP.inode, cloneFP.inode)
        XCTAssertNotNil(origFP.cloneID)
        XCTAssertEqual(origFP.cloneID, cloneFP.cloneID)
        XCTAssertTrue(origFP.sharesAllBlocks)
        XCTAssertTrue(cloneFP.sharesAllBlocks)

        let combined = FileSpaceEstimate.calculate(paths: [original, cloned])
        XCTAssertTrue(combined.complete)
        XCTAssertEqual(combined.files, 2)
        XCTAssertEqual(combined.uniqueFiles, 2)
        XCTAssertEqual(combined.deduplicatedClones, 1)
        XCTAssertTrue(combined.apfsClonesDeduplicated)
        XCTAssertEqual(combined.allocatedBytes, origFP.allocatedBytes)
        XCTAssertEqual(combined.potentialAfterTrashBytes, origFP.allocatedBytes)

        // Modifying the clone breaks shared blocks (copy-on-write), so both count separately.
        try Data(repeating: 0xA5, count: 65_536).write(to: cloned)
        let divergedFP = try XCTUnwrap(FileFootprint.read(cloned))
        XCTAssertFalse(divergedFP.sharesAllBlocks)
        let afterWrite = FileSpaceEstimate.calculate(paths: [original, cloned])
        XCTAssertEqual(afterWrite.deduplicatedClones, 0)
        XCTAssertEqual(afterWrite.allocatedBytes, origFP.allocatedBytes + divergedFP.allocatedBytes)
    }

    func testSparseFilesUseAllocatedBlocksAndLinksAndDirectoriesAreUnavailable() throws {
        let sparse = try file("sparse.bin")
        let handle = try FileHandle(forWritingTo: sparse)
        try handle.truncate(atOffset: 1_073_741_824); try handle.close()
        let footprint = try XCTUnwrap(FileFootprint.read(sparse))
        XCTAssertEqual(footprint.logicalBytes, 1_073_741_824)
        XCTAssertLessThan(footprint.allocatedBytes, footprint.logicalBytes)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: sparse)
        XCTAssertNil(FileFootprint.read(link)); XCTAssertNil(FileFootprint.read(root))
        XCTAssertFalse(FileSpaceEstimate.calculate(paths: [root, link]).complete)
        XCTAssertFalse(FileFootprint.isDataless(sparse))
    }

    func testInstallerOriginsKeepMailAndCloudReadOnlyIncludingCustomRoots() throws {
        let download = try file("Downloads/install.dmg")
        let telegram = try file("Downloads/Telegram Desktop/install.pkg")
        let mail = try file("Library/Containers/com.apple.mail/Data/Library/Mail Downloads/item/install.dmg")
        let cloud = try file("Library/Mobile Documents/com~apple~CloudDocs/Downloads/install.dmg")
        let report = InstallerDiscovery.scan(home: root, selectedRoot: nil, control: ScanControl())
        XCTAssertTrue(report.complete)
        XCTAssertEqual(Set(report.entries.map(\.url)), [download, telegram, mail, cloud])
        XCTAssertEqual(report.entries.first { $0.url == telegram }?.installerSource, .telegram)
        XCTAssertTrue(try XCTUnwrap(report.entries.first { $0.url == download }).removable)
        for path in [mail, cloud] { XCTAssertFalse(try XCTUnwrap(report.entries.first { $0.url == path }).removable) }
        let custom = InstallerDiscovery.scan(home: root, selectedRoot: mail.deletingLastPathComponent(), control: ScanControl())
        XCTAssertFalse(try XCTUnwrap(custom.entries.first).removable)
        XCTAssertTrue(InstallerDiscovery.managed(root.appendingPathComponent("library/mail/attachment.dmg"), home: root))
        XCTAssertFalse(InstallerDiscovery.managed(download, home: root))
    }

    func testFirmwareRecognitionAndAgeFilterDoNotSelectArbitraryIPSW() throws {
        let manifest = try file("source/BuildManifest.plist"), restore = try file("source/Restore.plist")
        let folder = root.appendingPathComponent("Library/iTunes/iPhone Software Updates")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let old = folder.appendingPathComponent("old.ipsw"), recent = folder.appendingPathComponent("recent.ipsw")
        for output in [old, recent] {
            XCTAssertEqual(Shell.run("/usr/bin/zip", ["-q", "-j", output.path, manifest.path, restore.path]).status, 0)
        }
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-40 * 86400)], ofItemAtPath: old.path)
        try file("Library/iTunes/iPhone Software Updates/not-firmware.ipsw")
        XCTAssertTrue(InstallerArchive.containsFirmware(old))
        let report = InstallerDiscovery.scan(home: root, selectedRoot: nil, control: ScanControl())
        XCTAssertEqual(report.entries.map(\.url), [old])
        let target = try XCTUnwrap(report.entries.first?.target)
        XCTAssertTrue(report.entries[0].removable)
        XCTAssertEqual(target.pathRules[old.path]?.olderThanDays, 30)
        XCTAssertTrue(target.requiresToolsIdle.contains("mobiledeviceupdater"))
        let usage = ApplicationUsageSnapshot(runningBundleIDs: [], handles: ShellResult(status: 0, stdout: "p42\nn/opt/unrelated\n", stderr: ""), toolExecutables: ["mobiledeviceupdater"])
        XCTAssertEqual(StorageSafety.check(old, target: target, usage: usage), .inUse)
    }

    func testFirmwareZIP64AboveFourGBIsRecognizedWithoutReadingPayload() throws {
        let archive = root.appendingPathComponent("large.ipsw")
        FileManager.default.createFile(atPath: archive.path, contents: nil)
        let file = try FileHandle(forWritingTo: archive)
        defer { try? file.close() }
        func integer(_ value: UInt64, bytes: Int) -> Data { Data((0..<bytes).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
        var central = Data()
        for name in ["BuildManifest.plist", "Restore.plist"] {
            var header = Data(repeating: 0, count: 46)
            header.replaceSubrange(0..<4, with: Data([0x50, 0x4b, 0x01, 0x02]))
            header.replaceSubrange(28..<30, with: integer(UInt64(name.utf8.count), bytes: 2))
            central.append(header); central.append(Data(name.utf8))
        }
        let centralOffset = UInt64(UInt32.max) + 1024
        try file.seek(toOffset: centralOffset); try file.write(contentsOf: central)
        let recordOffset = centralOffset + UInt64(central.count)
        var record = Data([0x50, 0x4b, 0x06, 0x06]); record.append(integer(44, bytes: 8))
        record.append(integer(45, bytes: 2)); record.append(integer(45, bytes: 2)); record.append(Data(repeating: 0, count: 8))
        record.append(integer(2, bytes: 8)); record.append(integer(2, bytes: 8))
        record.append(integer(UInt64(central.count), bytes: 8)); record.append(integer(centralOffset, bytes: 8))
        try file.write(contentsOf: record)
        var locator = Data([0x50, 0x4b, 0x06, 0x07]); locator.append(integer(0, bytes: 4)); locator.append(integer(recordOffset, bytes: 8)); locator.append(integer(1, bytes: 4))
        try file.write(contentsOf: locator)
        var end = Data([0x50, 0x4b, 0x05, 0x06]); end.append(integer(0, bytes: 4))
        end.append(integer(0xffff, bytes: 2)); end.append(integer(0xffff, bytes: 2))
        end.append(integer(0xffffffff, bytes: 4)); end.append(integer(0xffffffff, bytes: 4)); end.append(integer(0, bytes: 2))
        try file.write(contentsOf: end); try file.synchronize()
        XCTAssertTrue(InstallerArchive.containsFirmware(archive))
        let footprint = try XCTUnwrap(FileFootprint.read(archive))
        XCTAssertGreaterThan(footprint.logicalBytes, Int64(UInt32.max)); XCTAssertLessThan(footprint.allocatedBytes, 1_048_576)
    }

    @MainActor func testEstimateIsExportedAndInvalidatedBySelectionAndFilters() async throws {
        try file("Downloads/one.dmg")
        let model = GeneralModel(home: root)
        model.area = .installers; await model.scan(force: true); await model.estimateVisibleFiles()
        XCTAssertNotNil(model.fileSpaceEstimate)
        let output = try JSONSerialization.jsonObject(with: model.exportData()) as? [String: Any]
        let exportedEstimate = try XCTUnwrap(output?["file_space_estimate"] as? [String: Any])
        XCTAssertNotNil(exportedEstimate["deduplicated_apfs_clones"])
        XCTAssertNotNil(exportedEstimate["apfs_shared_blocks_deduplicated"])
        XCTAssertNotNil((output?["entries"] as? [[String: Any]])?.first?["source"])
        model.selected = Set(model.report.entries.map(\.id)); XCTAssertNil(model.fileSpaceEstimate)
        await model.estimateVisibleFiles(); model.search = "absent"; XCTAssertNil(model.fileSpaceEstimate)
    }

    func testCancellationAndDeniedSourceArePartial() throws {
        try file("Downloads/tool.dmg")
        let stopped = ScanControl(); stopped.cancel()
        XCTAssertFalse(InstallerDiscovery.scan(home: root, selectedRoot: nil, control: stopped).complete)
        let downloads = root.appendingPathComponent("Downloads")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: downloads.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: downloads.path) }
        XCTAssertFalse(InstallerDiscovery.scan(home: root, selectedRoot: downloads, control: ScanControl()).complete)
    }
}
