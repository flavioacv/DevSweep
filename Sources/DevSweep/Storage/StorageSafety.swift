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
                tools = Set(parsed.filter { $0.uid == getuid() }.map { $0.exeName.lowercased() })
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

/// Shared safeguards for declarative app caches and age-limited files.
enum StorageSafety {
    static func check(
        _ path: URL, target: StorageTarget, usage: ApplicationUsageSnapshot? = nil, now: Date = Date()
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
