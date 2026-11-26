import Darwin
import Foundation

enum GeneralHygiene {
    static func temporaries(root: URL, home: URL, control: ScanControl) -> GeneralReport {
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        guard owned(root), FileIdentity.read(root) != nil else {
            return GeneralReport(issues: [tr("hygiene.temp_unavailable")], complete: false)
        }
        let walk = DirectoryWalker.walk(root, depth: 6, control: control, skip: [".git"], reportDepthLimit: true)
        var report = GeneralReport(issues: walk.issues, complete: walk.complete, inspected: walk.visited)
        for file in walk.files {
            if control.isCancelled { report.complete = false; break }
            guard ["tmp", "temp"].contains(file.pathExtension.lowercased()), old(file), owned(file), eligiblePath(file) else { continue }
            var target = GeneralScanner.entry(file, root: root, area: .temporaries, home: home, age: 7).target
            // Only the actual per-user temporary root is supplied by the production caller.
            // This exact identity grant does not authorize /tmp or the enclosing user directory.
            if let grant = PathAuthorization.issue(file, within: root) { target.pathAuthorizations = [file.path: grant] }
            report.entries.append(GeneralEntry(target: target, modified: PathGlob.modificationDate(file)))
        }
        if control.isCancelled { report.issues.append(tr("general.cancelled")); report.complete = false }
        return report
    }

    static func trash(home: URL, control: ScanControl) -> GeneralReport {
        let root = home.appendingPathComponent(".Trash")
        do { _ = try FileManager.default.attributesOfItem(atPath: root.path) }
        catch let error as NSError {
            if error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { return GeneralReport() }
            return GeneralReport(issues: [error.localizedDescription], complete: false)
        }
        let walk = DirectoryWalker.walk(root, depth: 0, control: control)
        let entries = (walk.files + walk.directories).map { file -> GeneralEntry in
            var target = GeneralScanner.entry(file, root: root, area: .trash, home: home).target
            target.pathAuthorizations = [:]
            return GeneralEntry(target: target, modified: PathGlob.modificationDate(file))
        }
        return GeneralReport(entries: entries, issues: walk.issues, complete: walk.complete, inspected: walk.visited)
    }

    static func external(root: URL?, home: URL, volumes: [VolumeSnapshot], control: ScanControl) -> GeneralReport {
        guard let root,
              let volume = volumes.filter({ $0.path != "/" && $0.path != "/System/Volumes/Data"
                  && (root.path == $0.path || root.path.hasPrefix($0.path + "/")) }).max(by: { $0.path.count < $1.path.count }),
              !volume.readOnly, FileIdentity.read(root) != nil else {
            return GeneralReport(issues: [tr("hygiene.choose_external")], complete: false)
        }
        let walk = DirectoryWalker.walk(root, depth: 12, control: control,
            skip: [".Trashes", ".Trash", ".git", ".Spotlight-V100", ".fseventsd", ".DocumentRevisions-V100", "Backups.backupdb"], reportDepthLimit: true)
        var report = GeneralReport(issues: walk.issues, complete: walk.complete, inspected: walk.visited)
        let tempPrefix = root.appendingPathComponent(".TemporaryItems").path + "/"
        for file in walk.files {
            if control.isCancelled { report.complete = false; break }
            let dsStore = file.lastPathComponent == ".DS_Store" && header(file, equals: [0, 0, 0, 1, 0x42, 0x75, 0x64, 0x31])
            // AppleDouble can carry resource forks and is never a cleanup candidate.
            if file.lastPathComponent.hasPrefix("._") { continue }
            let temporary = file.path.hasPrefix(tempPrefix)
            guard eligiblePath(file), (dsStore || temporary) && old(file) && owned(file) else { continue }
            var target = GeneralScanner.entry(file, root: root, area: .external, home: home, age: 7).target
            target.pathAuthorizations = [:]
            if let grant = PathAuthorization.issue(file, within: root) { target.pathAuthorizations[file.path] = grant }
            report.entries.append(GeneralEntry(target: target, modified: PathGlob.modificationDate(file)))
        }
        if control.isCancelled { report.issues.append(tr("general.cancelled")); report.complete = false }
        return report
    }

    private static func owned(_ path: URL) -> Bool {
        guard let info = try? FileManager.default.attributesOfItem(atPath: path.path),
              let uid = info[.ownerAccountID] as? NSNumber else { return false }
        return uid.uint32Value == getuid()
    }
    private static func eligiblePath(_ path: URL) -> Bool {
        let protected: Set<String> = [".ssh", ".gnupg", ".config", ".git", "Keychains", "Mobile Documents", ".Trash", ".Trashes",
                                      "Backups.backupdb", ".Spotlight-V100", ".fseventsd", ".DocumentRevisions-V100"]
        return protected.isDisjoint(with: path.pathComponents) && !path.pathComponents.contains(where: SafeDelete.protectsShellConfiguration)
    }
    private static func old(_ file: URL) -> Bool {
        guard let date = PathGlob.modificationDate(file) else { return false }
        return date < Date().addingTimeInterval(-7 * 86_400)
    }
    private static func header(_ file: URL, equals bytes: [UInt8]) -> Bool {
        guard FileIdentity.read(file) != nil, let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: bytes.count)) == Data(bytes)
    }
}
