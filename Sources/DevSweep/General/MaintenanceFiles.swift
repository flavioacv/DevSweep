import Foundation
import Darwin

enum MaintenanceFiles {
    static func scan(_ task: MaintenanceTask, home: URL, control: ScanControl) -> GeneralReport {
        let relative: String
        switch task {
        case .savedStates: relative = "Library/Saved Application State"
        case .repairPreferences: relative = "Library/Preferences"
        case .finderLists: relative = "Library/Application Support/com.apple.sharedfilelist"
        case .launchAgents: relative = "Library/LaunchAgents"
        default: return GeneralReport(issues: [tr("maintenance.unsupported")], complete: false)
        }
        let root = home.appendingPathComponent(relative)
        guard PathGlob.exists(root.path) else { return GeneralReport() }
        let walk = DirectoryWalker.walk(root, depth: 0, control: control, limit: 5000)
        var report = GeneralReport(issues: walk.issues, complete: walk.complete, inspected: walk.visited)
        for path in walk.files + walk.directories {
            if control.isCancelled { report.complete = false; break }
            var eligible = false
            var owner: String?
            switch task {
            case .savedStates:
                owner = path.deletingPathExtension().lastPathComponent
                guard path.pathExtension == "savedState", let date = PathGlob.modificationDate(path), date < Date().addingTimeInterval(-30 * 86400) else { continue }
                let children = DirectoryWalker.walk(path, depth: 4, control: control, reportDepthLimit: true)
                eligible = children.complete && children.files.allSatisfy { (PathGlob.modificationDate($0) ?? Date()) < Date().addingTimeInterval(-30 * 86400) }
            case .repairPreferences:
                guard path.pathExtension == "plist", let info = try? FileManager.default.attributesOfItem(atPath: path.path),
                      (info[.size] as? NSNumber)?.intValue ?? Int.max <= 2_000_000 else { continue }
                do { let data = try Data(contentsOf: path); _ = try PropertyListSerialization.propertyList(from: data, format: nil) }
                catch { eligible = true }
                owner = path.deletingPathExtension().lastPathComponent
            case .finderLists:
                eligible = ["sfl2", "sfl3"].contains(path.pathExtension) && (PathGlob.modificationDate(path) ?? Date()) < Date().addingTimeInterval(-90 * 86400)
                owner = "com.apple.finder"
            case .launchAgents:
                guard path.pathExtension == "plist", let data = try? Data(contentsOf: path), data.count < 2_000_000,
                      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                      let program = MaintenanceTask.program(plist), program.hasPrefix("/") else { continue }
                eligible = !FileManager.default.fileExists(atPath: program)
            default: break
            }
            guard eligible else { continue }
            var target = GeneralScanner.entry(path, root: root, area: .maintenanceFiles, home: home).target
            if let owner { target.requiresAppsClosed = [owner] }
            if task == .savedStates { target.pathRules[path.path] = PathSpec(glob: path.path, olderThanDays: 30); target.recursiveAgeDays = 30 }
            // A loaded LaunchAgent can still be running after its executable disappears; report only.
            if task == .launchAgents { target.pathAuthorizations = [:] }
            report.entries.append(GeneralEntry(target: target, modified: PathGlob.modificationDate(path)))
        }
        return report
    }
}

enum MaintenanceDatabase {
    static func compact(_ database: URL, backupRoot: URL, usage: ApplicationUsageSnapshot,
                        control: ScanControl, deleteOldQuarantine: Bool = false) -> ShellResult {
        guard !control.isCancelled else { return ShellResult(status: -2, stdout: "", stderr: tr("general.cancelled")) }
        guard let grant = PathAuthorization.issue(database, within: database.deletingLastPathComponent()),
              usage.handles.status == 0, usage.handles.stdout.contains("\np") || usage.handles.stdout.hasPrefix("p"),
              !usage.handles.stdout.split(separator: "\n").filter({ $0.hasPrefix("n") }).contains(where: {
                  let name = String($0.dropFirst()); return name == database.path || name.hasPrefix(database.path + "-")
              }) else { return ShellResult(status: 1, stdout: "", stderr: tr("maintenance.database_busy")) }
        func run(_ sql: String, readonly: Bool = false) -> ShellResult {
            Shell.run("/usr/bin/sqlite3", (readonly ? ["-readonly"] : []) + ["-cmd", ".timeout 1500", database.path, sql], timeout: 30, shouldCancel: { control.isCancelled })
        }
        let check = run("PRAGMA quick_check;", readonly: true)
        guard check.status == 0, check.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "ok" else { return ShellResult(status: 1, stdout: check.stdout, stderr: tr("maintenance.database_invalid")) }
        do { try FileManager.default.createDirectory(at: backupRoot, withIntermediateDirectories: true) }
        catch { return ShellResult(status: 1, stdout: "", stderr: error.localizedDescription) }
        guard FileIdentity.read(backupRoot) != nil,
              let attributes = try? FileManager.default.attributesOfItem(atPath: backupRoot.path),
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { return ShellResult(status: 1, stdout: "", stderr: tr("maintenance.database_preserved")) }
        do { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: backupRoot.path) }
        catch { return ShellResult(status: 1, stdout: "", stderr: error.localizedDescription) }
        let backup = backupRoot.appendingPathComponent(UUID().uuidString + ".sqlite")
        let escaped = backup.path.replacingOccurrences(of: "'", with: "''")
        let copy = run("VACUUM INTO '\(escaped)';", readonly: true)
        guard copy.status == 0, grant.validates(database), !control.isCancelled else { return ShellResult(status: 1, stdout: copy.stdout, stderr: copy.stderr + "\n" + tr("maintenance.database_preserved")) }
        var sql = "VACUUM; PRAGMA quick_check;"
        if deleteOldQuarantine {
            let schema = run("SELECT name FROM pragma_table_info('LSQuarantineEvent') WHERE name = 'LSQuarantineTimeStamp';", readonly: true)
            guard schema.status == 0, schema.stdout.contains("LSQuarantineTimeStamp") else { return ShellResult(status: 1, stdout: "", stderr: tr("maintenance.unsupported")) }
            let cutoff = Date().timeIntervalSinceReferenceDate - 90 * 86400
            sql = "BEGIN IMMEDIATE; DELETE FROM LSQuarantineEvent WHERE LSQuarantineTimeStamp < \(cutoff); COMMIT; " + sql
        }
        let result = run(sql)
        let successful = result.status == 0 && result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "ok"
        return ShellResult(status: successful ? 0 : 1, stdout: result.stdout + "\n" + tr("maintenance.backup", ["path": backup.path]), stderr: result.stderr + (successful ? "" : "\n" + tr("maintenance.database_invalid")))
    }
}
