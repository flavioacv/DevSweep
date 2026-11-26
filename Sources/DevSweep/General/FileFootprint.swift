import Darwin
import Foundation

struct FileFootprint: Sendable, Equatable {
    let device: UInt64
    let inode: UInt64
    let logicalBytes: Int64
    let allocatedBytes: Int64
    let links: UInt64
    var cloneID: UInt64? = nil
    var sharesAllBlocks: Bool = false

    private static let attrCmnextCloneID: UInt32 = 0x0000_0100
    private static let attrCmnextExtFlags: UInt32 = 0x0000_0200
    private static let efSharesAllBlocks: UInt64 = 0x0000_0040

    static func read(_ url: URL) -> FileFootprint? {
        guard FileIdentity.read(url) != nil else { return nil }
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_flags & UInt32(SF_DATALESS) == 0, info.st_size >= 0, info.st_blocks >= 0,
              info.st_blocks <= Int64.max / 512 else { return nil }
        let clone = readCloneIdentity(url.path)
        return FileFootprint(device: UInt64(UInt32(bitPattern: info.st_dev)), inode: info.st_ino,
                             logicalBytes: info.st_size, allocatedBytes: info.st_blocks * 512, links: UInt64(info.st_nlink),
                             cloneID: clone?.cloneID, sharesAllBlocks: clone?.sharesAllBlocks ?? false)
    }

    /// Reads APFS clone identity and `EF_SHARES_ALL_BLOCKS` via `getattrlist` without following symlinks.
    static func readCloneIdentity(_ path: String) -> (cloneID: UInt64, sharesAllBlocks: Bool)? {
        var list = attrlist()
        list.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        list.forkattr = attrCmnextCloneID | attrCmnextExtFlags
        var buffer = [UInt8](repeating: 0, count: 20)
        let options = UInt32(FSOPT_NOFOLLOW | FSOPT_ATTR_CMN_EXTENDED)
        let status = path.withCString { cPath in
            buffer.withUnsafeMutableBytes { raw in
                getattrlist(cPath, &list, raw.baseAddress, raw.count, options)
            }
        }
        guard status == 0 else { return nil }
        let length = buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }
        guard length >= 20 else { return nil }
        let cloneID = buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt64.self) }
        let extFlags = buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 12, as: UInt64.self) }
        return (cloneID, (extFlags & efSharesAllBlocks) != 0)
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
    var deduplicatedClones = 0
    var apfsClonesDeduplicated = false
    var complete = true

    /// A bound for selected regular files, deduplicating hardlinks and full APFS clones within the selection.
    static func calculate(paths: [URL]) -> FileSpaceEstimate {
        var estimate = FileSpaceEstimate()
        var groups: [String: (FileFootprint, Int)] = [:]
        var orderedKeys: [String] = []
        for path in Set(paths.map { $0.standardizedFileURL.path }).sorted() {
            guard let footprint = FileFootprint.read(URL(fileURLWithPath: path)) else { estimate.complete = false; continue }
            estimate.files += 1
            let key = "\(footprint.device):\(footprint.inode)"
            if let previous = groups[key] {
                if previous.0 != footprint { estimate.complete = false }
                groups[key] = (footprint, previous.1 + 1)
            } else {
                groups[key] = (footprint, 1)
                orderedKeys.append(key)
            }
        }
        estimate.uniqueFiles = groups.count
        var seenClones = Set<String>()
        for key in orderedKeys {
            guard let (file, selectedLinks) = groups[key] else { continue }
            if let cloneID = file.cloneID {
                estimate.apfsClonesDeduplicated = true
                if file.sharesAllBlocks {
                    let cloneKey = "\(file.device):\(cloneID)"
                    if !seenClones.insert(cloneKey).inserted {
                        estimate.deduplicatedClones += 1
                        continue
                    }
                }
            }
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
