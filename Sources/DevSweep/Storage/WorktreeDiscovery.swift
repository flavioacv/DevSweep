import Foundation

/// Reads linked-worktree metadata only inside configured workspace roots. Never follows symlinks.
enum WorktreeDiscovery {
    static let agentFolders: Set<String> = [".worktrees", ".claude", ".codex", ".cursor"]

    static func text(_ file: URL) -> String? {
        guard FileIdentity.read(file) != nil, !FileFootprint.isDataless(file),
              let attrs = try? FileManager.default.attributesOfItem(atPath: file.path), attrs[.type] as? FileAttributeType == .typeRegular,
              (attrs[.size] as? NSNumber)?.intValue ?? Int.max < 8192,
              let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 8192), data.count < 8192 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func contained(_ url: URL, roots: [URL]) -> Bool {
        guard let identity = FileIdentity.read(url) else { return false }
        return roots.contains { root in
            (url.path == root.path || url.path.hasPrefix(root.path + "/")) && FileIdentity.read(root)?.device == identity.device
        }
    }
    static func gitDirectory(_ project: URL, roots: [URL]) -> URL? {
        let git = project.appendingPathComponent(".git")
        if (try? FileManager.default.attributesOfItem(atPath: git.path)[.type]) as? FileAttributeType == .typeDirectory {
            return contained(git, roots: roots) ? git : nil
        }
        guard let value = text(git), value.hasPrefix("gitdir: ") else { return nil }
        let path = String(value.dropFirst(8))
        let directory = URL(fileURLWithPath: path, relativeTo: project.appendingPathComponent("", isDirectory: true)).standardizedFileURL
        return contained(directory, roots: roots) ? directory : nil
    }
    static func linked(to project: URL, roots: [URL]) -> [URL] {
        guard var git = gitDirectory(project, roots: roots) else { return [] }
        if let common = text(git.appendingPathComponent("commondir")) {
            let directory = URL(fileURLWithPath: common, relativeTo: git.appendingPathComponent("", isDirectory: true)).standardizedFileURL
            guard contained(directory, roots: roots) else { return [] }
            git = directory
        }
        let registry = git.appendingPathComponent("worktrees")
        guard contained(registry, roots: roots),
              let names = try? FileManager.default.contentsOfDirectory(atPath: registry.path), names.count <= 128 else { return [] }
        return names.sorted().compactMap { name in
            let admin = registry.appendingPathComponent(name)
            guard contained(admin, roots: roots), let pointer = text(admin.appendingPathComponent("gitdir")) else { return nil }
            let marker = URL(fileURLWithPath: pointer, relativeTo: admin.appendingPathComponent("", isDirectory: true)).standardizedFileURL
            let root = marker.deletingLastPathComponent()
            guard marker.lastPathComponent == ".git", contained(root, roots: roots), gitDirectory(root, roots: roots)?.path == admin.path else { return nil }
            return root
        }
    }
}
