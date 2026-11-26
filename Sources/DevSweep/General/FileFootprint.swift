import Darwin
import Foundation

struct FileFootprint: Sendable, Equatable {
    let device: UInt64
    let inode: UInt64
    let logicalBytes: Int64
    let allocatedBytes: Int64
    let links: UInt64

    static func read(_ url: URL) -> FileFootprint? {
        guard FileIdentity.read(url) != nil else { return nil }
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_flags & UInt32(SF_DATALESS) == 0, info.st_size >= 0, info.st_blocks >= 0,
              info.st_blocks <= Int64.max / 512 else { return nil }
        return FileFootprint(device: UInt64(UInt32(bitPattern: info.st_dev)), inode: info.st_ino,
                             logicalBytes: info.st_size, allocatedBytes: info.st_blocks * 512, links: UInt64(info.st_nlink))
    }

    static func isDataless(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_flags & UInt32(SF_DATALESS) != 0
    }
}

struct FileSpaceEstimate: Sendable {
    var allocatedBytes: Int64 = 0
    var potentialAfterTrashBytes: Int64 = 0
    var files = 0
    var uniqueFiles = 0
    var linksOutsideSelection = 0
    var complete = true

    /// A bound for selected regular files, never a claim of immediately freed or exclusive APFS blocks.
    static func calculate(paths: [URL]) -> FileSpaceEstimate {
        var estimate = FileSpaceEstimate()
        var groups: [String: (FileFootprint, Int)] = [:]
        for path in Set(paths.map { $0.standardizedFileURL.path }).sorted() {
            guard let footprint = FileFootprint.read(URL(fileURLWithPath: path)) else { estimate.complete = false; continue }
            estimate.files += 1
            let key = "\(footprint.device):\(footprint.inode)"
            if let previous = groups[key] {
                if previous.0 != footprint { estimate.complete = false }
                groups[key] = (footprint, previous.1 + 1)
            } else { groups[key] = (footprint, 1) }
        }
        estimate.uniqueFiles = groups.count
        for (file, selectedLinks) in groups.values {
            let sum = estimate.allocatedBytes.addingReportingOverflow(file.allocatedBytes)
            if sum.overflow { estimate.complete = false } else { estimate.allocatedBytes = sum.partialValue }
            if UInt64(selectedLinks) == file.links {
                let possible = estimate.potentialAfterTrashBytes.addingReportingOverflow(file.allocatedBytes)
                if possible.overflow { estimate.complete = false } else { estimate.potentialAfterTrashBytes = possible.partialValue }
            } else { estimate.linksOutsideSelection += 1 }
        }
        return estimate
    }
}
