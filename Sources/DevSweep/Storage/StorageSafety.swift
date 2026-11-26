import Darwin
import Foundation

struct ApplicationUsageSnapshot: Sendable {
    /// Nil means that the process inventory or an app's identity could not be verified.
    let runningBundleIDs: Set<String>?
    let handles: ShellResult
    var toolExecutables: Set<String>? = nil

    static func capture(includeApplications: Bool, includeTools: Bool = false) -> ApplicationUsageSnapshot {
        let running: Set<String>?
        var tools: Set<String>?
        if includeApplications || includeTools {
            let result = Shell.run("/bin/ps", ["-axww", "-o", "pid=,ppid=,uid=,rss=,%cpu=,etime=,command="], timeout: 15)
            running = includeApplications ? bundleIDs(from: result) : nil
            let parsed = ProcessScanner.parse(result.stdout)
            if result.status == 0 && !parsed.isEmpty && parsed.count == result.stdout.split(separator: "\n").count {
                // Tool idleness includes visible system updaters; app bundle ownership remains user-scoped.
                tools = Set(parsed.map { $0.exeName.lowercased() })
            }
        } else {
            running = nil
        }
        let handles = Shell.run("/usr/sbin/lsof", ["-nP", "-a", "-u", String(getuid()), "-Fpn"], timeout: 15)
        return ApplicationUsageSnapshot(runningBundleIDs: running, handles: handles, toolExecutables: tools)
    }

    static func bundleIDs(
        from result: ShellResult,
        resolveExecutable: (Int32, String) -> String = ProcessScanner.resolveExecutable,
        identifyBundle: (String) -> String? = { Bundle(path: $0)?.bundleIdentifier },
        uid: UInt32 = getuid()
    ) -> Set<String>? {
        guard result.status == 0 else { return nil }
        let processes = ProcessScanner.parse(result.stdout, exeResolver: resolveExecutable)
        guard !processes.isEmpty, processes.count == result.stdout.split(separator: "\n").count else { return nil }
        var ids = Set<String>()
        var visited = Set<String>()
        for process in processes where process.uid == uid {
            guard let end = process.exePath.range(of: ".app/", options: .caseInsensitive) else { continue }
            // The outer app identifies helpers too, including renamed apps and copies outside /Applications.
            let bundle = String(process.exePath[..<process.exePath.index(before: end.upperBound)])
            guard visited.insert(bundle).inserted else { continue }
            guard let id = identifyBundle(bundle) else { return nil }
            ids.insert(id)
        }
        return ids
    }
}

/// Inspects Chromium/Electron `SingletonLock` symlinks (`<host>-<pid>`) without following them.
enum SingletonLockGuard {
    enum State: Equatable, Sendable {
        case none
        case live(pid: Int32)
        case stale
        case unreadable
    }

    static func defaultProcessAlive(_ pid: Int32) -> Bool {
        pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
    }

    static func inspect(
        _ lockURL: URL,
        isProcessAlive: (Int32) -> Bool = defaultProcessAlive
    ) -> State {
        var st = stat()
        if lstat(lockURL.path, &st) != 0 {
            return (errno == ENOENT || errno == ENOTDIR) ? .none : .unreadable
        }
        guard (st.st_mode & S_IFMT) == S_IFLNK else { return .unreadable }
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let length = readlink(lockURL.path, &buffer, buffer.count - 1)
        guard length > 0 else { return .unreadable }
        buffer[length] = 0
        let target = String(cString: buffer)
        guard let separator = target.lastIndex(of: "-"),
              let pid = Int32(target[target.index(after: separator)...]),
              pid > 0 else { return .unreadable }
        return isProcessAlive(pid) ? .live(pid: pid) : .stale
    }

    /// Checks up to 3 ancestor directories (and the mirrored `Application Support` tree for `Library/Caches` paths).
    static func isPathHeld(
        _ path: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        isProcessAlive: (Int32) -> Bool = defaultProcessAlive
    ) -> Bool {
        let normalizedHome = home.resolvingSymlinksInPath().standardizedFileURL.path
        let literal = path.standardizedFileURL.path
        let stops: Set<String> = [
            "/",
            normalizedHome,
            normalizedHome + "/Library",
            normalizedHome + "/Library/Caches",
            normalizedHome + "/Library/Application Support",
        ]
        if hasActiveLockInAncestors(startingAt: path.deletingLastPathComponent(), stops: stops, maxLevels: 3, isProcessAlive: isProcessAlive) {
            return true
        }
        let cachesPrefix = normalizedHome + "/Library/Caches/"
        if literal.hasPrefix(cachesPrefix) {
            let relative = String(literal.dropFirst(cachesPrefix.count))
            let mirror = URL(fileURLWithPath: normalizedHome + "/Library/Application Support/" + relative)
            if hasActiveLockInAncestors(startingAt: mirror, stops: stops, maxLevels: 3, isProcessAlive: isProcessAlive) {
                return true
            }
        }
        return false
    }

