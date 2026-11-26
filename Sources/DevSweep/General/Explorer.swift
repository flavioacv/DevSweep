import Foundation

enum ExplorerMode: String, CaseIterable, Identifiable {
    case folders, largeFiles
    var id: String { rawValue }
    var title: String { self == .folders ? tr("explorer.folders") : tr("explorer.large_files") }
}

enum ExplorerSort: String, CaseIterable, Identifiable {
    case size, newest, oldest, name
    var id: String { rawValue }
    var title: String {
        switch self {
        case .size: tr("explorer.sort_size")
        case .newest: tr("explorer.sort_newest")
        case .oldest: tr("explorer.sort_oldest")
        case .name: tr("explorer.sort_name")
        }
    }
}

struct ExplorerFilter: Equatable, Sendable {
    var minimumBytes: Int64 = 0
    var olderThanDays = 0
    var extensions = ""

    func accepts(_ entry: GeneralEntry, measurement: SizeMeasurement?, now: Date = Date()) -> Bool {
        if minimumBytes > 0, measurement?.state != .complete || (measurement?.bytes ?? 0) < minimumBytes { return false }
        if olderThanDays > 0 {
            guard let date = entry.modified, date < now.addingTimeInterval(-Double(olderThanDays) * 86_400) else { return false }
        }
        let types = Set(extensions.lowercased().split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }.filter { !$0.isEmpty })
        return types.isEmpty || types.contains(entry.url.pathExtension.lowercased())
    }
}

enum ExplorerScanner {
    /// Local allocated bytes, not logical file length; sparse files do not inflate this search.
    static func scan(root: URL, home: URL, minimumBytes: Int64, control: ScanControl,
                     limit: Int = 100_000, seconds: TimeInterval = 30, depth: Int = 32) -> GeneralReport {
        guard hasLocalMount(root, volumes: SystemMonitor.volumes()) else {
            return GeneralReport(issues: [tr("general.root_unavailable")], complete: false)
        }
        let walk = DirectoryWalker.walk(root, depth: depth, control: control, limit: limit, seconds: seconds,
                                        skip: [".git"], reportDepthLimit: true)
        var report = GeneralReport(issues: walk.issues, complete: walk.complete, inspected: walk.visited)
        for file in walk.files {
            if control.isCancelled { report.complete = false; report.issues.append(tr("general.cancelled")); break }
            do {
                let values = try file.resourceValues(forKeys: [.fileAllocatedSizeKey])
                guard let bytes = values.fileAllocatedSize else { throw CocoaError(.fileReadUnknown) }
                if Int64(bytes) >= minimumBytes {
                    report.entries.append(GeneralScanner.entry(file, root: root, area: .explorer, home: home))
                }
            } catch { report.complete = false; report.issues.append("\(file.path): \(error.localizedDescription)") }
        }
        return report
    }

    static func volume(containing root: URL, volumes: [VolumeSnapshot]) -> VolumeSnapshot? {
        volumes.filter { $0.path == "/" || root.path == $0.path || root.path.hasPrefix($0.path + "/") }
            .max { $0.path.count < $1.path.count }
    }

    static func hasLocalMount(_ root: URL, volumes: [VolumeSnapshot]) -> Bool {
        guard root.path.hasPrefix("/Volumes/") else { return true }
        return volumes.contains { $0.path.hasPrefix("/Volumes/") && (root.path == $0.path || root.path.hasPrefix($0.path + "/")) }
    }
}
