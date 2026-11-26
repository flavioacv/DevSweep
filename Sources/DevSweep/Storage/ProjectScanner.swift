import Foundation

struct DevProject: Sendable {
    let url: URL
    /// Marker files (from the stack definitions) present at the project root.
    let markers: Set<String>
    let lastActivity: Date

    var name: String { url.lastPathComponent }
}

/// Finds projects under the configured roots by the marker files stacks declare (pubspec.yaml, go.mod…).
enum ProjectScanner {
    private static let alwaysSkip: Set<String> = ["Library", "node_modules", "Pods", "DerivedData"]
    private static let gitActivity = [".git/index", ".git/FETCH_HEAD", ".git/HEAD"]

    static func scan(
        roots: [String], markers: Set<String>, activityFiles: [String],
        skipNames: Set<String>, maxDepth: Int = 4
    ) -> [DevProject] {
        guard !markers.isEmpty else { return [] }
        let fm = FileManager.default
        let skip = alwaysSkip.union(skipNames)
        let activity = Array(Set(gitActivity + Array(markers) + activityFiles))
        var visitedRoots = Set<String>()
        var projects: [DevProject] = []
        var visited = Set<String>()
        let authorizedRoots = roots.map { URL(fileURLWithPath: expandTilde($0)).resolvingSymlinksInPath().standardizedFileURL }

        func visit(_ path: String, depth: Int) {
            let url = URL(fileURLWithPath: path)
            guard visited.count < 50_000, visited.insert(path).inserted, FileIdentity.read(url) != nil, !FileFootprint.isDataless(url),
                  let entries = try? fm.contentsOfDirectory(atPath: path) else { return }
            let found = markers.intersection(entries)
            if !found.isEmpty {
                projects.append(DevProject(url: URL(fileURLWithPath: path), markers: found, lastActivity: lastActivity(path, activity, roots: authorizedRoots)))
            }
            guard depth < maxDepth else { return }
            for name in WorktreeDiscovery.agentFolders where entries.contains(name) {
                let candidate = url.appendingPathComponent(name == ".worktrees" ? name : name + "/worktrees")
                if FileIdentity.read(candidate) != nil { visit(candidate.path, depth: depth + 1) }
            }
            for entry in entries where !entry.hasPrefix(".") && !skip.contains(entry) {
                let child = path + "/" + entry
                var isDirectory: ObjCBool = false
                guard fm.fileExists(atPath: child, isDirectory: &isDirectory), isDirectory.boolValue,
                      (try? fm.destinationOfSymbolicLink(atPath: child)) == nil else { continue }
                visit(child, depth: depth + 1)
            }
        }

        for root in roots {
            let path = URL(fileURLWithPath: expandTilde(root)).resolvingSymlinksInPath().path
            // APFS is usually case-insensitive: ~/Project and ~/project are the same folder.
            guard visitedRoots.insert(path.lowercased()).inserted else { continue }
            visit(path, depth: 0)
        }
        var index = 0
        while index < projects.count && index < 128 {
            for linked in WorktreeDiscovery.linked(to: projects[index].url, roots: authorizedRoots) { visit(linked.path, depth: 0) }
            index += 1
        }
        return projects
    }

    private static func lastActivity(_ path: String, _ files: [String], roots: [URL]) -> Date {
        let git = WorktreeDiscovery.gitDirectory(URL(fileURLWithPath: path), roots: roots)
        let linkedActivity = ["index", "FETCH_HEAD", "HEAD"].compactMap { name in git.flatMap { PathGlob.modificationDate($0.appendingPathComponent(name)) } }
        let dates = linkedActivity + files.compactMap { PathGlob.modificationDate(URL(fileURLWithPath: path + "/" + $0)) }
        return dates.max() ?? PathGlob.modificationDate(URL(fileURLWithPath: path)) ?? .distantPast
    }
}
