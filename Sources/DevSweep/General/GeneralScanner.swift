import Foundation

enum GeneralArea: String, CaseIterable, Identifiable, Sendable {
    case logs, caches, temporaries, trash, external, projects, explorer, installers, applications, orphans, maintenanceFiles, maintenance, monitor
    var id: String { rawValue }
    var title: String {
        switch self {
        case .logs: tr("general.logs")
        case .caches: tr("general.caches")
        case .temporaries: tr("hygiene.temporaries")
        case .trash: tr("hygiene.trash")
        case .external: tr("hygiene.external")
        case .projects: tr("general.projects")
        case .explorer: tr("general.explorer")
        case .installers: tr("general.installers")
        case .applications: tr("general.applications")
        case .orphans: tr("orphans.title")
        case .maintenanceFiles: tr("maintenance.files")
        case .maintenance: tr("general.maintenance")
        case .monitor: tr("general.monitor")
        }
    }
    var icon: String {
        switch self {
        case .logs: "doc.text"
        case .caches: "shippingbox"
        case .temporaries: "clock.arrow.circlepath"
        case .trash: "trash"
        case .external: "externaldrive"
        case .projects: "hammer"
        case .explorer: "internaldrive"
        case .installers: "shippingbox.and.arrow.backward"
        case .applications: "app"
        case .orphans: "app.badge"
        case .maintenanceFiles: "doc.badge.gearshape"
        case .maintenance: "wrench.and.screwdriver"
        case .monitor: "waveform.path.ecg"
        }
    }
}

struct GeneralEntry: Identifiable, Sendable {
    let target: StorageTarget
    let modified: Date?
    var association: AppAssociation? = nil
    var installerSource: InstallerSource? = nil
    var id: String { target.id }
    var url: URL { target.paths[0] }
    var removable: Bool { target.pathAuthorizations.count == target.paths.count }
}

struct GeneralReport: Sendable {
    var entries: [GeneralEntry] = []
    var issues: [String] = []
    var complete = true
    var inspected = 0
    var references: [ConfigReference] = []
    var referencesComplete = true
    var referenceIssues: [String] = []
}

enum GeneralScanner {
    static let cacheNames: Set<String> = ["Code Cache", "GPUCache", "DawnCache", "GrShaderCache", "GraphiteDawnCache", "DawnGraphiteCache", "DawnWebGPUCache", "cache2"]
    static let artifactNames: Set<String> = ["node_modules", "target", "build", "dist", "venv", ".venv", ".pytest_cache", ".mypy_cache", ".tox", ".nox", ".ruff_cache", ".gradle", ".terragrunt-cache", "__pycache__", ".next", ".nuxt", ".output", "vendor", "bin", "obj", ".turbo", ".parcel-cache", ".dart_tool", ".zig-cache", "zig-out", ".angular", ".svelte-kit", ".astro", "coverage", "DerivedData", "Pods", ".cxx", ".expo", ".build"]
    static let markers: Set<String> = ["package.json", "Cargo.toml", "go.mod", "pubspec.yaml", "pyproject.toml", "requirements.txt", "composer.json", "pom.xml", "build.gradle", "build.gradle.kts", "Package.swift", "CMakeLists.txt", "build.zig", "Gemfile", "terragrunt.hcl"]

