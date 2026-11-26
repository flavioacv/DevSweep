import Darwin
import Foundation

/// Rechecks project artifacts at execution time. An inconclusive probe preserves the artifact.
enum ProjectCleanupGuard {
    enum Verdict: Equatable { case allowed, inUse, tracked, unverified }

    static func check(
        _ path: URL, projectRoot: URL, handles snapshot: ShellResult? = nil,
        run: (String, [String]) -> ShellResult = { Shell.run($0, $1, timeout: 15) }
    ) -> Verdict {
        let root = projectRoot.resolvingSymlinksInPath().standardizedFileURL
        let artifact = path.resolvingSymlinksInPath().standardizedFileURL
        guard artifact.path.hasPrefix(root.path + "/"),
              FileManager.default.fileExists(atPath: root.path) else { return .unverified }

        // A manifest can belong to a nested package inside an enclosing Git repository.
        var ancestor = root
        var hasRepository = false
        while ancestor.path != "/" {
            if FileManager.default.fileExists(atPath: ancestor.appendingPathComponent(".git").path) {
                hasRepository = true
                break
            }
            ancestor.deleteLastPathComponent()
        }
        if hasRepository {
            let relative = String(artifact.path.dropFirst(root.path.count + 1))
            let tracked = run("/usr/bin/git", ["--literal-pathspecs", "-C", root.path, "ls-files", "-z", "--", relative])
            guard tracked.status == 0 else { return .unverified }
            if !tracked.stdout.isEmpty { return .tracked }
        }

        let handles = snapshot ?? run("/usr/sbin/lsof", ["-nP", "-a", "-u", String(getuid()), "-Fpn"])
        guard handles.status == 0 else { return .unverified }
        let lines = handles.stdout.split(separator: "\n")
        guard lines.contains(where: { $0.hasPrefix("p") }) else { return .unverified }
        for line in lines where line.hasPrefix("n") {
            let name = String(line.dropFirst())
            if name == root.path || name == projectRoot.path
                || name == artifact.path || name.hasPrefix(artifact.path + "/")
                || name == path.path || name.hasPrefix(path.path + "/") {
                return .inUse
            }
        }
        return .allowed
    }
}
