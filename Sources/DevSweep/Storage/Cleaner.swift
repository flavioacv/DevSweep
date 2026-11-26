import Foundation

struct SizeMeasurement: Sendable, Equatable {
    enum State: Sendable { case complete, partial, unavailable }
    var bytes: Int64
    var state: State
    var errors: [String] = []
}

enum SizeCalculator {
    /// Compatibility for callers that only need measured bytes.
    static func size(of paths: [URL]) -> Int64 { measure(paths).bytes }

    /// Allocated size on disk. Incomplete output must never masquerade as an empty folder.
    static func measure(_ paths: [URL], timeout: TimeInterval = 900,
                        shouldCancel: @escaping @Sendable () -> Bool = { false }) -> SizeMeasurement {
        var existing: [String] = []
        var results: [SizeMeasurement] = []
        for path in Set(paths.map(\.path)).sorted() {
            do {
                _ = try FileManager.default.attributesOfItem(atPath: path)
                existing.append(path)
            } catch let error as NSError {
                // Missing artifacts are empty; denied access is an unknown measurement.
                if error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) {
                    continue
                }
                results.append(SizeMeasurement(bytes: 0, state: .unavailable,
                                               errors: ["\(path): \(error.localizedDescription)"]))
            }
        }
        for start in stride(from: 0, to: existing.count, by: 200) {
            if shouldCancel() { results.append(SizeMeasurement(bytes: 0, state: .unavailable, errors: [tr("general.cancelled")])); break }
            let chunk = Array(existing[start..<min(start + 200, existing.count)])
            results.append(parse(Shell.run("/usr/bin/du", ["-sk"] + chunk, timeout: timeout, shouldCancel: shouldCancel), expectedPaths: chunk.count))
        }
        return combine(results)
    }

    static func parse(_ result: ShellResult, expectedPaths: Int) -> SizeMeasurement {
        let values = result.stdout.split(separator: "\n").compactMap { line -> Int64? in
            guard let field = line.split(separator: "\t", maxSplits: 1).first,
                  let kb = Int64(field), kb >= 0, kb <= Int64.max / 1024 else { return nil }
            return kb * 1024
        }
        let complete = result.status == 0 && values.count == expectedPaths
        return SizeMeasurement(
            bytes: values.reduce(0, +), state: complete ? .complete : values.isEmpty ? .unavailable : .partial,
            errors: result.stderr.split(separator: "\n").map(String.init)
        )
    }

    static func combine(_ measurements: [SizeMeasurement]) -> SizeMeasurement {
        let complete = measurements.allSatisfy { $0.state == .complete }
        let available = measurements.contains { $0.state != .unavailable }
        return SizeMeasurement(bytes: measurements.reduce(0) { $0 + $1.bytes },
                               state: complete ? .complete : available ? .partial : .unavailable,
                               errors: measurements.flatMap(\.errors))
    }
}