    static func scan(_ area: GeneralArea, home: URL, selectedRoot: URL?, prefs: PrefsSnapshot,
                     control: ScanControl, applicationRoots: [URL]? = nil) -> GeneralReport {
        let home = home.resolvingSymlinksInPath().standardizedFileURL
        let selectedRoot = selectedRoot?.standardizedFileURL
        var report = GeneralReport()
        let fm = FileManager.default
        let library = home.appendingPathComponent("Library")
        if let selectedRoot {
            let volume = SystemMonitor.volumes().contains { selectedRoot.path == $0.path || selectedRoot.path.hasPrefix($0.path + "/") }
            if FileIdentity.read(selectedRoot) == nil || (selectedRoot.path.hasPrefix("/Volumes/") && !volume) {
                report.complete = false; report.issues = [tr("general.root_unavailable")]; return report
            }
        }
        switch area {
        case .orphans:
            return OrphanScanner.scan(home: home, roots: applicationRoots, receipts: CleanupLog.read(), control: control)
        case .temporaries:
            return GeneralHygiene.temporaries(root: URL(fileURLWithPath: NSTemporaryDirectory()), home: home, control: control)
        case .trash:
            return GeneralHygiene.trash(home: home, control: control)
        case .external:
            return GeneralHygiene.external(root: selectedRoot, home: home, volumes: SystemMonitor.volumes(), control: control)
        case .logs:
            var roots = selectedRoot.map { [$0] } ?? [library.appendingPathComponent("Logs")]
            let support = library.appendingPathComponent("Application Support")
            for app in selectedRoot == nil ? ((try? fm.contentsOfDirectory(at: support, includingPropertiesForKeys: nil)) ?? []) : [] {
                if control.isCancelled { report.complete = false; break }
                let children = (try? fm.contentsOfDirectory(at: app, includingPropertiesForKeys: nil)) ?? []
                roots += children.filter { $0.lastPathComponent.lowercased() == "logs" }
            }
            if selectedRoot == nil { roots += containerRoots(library: library, name: "Logs") }
            for root in unique(roots) where PathGlob.exists(root.path) {
                let walk = DirectoryWalker.walk(root, depth: 5, control: control)
                absorb(walk, into: &report)
                for file in walk.files where isLog(file) {
                    guard let date = PathGlob.modificationDate(file), date < Date().addingTimeInterval(-30 * 86_400) else { continue }
                    report.entries.append(entry(file, root: root, area: area, home: home, age: 30))
                }
            }
        case .caches:
            let installed = scan(.applications, home: home, selectedRoot: nil, prefs: prefs, control: control, applicationRoots: applicationRoots).entries
            let owners = installed.compactMap { item -> (String, String)? in
                guard let bundle = Bundle(url: item.url), let id = bundle.bundleIdentifier else { return nil }
                return (id, (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? item.url.deletingPathExtension().lastPathComponent)
            }
            let cacheRoots = selectedRoot.map { [$0] } ?? ([library.appendingPathComponent("Caches"), library.appendingPathComponent("Application Support")] + containerRoots(library: library, name: "Caches"))
            for root in cacheRoots where PathGlob.exists(root.path) {
                let walk = DirectoryWalker.walk(root, depth: 4, control: control,
                    skip: ["Local Storage", "Session Storage", "IndexedDB", "Service Worker", "Databases", "Cookies", "Network", "node_modules", ".git"],
                    pruneNames: cacheNames.union(["Cache", "CachedData"]))
                absorb(walk, into: &report)
                for folder in walk.directories {
                    guard !folder.pathComponents.contains(where: { $0.hasPrefix("com.apple.") }) else { continue }
                    let parent = folder.deletingLastPathComponent()
                    let recognizable = cacheNames.contains(folder.lastPathComponent)
                        || (["Cache", "CachedData"].contains(folder.lastPathComponent)
                            && (PathGlob.exists(parent.appendingPathComponent("Code Cache").path)
                                || PathGlob.exists(parent.appendingPathComponent("GPUCache").path)))
                        || validCacheTag(folder)
                    if recognizable {
                        var item = entry(folder, root: root, area: area, home: home)
                        var target = item.target
                        let components = folder.pathComponents.map { $0.lowercased().filter { $0.isLetter || $0.isNumber } }
                        let pairs = zip(components, components.dropFirst()).map { $0 + $1 }
                        target.requiresAppsClosed = owners.filter { owner in
                            let id = owner.0.lowercased().filter { $0.isLetter || $0.isNumber }
                            let name = owner.1.lowercased().filter { $0.isLetter || $0.isNumber }
                            return components.contains(id) || components.contains(name) || pairs.contains(name)
                        }.map { $0.0 }
                        if target.requiresAppsClosed.isEmpty && !validCacheTag(folder) { target.pathAuthorizations = [:] }
                        item = GeneralEntry(target: target, modified: item.modified)
                        report.entries.append(item)
                    }
                }
            }
        case .installers:
            return InstallerDiscovery.scan(home: home, selectedRoot: selectedRoot, control: control)
        case .projects:
            guard prefs.workspacesConfirmed else { report.issues = [tr("general.confirm_projects")]; report.complete = false; return report }
            let roots = selectedRoot.map { [$0] } ?? prefs.projectRoots.map { URL(fileURLWithPath: expandTilde($0)).resolvingSymlinksInPath() }
            var pending = roots
            var queued = Set(roots.map(\.path))
            let discoveryDeadline = Date().addingTimeInterval(30)
            var visited = Set<String>(), seen = Set<String>()
            while !pending.isEmpty {
                if control.isCancelled || Date() > discoveryDeadline { report.complete = false; report.issues.append(tr("general.scan_limited")); break }
                let root = pending.removeFirst()
                guard visited.insert(root.path).inserted else { continue }
                if visited.count > 128 { report.complete = false; report.issues.append(tr("general.scan_limited")); break }
                let walk = DirectoryWalker.walk(root, depth: 6, control: control, skip: [".git"], pruneNames: artifactNames)
                absorb(walk, into: &report)
                for project in [root] + walk.directories where PathGlob.exists(project.appendingPathComponent(".git").path) {
                    if control.isCancelled || Date() > discoveryDeadline { report.complete = false; report.issues.append(tr("general.scan_limited")); break }
                    for linked in WorktreeDiscovery.linked(to: project, roots: roots) where !queued.contains(linked.path) {
                        if queued.count >= 128 { report.complete = false; report.issues.append(tr("general.scan_limited")); break }
                        queued.insert(linked.path); pending.append(linked)
                    }
                }
                for folder in walk.directories where artifactNames.contains(folder.lastPathComponent) && seen.insert(folder.path).inserted {
                    guard let project = projectRoot(folder, within: root) else { continue }
                    var item = entry(folder, root: root, area: area, home: home)
                    var target = item.target
                    target.projectRootsByPath = [folder.path: project]
                    target.protectNestedRepositories = true
                    item = GeneralEntry(target: target, modified: item.modified)
                    report.entries.append(item)
                }
            }
        case .explorer:
            let root = selectedRoot ?? home
            do {
                for file in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
                    if control.isCancelled { report.complete = false; break }
                    report.inspected += 1
                    guard FileIdentity.read(file) != nil else { continue }
                    report.entries.append(entry(file.resolvingSymlinksInPath().standardizedFileURL, root: root, area: area, home: home))
                }
            } catch { report.complete = false; report.issues.append(error.localizedDescription) }
        case .applications:
            for root in applicationRoots ?? [URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/System/Applications"), home.appendingPathComponent("Applications")] where PathGlob.exists(root.path) {
                let walk = DirectoryWalker.walk(root, depth: 2, control: control)
                absorb(walk, into: &report)
                for app in walk.directories where app.pathExtension.lowercased() == "app" {
                    var item = entry(app, root: root, area: area, home: home)
                    if let id = Bundle(url: app)?.bundleIdentifier, !id.lowercased().hasPrefix("com.apple.") {
                        var target = item.target
                        target.requiresAppsClosed = [id]
                        item = GeneralEntry(target: target, modified: item.modified)
                    } else {
                        var target = item.target; target.pathAuthorizations = [:]
                        item = GeneralEntry(target: target, modified: item.modified)
                    }
                    report.entries.append(item)
                }
            }
        case .maintenanceFiles, .maintenance, .monitor: break
        }
        var seen = Set<String>()
        report.entries = report.entries.filter { seen.insert($0.url.path).inserted }
        if control.isCancelled { report.complete = false; report.issues.append(tr("general.cancelled")) }
        return report
    }

