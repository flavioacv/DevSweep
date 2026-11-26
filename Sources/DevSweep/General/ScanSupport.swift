import Foundation

final class ScanControl: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    func cancel() { lock.lock(); stopped = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
}

struct FileIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64

    static func read(_ url: URL) -> FileIdentity? {
        guard url.resolvingSymlinksInPath().standardizedFileURL.path == url.standardizedFileURL.path,
              let info = try? FileManager.default.attributesOfItem(atPath: url.path),
              info[.type] as? FileAttributeType != .typeSymbolicLink,
              let device = info[.systemNumber] as? NSNumber,
              let inode = info[.systemFileNumber] as? NSNumber else { return nil }
        return FileIdentity(device: device.uint64Value, inode: inode.uint64Value)
    }
}

/// Exact authorization issued by a completed general scan, never by a YAML path or filename alone.
struct PathAuthorization: Sendable {
    let path: URL
    let root: URL
    let parent: URL
    let pathIdentity: FileIdentity
    let rootIdentity: FileIdentity
    let parentIdentity: FileIdentity
    let fileSize: UInt64?
    let fileModified: Date?

    static func issue(_ path: URL, within root: URL) -> PathAuthorization? {
        let path = path.standardizedFileURL
        let root = root.standardizedFileURL
        guard root.path != "/", path.path.hasPrefix(root.path + "/"),
              let pathID = FileIdentity.read(path), let rootID = FileIdentity.read(root),
              let parentID = FileIdentity.read(path.deletingLastPathComponent()) else { return nil }
        let attributes = try? FileManager.default.attributesOfItem(atPath: path.path)
        let regular = attributes?[.type] as? FileAttributeType == .typeRegular
        return PathAuthorization(path: path, root: root, parent: path.deletingLastPathComponent(),
                                 pathIdentity: pathID, rootIdentity: rootID, parentIdentity: parentID,
                                 fileSize: regular ? (attributes?[.size] as? NSNumber)?.uint64Value : nil,
                                 fileModified: regular ? attributes?[.modificationDate] as? Date : nil)
    }

    func validates(_ candidate: URL) -> Bool {
        guard candidate.standardizedFileURL.path == path.path, path.path.hasPrefix(root.path + "/"),
              FileIdentity.read(path) == pathIdentity, FileIdentity.read(root) == rootIdentity,
              FileIdentity.read(parent) == parentIdentity else { return false }
        if let fileSize, let fileModified {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path.path) else { return false }
            return (attributes[.size] as? NSNumber)?.uint64Value == fileSize && attributes[.modificationDate] as? Date == fileModified
        }
        return true
    }
}

struct WalkReport: Sendable {
    var files: [URL] = []
    var directories: [URL] = []
    var issues: [String] = []
    var visited = 0
    var complete = true
}

/// Bounded metadata-only walk. Never follows aliases, other mounts or online-only cloud files.
enum DirectoryWalker {
    static func walk(_ root: URL, depth: Int, control: ScanControl, limit: Int = 50_000,
                     seconds: TimeInterval = 15, skip: Set<String> = [], pruneNames: Set<String> = [],
                     reportDepthLimit: Bool = false) -> WalkReport {
        var report = WalkReport()
        guard let identity = FileIdentity.read(root) else {
            report.complete = false; report.issues = [root.path]; return report
        }
        let deadline = Date().addingTimeInterval(seconds)
        var pending: [(URL, Int)] = [(root, 0)]
        while let (directory, level) = pending.popLast() {
            if control.isCancelled || report.visited >= limit || Date() > deadline {
                report.complete = false; report.issues.append(tr("general.scan_limited")); break
            }
            do {
                for discovered in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]) {
                    let url = discovered.standardizedFileURL
                    report.visited += 1
                    if report.visited > limit || control.isCancelled || Date() > deadline {
                        report.complete = false; report.issues.append(tr("general.scan_limited")); break
                    }
                    guard !skip.contains(url.lastPathComponent) else { continue }
                    let metadata = try FileManager.default.attributesOfItem(atPath: url.path)
                    if metadata[.type] as? FileAttributeType == .typeSymbolicLink { continue }
                    guard let id = FileIdentity.read(url) else { report.complete = false; report.issues.append(url.path); continue }
                    guard id.device == identity.device else { continue }
                    let cloud = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
                    if cloud?.isUbiquitousItem == true && cloud?.ubiquitousItemDownloadingStatus != .current { continue }
                    let info = try FileManager.default.attributesOfItem(atPath: url.path)
                    if info[.type] as? FileAttributeType == .typeDirectory {
                        let normalized = url.resolvingSymlinksInPath().standardizedFileURL
                        report.directories.append(normalized)
                        if level < depth && url.pathExtension.lowercased() != "app" && !pruneNames.contains(url.lastPathComponent) { pending.append((normalized, level + 1)) }
                        else if reportDepthLimit && level >= depth && url.pathExtension.lowercased() != "app" && !pruneNames.contains(url.lastPathComponent) {
                            report.complete = false; report.issues.append(tr("explorer.depth_limit", ["path": normalized.path]))
                        }
                    } else if info[.type] as? FileAttributeType == .typeRegular {
                        report.files.append(url.resolvingSymlinksInPath().standardizedFileURL)
                    }
                }
            } catch {
                report.complete = false; report.issues.append("\(directory.path): \(error.localizedDescription)")
            }
        }
        if FileIdentity.read(root) != identity { report.complete = false; report.issues.append(root.path) }
        return report
    }
}
