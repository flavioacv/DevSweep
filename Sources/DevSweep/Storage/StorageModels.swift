import Foundation

enum Risk: String, Comparable, Sendable {
    /// Regenerated automatically, nothing to download.
    case safe
    /// Comes back on the next build/install, but has to be downloaded again.
    case redownload
    /// Removes state the user might want (simulator data, archives, open apps).
    case dataLoss = "data_loss"

    private var rank: Int {
        switch self {
        case .safe: 0
        case .redownload: 1
        case .dataLoss: 2
        }
    }

    static func < (lhs: Risk, rhs: Risk) -> Bool { lhs.rank < rhs.rank }

    var label: String {
        switch self {
        case .safe: tr("risk.safe")
        case .redownload: tr("risk.redownload")
        case .dataLoss: tr("risk.data_loss")
        }
    }
}

enum CleanMethod: Sendable {
    case delete
    case trash
    /// Runs each command (first element is the tool) and optionally deletes the paths afterwards.
    case commands([[String]], thenDelete: Bool)

    /// Commands may operate on an entire cache, so they cannot be split into per-path actions.
    var supportsPathSelection: Bool {
        if case .commands = self { return false }
        return true
    }

    /// Short, stable label for the cleanup log.
    var logDescription: String {
        switch self {
        case .delete: "delete"
        case .trash: "trash"
        case .commands(let commands, let thenDelete):
            (commands.map { $0.joined(separator: " ") } + (thenDelete ? ["delete"] : [])).joined(separator: "; ")
        }
    }
}

struct StorageTarget: Identifiable, Sendable {
    let id: String
    let stack: StackInfo
    let title: String
    let detail: String
    let risk: Risk
    let paths: [URL]
    var method: CleanMethod = .delete
    /// Substrings of process command lines to terminate before cleaning (e.g. Gradle daemons).
    var stopProcesses: [String] = []
    var autoRecommend: Bool = true
    /// Per-target suggestion threshold; falls back to the global preference.
    var recommendMinBytes: Int64? = nil
    /// Exact generated artifacts authorized by confirmed project discovery, including external disks.
    var authorizedProjectPaths: [URL] = []
    /// Project ownership for the review UI; unrelated global paths have no entry.
    var projectRootsByPath: [String: URL] = [:]
    /// Bundle identifiers whose main app and helpers must be absent before cleaning.
    var requiresAppsClosed: [String] = []
    var requiresToolsIdle: [String] = []
    /// Scan-time filters that must still hold immediately before execution.
    var pathRules: [String: PathSpec] = [:]

    var pathAuthorizations: [String: PathAuthorization] = [:]
    var protectNestedRepositories = false
    var appRemovalContext: AppRemovalContext? = nil
    var orphanRemovalContext: OrphanRemovalContext? = nil
    var recursiveAgeDays: Int? = nil
    var serviceRemovalContext: ServiceRemovalContext? = nil

    var needsUsageCheck: Bool { !requiresToolsIdle.isEmpty || !pathAuthorizations.isEmpty || !requiresAppsClosed.isEmpty || !pathRules.isEmpty || !projectRootsByPath.isEmpty }

    func selecting(paths selected: Set<URL>) -> StorageTarget? {
        guard method.supportsPathSelection else { return nil }
        let paths = paths.filter { selected.contains($0) }
        guard !paths.isEmpty else { return nil }
        return replacingPaths(paths)
    }

    func replacingPaths(_ paths: [URL]) -> StorageTarget {
        StorageTarget(id: id, stack: stack, title: title, detail: detail, risk: risk, paths: paths,
                      method: method, stopProcesses: stopProcesses, autoRecommend: autoRecommend,
                      recommendMinBytes: recommendMinBytes,
                      authorizedProjectPaths: authorizedProjectPaths.filter { paths.contains($0) },
                      projectRootsByPath: projectRootsByPath.filter { pair in paths.contains { $0.path == pair.key } },
                      requiresAppsClosed: requiresAppsClosed,
                      requiresToolsIdle: requiresToolsIdle,
                      pathRules: pathRules.filter { pair in paths.contains { $0.path == pair.key } },
                      pathAuthorizations: pathAuthorizations.filter { pair in paths.contains { $0.path == pair.key } },
                      protectNestedRepositories: protectNestedRepositories, appRemovalContext: appRemovalContext, orphanRemovalContext: orphanRemovalContext, recursiveAgeDays: recursiveAgeDays, serviceRemovalContext: serviceRemovalContext)
    }

    var cleanupUnits: [StorageTarget] {
        guard method.supportsPathSelection else { return [self] }
        return Array(Set(paths)).sorted { $0.path < $1.path }.map { replacingPaths([$0]) }
    }
}

struct CleanupProgress: Sendable {
    var completed: Int
    var total: Int
    var currentPath: String
    var isRefreshing = false
}

struct CleanupSummary: Sendable {
    var completed: Int
    var total: Int
    var freed: Int64
    var errors: [String]
    var cancelled: Bool
}

/// Shared by review and execution; an uncertain check never authorizes removal.
enum CleanupGuardVerdict: Equatable, Sendable {
    case allowed, inUse, tracked, recent, unverified
}