    static func entry(_ path: URL, root: URL, area: GeneralArea, home: URL, age: Int? = nil) -> GeneralEntry {
        var target = StorageTarget(id: "general:\(area.rawValue):\(path.path)",
            stack: StackInfo(id: "general-workspace", name: area.title, icon: area.icon, order: 0),
            title: path.lastPathComponent, detail: path.deletingLastPathComponent().path,
            risk: .dataLoss, paths: [path], method: .trash, autoRecommend: false)
        let homePath = home.standardizedFileURL.path
        let inHome = path.path.hasPrefix(homePath + "/")
        let forbidden: Set<String> = [".ssh", ".gnupg", ".config", ".git", "Keychains", "Mobile Documents"]
        let protectedRoots = ["Library", "Documents", "Desktop", "Downloads", "Pictures", "Music", "Movies", "Applications"]
        let components = path.pathComponents
        let protectedHomeRoot = protectedRoots.contains { path.path == home.appendingPathComponent($0).path }
            || ["Caches", "Application Support", "Preferences", "Containers", "Group Containers", "Logs"].contains { path.path == home.appendingPathComponent("Library/" + $0).path }
        let external = root.path.hasPrefix("/Volumes/") && root.pathComponents.count >= 3
        let application = area == .applications && root.path == "/Applications" && path.pathExtension == "app"
        let allowedHome = !inHome || SafeDelete.isAllowed(path, home: homePath)
        if (inHome || external || application) && allowedHome && !protectedHomeRoot
            && forbidden.isDisjoint(with: components) && !components.contains(where: SafeDelete.protectsShellConfiguration),
           let authorization = PathAuthorization.issue(path, within: root) {
            target.pathAuthorizations[path.path] = authorization
        }
        if let age { target.pathRules[path.path] = PathSpec(glob: path.path, olderThanDays: age, filesOnly: true) }
        return GeneralEntry(target: target, modified: PathGlob.modificationDate(path))
    }