    private static func hasActiveLockInAncestors(
        startingAt directory: URL,
        stops: Set<String>,
        maxLevels: Int,
        isProcessAlive: (Int32) -> Bool
    ) -> Bool {
        var current = directory.standardizedFileURL
        for _ in 0..<maxLevels {
            let currentPath = current.path
            if stops.contains(currentPath) || currentPath.isEmpty { break }
            var st = stat()
            if lstat(currentPath, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR {
                switch inspect(current.appendingPathComponent("SingletonLock"), isProcessAlive: isProcessAlive) {
                case .live, .unreadable: return true
                case .none, .stale: break
                }
            }
            let parent = current.deletingLastPathComponent().standardizedFileURL
            if parent.path == currentPath { break }
            current = parent
        }
        return false
    }
}

/// Shared safeguards for declarative app caches and age-limited files.
enum StorageSafety {
    static func check(
        _ path: URL, target: StorageTarget, usage: ApplicationUsageSnapshot? = nil, now: Date = Date(),
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        isProcessAlive: (Int32) -> Bool = SingletonLockGuard.defaultProcessAlive
    ) -> CleanupGuardVerdict {
        if let service = target.serviceRemovalContext, !service.validates() { return .unverified }
        if let days = target.recursiveAgeDays {
            let walk = DirectoryWalker.walk(path, depth: 4, control: ScanControl(), reportDepthLimit: true)
            guard walk.complete else { return .unverified }
            let cutoff = now.addingTimeInterval(-Double(days) * 86400)
            if (walk.files + walk.directories).contains(where: { (PathGlob.modificationDate($0) ?? now) >= cutoff }) { return .recent }
        }
        if let context = target.orphanRemovalContext, !context.validates() { return .unverified }
        if let context = target.appRemovalContext, !context.validates() { return .unverified }
        if let authorization = target.pathAuthorizations[path.path], !authorization.validates(path) { return .unverified }
        if !target.requiresToolsIdle.isEmpty {
            if target.pathAuthorizations[path.path] == nil && !SafeDelete.isAllowed(path) { return .unverified }
            guard let tools = usage?.toolExecutables else { return .unverified }
            if tools.contains(where: { tool in target.requiresToolsIdle.contains { tool.hasPrefix($0.lowercased()) } }) { return .inUse }
        }
        if !target.requiresToolsIdle.isEmpty || !target.requiresAppsClosed.isEmpty || target.pathRules[path.path] != nil || !target.pathAuthorizations.isEmpty {
            let literal = path.standardizedFileURL.path
            guard path.resolvingSymlinksInPath().standardizedFileURL.path == literal,
                  let attributes = try? FileManager.default.attributesOfItem(atPath: path.path) else { return .unverified }
            if let rule = target.pathRules[path.path] {
                if rule.filesOnly == true && attributes[.type] as? FileAttributeType != .typeRegular { return .unverified }
                if let days = rule.olderThanDays {
                    guard let modified = attributes[.modificationDate] as? Date else { return .unverified }
                    guard modified < now.addingTimeInterval(-Double(days) * 86_400) else { return .recent }
                }
            }
            guard let usage else { return .unverified }
            if !target.requiresAppsClosed.isEmpty {
                guard let running = usage.runningBundleIDs else { return .unverified }
                if !Set(running.map { $0.lowercased() }).isDisjoint(with: target.requiresAppsClosed.map { $0.lowercased() }) { return .inUse }
            }
            if SingletonLockGuard.isPathHeld(path, home: home, isProcessAlive: isProcessAlive) { return .inUse }
            guard usage.handles.status == 0,
                  usage.handles.stdout.split(separator: "\n").contains(where: { $0.hasPrefix("p") }) else { return .unverified }
            for line in usage.handles.stdout.split(separator: "\n") where line.hasPrefix("n") {
                let openPath = String(line.dropFirst())
                if openPath == literal || openPath.hasPrefix(literal + "/") { return .inUse }
            }
        }
        if target.protectNestedRepositories {
            let nested = Shell.run("/usr/bin/find", [path.path, "-name", ".git", "-print", "-quit"], timeout: 10)
            guard nested.status == 0 else { return .unverified }
            if !nested.stdout.isEmpty { return .tracked }
        }
        if let project = target.projectRootsByPath[path.path] {
            return ProjectCleanupGuard.check(path, projectRoot: project, handles: usage?.handles)
        }
        return .allowed
    }
}