enum Cleaner {
    /// Cleans a target and returns human-readable errors (empty on success).
    static func clean(_ target: StorageTarget, usage suppliedUsage: ApplicationUsageSnapshot? = nil) -> [String] {
        var errors: [String] = []
        let usage = suppliedUsage ?? (target.needsUsageCheck
            ? ApplicationUsageSnapshot.capture(includeApplications: !target.requiresAppsClosed.isEmpty) : nil)
        let paths = target.paths.filter { path in
            guard PathGlob.exists(path.path) else { return true }
            switch StorageSafety.check(path, target: target, usage: usage) {
            case .allowed: return true
            case .inUse: errors.append(tr("cleanup.protected_in_use", ["path": path.path]))
            case .recent: errors.append(tr("cleanup.protected_recent", ["path": path.path]))
            case .tracked: errors.append(tr("cleanup.protected_tracked", ["path": path.path]))
            case .unverified: errors.append(tr("cleanup.protected_unknown", ["path": path.path]))
            }
            return false
        }
        if !paths.isEmpty && !target.stopProcesses.isEmpty {
            ProcessKiller.terminateMatching(target.stopProcesses)
        }
        switch target.method {
        case .delete:
            errors += paths.compactMap { SafeDelete.remove($0, authorizedProjectPaths: target.authorizedProjectPaths) }
        case .trash:
            for url in paths where PathGlob.exists(url.path) {
                do {
                    if let authorization = target.pathAuthorizations[url.path], !authorization.validates(url) {
                        errors.append(tr("cleanup.protected_unknown", ["path": url.path])); continue
                    }
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                } catch {
                    errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
        case .commands(let commands, let thenDelete):
            // A tool command may act on more than a single path: reject the whole action if any path failed.
            guard paths.count == target.paths.count else { break }
            for command in commands {
                let result = Shell.run(command[0], Array(command.dropFirst()), timeout: 900)
                if result.status != 0 {
                    let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    errors.append("\(command.joined(separator: " ")): \(message.prefix(160))")
                }
            }
            if thenDelete {
                errors += paths.compactMap { SafeDelete.remove($0, authorizedProjectPaths: target.authorizedProjectPaths) }
            }
        }
        CleanupLog.record(CleanupLog.Entry(
            date: Date(),
            item: target.id,
            risk: target.risk.rawValue,
            method: target.method.logDescription,
            paths: target.paths.map(\.path),
            errors: errors, title: target.title
        ))
        return errors
    }
}

enum SafeDelete {
    private static let protectedTopLevel: Set<String> = [
        "Desktop", "Documents", "Downloads", "Library", "Pictures", "Movies", "Music",
        "Applications", "Public", "Project", "Projects", "Developer", ".ssh", ".gnupg", ".config",
    ]
    /// Shell setup is not a cache and no stack has any business touching it. Blocked outright so a
    /// stack file — including one from a contributor — can never take a terminal down with it.
    private static let protectedPrefixes: [String] = [
        ".oh-my-zsh", ".oh-my-posh", ".zshrc", ".zshenv", ".zprofile", ".zlogin", ".zlogout",
        ".zsh_history", ".zcompdump", ".bashrc", ".bash_profile", ".bash_history", ".profile",
        ".p10k.zsh", ".poshthemes", ".fzf.zsh", ".gitconfig", ".netrc",
    ]
    private static let protectedInLibrary: Set<String> = [
        "Caches", "Application Support", "Developer", "Preferences", "Keychains",
        "Containers", "Group Containers", "Mobile Documents", "Mail", "Messages",
    ]

    /// Home paths retain protected-root checks; external paths require exact project authorization.
    static func protectsShellConfiguration(_ name: String) -> Bool {
        protectedPrefixes.contains { name == $0 || name.hasPrefix($0) }
    }

    static func isAllowed(_ url: URL, authorizedProjectPaths: [URL] = [], home: String = NSHomeDirectory()) -> Bool {
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(home + "/") else {
            // Reject links (including linked ancestors) that now redirect a previously scanned artifact.
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
            return resolved == path && authorizedProjectPaths.contains {
                $0.standardizedFileURL.path == path
            }
        }
        guard !path.contains("/../") else { return false }
        let parts = path.dropFirst(home.count + 1).split(separator: "/").map(String.init)
        guard !parts.isEmpty else { return false }
        if parts.count == 1 && protectedTopLevel.contains(parts[0]) { return false }
        if protectsShellConfiguration(parts[0]) { return false }
        if parts.count == 2 && parts[0] == "Library" && protectedInLibrary.contains(parts[1]) { return false }
        return true
    }

    static func remove(_ url: URL, authorizedProjectPaths: [URL] = []) -> String? {
        guard PathGlob.exists(url.path) else { return nil }
        guard isAllowed(url, authorizedProjectPaths: authorizedProjectPaths) else { return tr("error.blocked", ["path": url.path]) }
        do {
            try FileManager.default.removeItem(at: url)
            return nil
        } catch {
            // Go's module cache (and some Pods) are read-only on purpose.
            Shell.run("/bin/chmod", ["-R", "u+w", url.path], timeout: 300)
            let result = Shell.run("/bin/rm", ["-rf", url.path], timeout: 900)
            guard PathGlob.exists(url.path) else { return nil }
            let reason = result.stderr.split(separator: "\n").first.map(String.init) ?? error.localizedDescription
            return "\(url.lastPathComponent): \(reason)"
        }
    }
}