    static func projectRoot(_ artifact: URL, within root: URL) -> URL? {
        var parent = artifact.deletingLastPathComponent()
        while parent.path == root.path || parent.path.hasPrefix(root.path + "/") {
            let entries = Set((try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? [])
            if !entries.isDisjoint(with: markers) || entries.contains(where: { $0.hasSuffix(".csproj") || $0.hasSuffix(".fsproj") }) { return parent }
            if parent.path == root.path { break }
            parent.deleteLastPathComponent()
        }
        return nil
    }

    static func isLog(_ path: URL) -> Bool {
        let ext = path.pathExtension.lowercased()
        return ["log", "ips", "crash", "hang", "spin"].contains(ext)
            || path.lastPathComponent.range(of: #"\.log\.(?:[0-9]+|gz)$"#, options: .regularExpression) != nil
    }

    static func validCacheTag(_ directory: URL) -> Bool {
        let tag = directory.appendingPathComponent("CACHEDIR.TAG")
        guard FileIdentity.read(tag) != nil, let handle = try? FileHandle(forReadingFrom: tag) else { return false }
        defer { try? handle.close() }
        let data = try? handle.read(upToCount: 43)
        return data.flatMap { String(data: $0, encoding: .utf8) } == "Signature: 8a477f597d28d172789f06886806bc55"
    }

    private static func containerRoots(library: URL, name: String) -> [URL] {
        var result: [URL] = []
        for base in ["Containers", "Group Containers"] {
            let root = library.appendingPathComponent(base)
            for container in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
                let candidate = container.appendingPathComponent((base == "Containers" ? "Data/" : "") + "Library/" + name)
                if FileIdentity.read(candidate) != nil { result.append(candidate.resolvingSymlinksInPath().standardizedFileURL) }
            }
        }
        return result
    }

    private static func unique(_ urls: [URL]) -> [URL] { Array(Set(urls)).sorted { $0.path < $1.path } }
    private static func absorb(_ walk: WalkReport, into report: inout GeneralReport) {
        report.inspected += walk.visited; report.issues += walk.issues; report.complete = report.complete && walk.complete
    }
}

/// Inspects only a bounded ZIP central directory. No extraction, decompression or cloud download.
enum InstallerArchive {
    static func containsInstaller(_ url: URL) -> Bool {
        names(url)?.contains { $0.contains(".app/Contents/Info.plist") || $0.hasSuffix(".pkg") || $0.hasSuffix(".mpkg") } ?? false
    }
    static func containsFirmware(_ url: URL) -> Bool {
        guard let entries = names(url) else { return false }
        return entries.contains("BuildManifest.plist") && entries.contains("Restore.plist")
    }

