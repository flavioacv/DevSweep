import Foundation

enum MaintenanceTask: String, CaseIterable, Identifiable, Sendable {
    case launchAgents, preferences, spotlight, loginItems, verifyDisk, dns, quickLook
    var id: String { rawValue }
    var changesState: Bool { self == .dns || self == .quickLook }
    var title: String {
        switch self {
        case .launchAgents: tr("maintenance.agents")
        case .preferences: tr("maintenance.preferences")
        case .spotlight: tr("maintenance.spotlight")
        case .loginItems: tr("maintenance.login")
        case .verifyDisk: tr("maintenance.disk")
        case .dns: tr("maintenance.dns")
        case .quickLook: tr("maintenance.quicklook")
        }
    }
    var command: (String, [String])? {
        switch self {
        case .spotlight: ("/usr/bin/mdutil", ["-s", "/"])
        case .loginItems: ("/usr/bin/sfltool", ["dumpbtm"])
        case .verifyDisk: ("/usr/sbin/diskutil", ["verifyVolume", "/"])
        case .dns: ("/usr/bin/dscacheutil", ["-flushcache"])
        case .quickLook: ("/usr/bin/qlmanage", ["-r", "cache"])
        case .launchAgents, .preferences: nil
        }
    }

    func run(home: URL, control: ScanControl, searchRoots: [URL]? = nil) -> ShellResult {
        if let (executable, args) = command {
            return Shell.run(executable, args, timeout: 120, shouldCancel: { control.isCancelled })
        }
        var lines: [String] = []
        var failures = 0
        let roots = searchRoots ?? (self == .preferences ? [home.appendingPathComponent("Library/Preferences")]
            : [home.appendingPathComponent("Library/LaunchAgents"), URL(fileURLWithPath: "/Library/LaunchAgents"), URL(fileURLWithPath: "/Library/LaunchDaemons")])
        if control.isCancelled { return ShellResult(status: -2, stdout: "", stderr: tr("general.cancelled")) }
        for root in roots where PathGlob.exists(root.path) {
            let walk = DirectoryWalker.walk(root, depth: 0, control: control, limit: 5000)
            if !walk.complete { failures += 1; lines += walk.issues }
            for file in walk.files where file.pathExtension == "plist" {
                if control.isCancelled { return ShellResult(status: -2, stdout: lines.joined(separator: "\n"), stderr: tr("general.cancelled")) }
                do {
                    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
                    guard (attributes[.size] as? NSNumber)?.intValue ?? Int.max < 2_000_000 else {
                        failures += 1; lines.append(tr("maintenance.skipped", ["path": file.path])); continue
                    }
                    let data = try Data(contentsOf: file)
                    let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
                    if self == .launchAgents, let dictionary = plist as? [String: Any], let program = Self.program(dictionary) {
                        let exists = program.hasPrefix("/") ? FileManager.default.fileExists(atPath: program) : Shell.which(program) != nil
                        if !exists { lines.append(tr("maintenance.missing", ["path": file.path, "program": program])) }
                    }
                } catch { failures += 1; lines.append("\(file.path): \(error.localizedDescription)") }
            }
        }
        if lines.isEmpty { lines.append(tr("maintenance.no_issues")) }
        return ShellResult(status: failures > 0 ? 1 : 0, stdout: lines.joined(separator: "\n"), stderr: "")
    }

    static func program(_ plist: [String: Any]) -> String? {
        if let program = plist["Program"] as? String, !program.isEmpty { return program }
        return (plist["ProgramArguments"] as? [String])?.first
    }
}
