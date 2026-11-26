import Foundation

struct OrphanRemovalContext: Sendable {
    let bundleID: String
    let roots: [URL]
    func validates() -> Bool {
        let inventory = AppUninstall.inventory(roots: roots, control: ScanControl())
        return inventory.complete && !inventory.apps.values.contains { $0.lowercased() == bundleID.lowercased() || $0.lowercased().hasPrefix(bundleID.lowercased() + ".") || bundleID.lowercased().hasPrefix($0.lowercased() + ".") }
    }
}

enum OrphanScanner {
    static func validID(_ text: String) -> Bool {
        text.count <= 200 && !text.lowercased().hasPrefix("com.apple.")
            && text.range(of: #"^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$"#, options: .regularExpression) != nil
    }

    static func scan(home: URL, roots: [URL]? = nil, receipts: [CleanupLog.Entry], control: ScanControl) -> GeneralReport {
        let roots = roots ?? [URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/System/Applications"), home.appendingPathComponent("Applications")]
        let inventory = AppUninstall.inventory(roots: roots, control: control)
        var report = GeneralReport(issues: inventory.issues, complete: inventory.complete)
        guard inventory.complete else { return report }
        let installed = Set(inventory.apps.values.map { $0.lowercased() })
        let known = Set(receipts.compactMap { receipt -> String? in
            guard receipt.method == "trash", receipt.errors.isEmpty,
                  receipt.paths.contains(where: { URL(fileURLWithPath: $0).pathExtension.lowercased() == "app" }),
                  let id = receipt.bundleID, validID(id) else { return nil }
            return id
        })
        let locations: [(String, AppFileKind)] = [("Caches", .cache), ("Logs", .logs), ("Preferences", .preferences),
            ("Application Support", .support), ("Saved Application State", .savedState), ("Containers", .container)]
        for (folder, kind) in locations {
            let root = home.appendingPathComponent("Library/" + folder)
            if !PathGlob.exists(root.path) { continue }
            let walk = DirectoryWalker.walk(root, depth: 0, control: control, limit: 5000)
            report.complete = report.complete && walk.complete; report.issues += walk.issues; report.inspected += walk.visited
            for file in walk.files + walk.directories {
                let id = (kind == .preferences || kind == .savedState) ? file.deletingPathExtension().lastPathComponent : file.lastPathComponent
                guard validID(id), !installed.contains(id.lowercased()) else { continue }
                var target = GeneralScanner.entry(file, root: root, area: .orphans, home: home).target
                target.requiresAppsClosed = [id]
                target.orphanRemovalContext = OrphanRemovalContext(bundleID: id, roots: roots)
                if !known.contains(id) || kind == .container { target.pathAuthorizations = [:] }
                if kind == .preferences { target.pathRules[file.path] = PathSpec(glob: file.path, filesOnly: true) }
                report.entries.append(GeneralEntry(target: target, modified: PathGlob.modificationDate(file), association: AppAssociation(bundleID: id, kind: kind)))
            }
        }
        let agents = home.appendingPathComponent("Library/LaunchAgents")
        if PathGlob.exists(agents.path) {
            let walk = DirectoryWalker.walk(agents, depth: 0, control: control, limit: 5000)
            report.complete = report.complete && walk.complete; report.issues += walk.issues
            for file in walk.files where file.pathExtension == "plist" {
                guard let size = try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber,
                      size.intValue < 2_000_000, let data = try? Data(contentsOf: file),
                      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                      let label = plist["Label"] as? String, validID(label),
                      let executable = MaintenanceTask.program(plist), executable.hasPrefix("/"),
                      !FileManager.default.fileExists(atPath: executable) else { continue }
                let owner = known.first { label == $0 || label.hasPrefix($0 + ".") }
                let service = ServiceRemovalContext(label: label, executable: executable)
                var target = GeneralScanner.entry(file, root: agents, area: .orphans, home: home).target
                target.pathRules[file.path] = PathSpec(glob: file.path, filesOnly: true)
                target.serviceRemovalContext = service
                if let owner, OrphanRemovalContext(bundleID: owner, roots: roots).validates(), service.validates() {
                    target.requiresAppsClosed = [owner]
                    target.orphanRemovalContext = OrphanRemovalContext(bundleID: owner, roots: roots)
                } else { target.pathAuthorizations = [:] }
                report.entries.append(GeneralEntry(target: target, modified: PathGlob.modificationDate(file), association: AppAssociation(bundleID: owner ?? label, kind: .service)))
            }
        }
        if control.isCancelled { report.complete = false; report.issues.append(tr("general.cancelled")) }
        return report
    }
}