    /// ZIP/ZIP64 central-directory metadata only, capped independently of payload size.
    private static func names(_ url: URL) -> [String]? {
        guard FileIdentity.read(url) != nil, !FileFootprint.isDataless(url), let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        func number(_ data: Data, _ offset: Int, _ length: Int) -> UInt64 {
            guard offset >= 0, offset + length <= data.count else { return UInt64.max }
            return (0..<length).reduce(0) { $0 | UInt64(data[offset + $1]) << (8 * $1) }
        }
        do {
            let size = try file.seekToEnd()
            guard size >= 22 else { return nil }
            let tailSize = min(size, 65_557)
            try file.seek(toOffset: size - tailSize)
            let tail = try file.read(upToCount: Int(tailSize)) ?? Data()
            guard let end = tail.range(of: Data([0x50, 0x4b, 0x05, 0x06]), options: .backwards), end.lowerBound + 22 <= tail.count else { return nil }
            let at = end.lowerBound, absoluteEnd = size - tailSize + UInt64(at)
            guard number(tail, at + 4, 2) == 0, number(tail, at + 6, 2) == 0,
                  UInt64(at + 22) + number(tail, at + 20, 2) == UInt64(tail.count) else { return nil }
            var count = number(tail, at + 10, 2), bytes = number(tail, at + 12, 4), offset = number(tail, at + 16, 4)
            var boundary = absoluteEnd
            if count == 0xffff || bytes == 0xffffffff || offset == 0xffffffff {
                guard absoluteEnd >= 20 else { return nil }
                try file.seek(toOffset: absoluteEnd - 20)
                let locator = try file.read(upToCount: 20) ?? Data()
                guard locator.count == 20, locator.prefix(4) == Data([0x50, 0x4b, 0x06, 0x07]),
                      number(locator, 4, 4) == 0, number(locator, 16, 4) == 1 else { return nil }
                let recordOffset = number(locator, 8, 8)
                guard absoluteEnd >= 76, recordOffset <= absoluteEnd - 76 else { return nil }
                try file.seek(toOffset: recordOffset)
                let record = try file.read(upToCount: 56) ?? Data()
                guard record.count == 56, record.prefix(4) == Data([0x50, 0x4b, 0x06, 0x06]),
                      number(record, 4, 8) >= 44, number(record, 4, 8) <= 1024,
                      number(record, 16, 4) == 0, number(record, 20, 4) == 0,
                      number(record, 24, 8) == number(record, 32, 8) else { return nil }
                guard number(record, 4, 8) <= absoluteEnd - 20 - recordOffset - 12 else { return nil }
                count = number(record, 32, 8); bytes = number(record, 40, 8); offset = number(record, 48, 8); boundary = recordOffset
            } else if number(tail, at + 8, 2) != count { return nil }
            guard count > 0, count <= 1000, bytes <= 1_048_576, offset <= boundary, bytes <= boundary - offset else { return nil }
            try file.seek(toOffset: offset)
            let central = try file.read(upToCount: Int(bytes)) ?? Data()
            var cursor = 0
            var result: [String] = []
            for _ in 0..<count {
                guard cursor + 46 <= central.count, central[cursor..<cursor + 4] == Data([0x50, 0x4b, 0x01, 0x02]) else { return nil }
                let length = Int(number(central, cursor + 28, 2)), extra = Int(number(central, cursor + 30, 2)), comment = Int(number(central, cursor + 32, 2))
                guard cursor + 46 + length + extra + comment <= central.count,
                      let name = String(data: central[cursor + 46..<cursor + 46 + length], encoding: .utf8),
                      !name.hasPrefix("/"), !name.contains("\0"), !name.contains("\\"), !name.split(separator: "/").contains("..") else { return nil }
                result.append(name); cursor += 46 + length + extra + comment
            }
            return result
        } catch { return nil }
    }
}
