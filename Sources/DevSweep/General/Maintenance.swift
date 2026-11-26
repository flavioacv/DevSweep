import Foundation
import Darwin

enum MaintenanceTask: String, CaseIterable, Identifiable, Sendable {
    case launchAgents, preferences, spotlight, loginItems, verifyDisk, dns, quickLook
    case iconCache, savedStates, repairPreferences, sqlite, preventDSStore, legacyOverrides, networkReset, permissions
    case spotlightRebuild, spotlightRules, periodic, finderLists, gatekeeper, notifications, coreDuet, sensorReport, backups, dockerAudit, dockerPrune
    var reviewsFiles: Bool { [.savedStates, .repairPreferences, .finderLists].contains(self) }
    var requiresAdmin: Bool { [.dns, .networkReset, .permissions, .spotlightRebuild, .periodic, .sensorReport].contains(self) }
    var id: String { rawValue }
    var changesState: Bool { [.dns, .quickLook, .iconCache, .sqlite, .preventDSStore, .networkReset, .permissions, .spotlightRebuild, .periodic, .gatekeeper, .notifications, .coreDuet, .dockerPrune].contains(self) }
    var title: String {
        switch self {
        case .launchAgents: tr("maintenance.agents")
        case .preferences: tr("maintenance.preferences")
        case .spotlight: tr("maintenance.spotlight")
        case .loginItems: tr("maintenance.login")
        case .verifyDisk: tr("maintenance.disk")
        case .dns: tr("maintenance.dns")
        case .quickLook: tr("maintenance.quicklook")
        case .iconCache: tr("maintenance.icon_cache")
        case .savedStates: tr("maintenance.saved_states")
        case .repairPreferences: tr("maintenance.repair_preferences")
        case .sqlite: tr("maintenance.sqlite")
        case .preventDSStore: tr("maintenance.prevent_dsstore")
        case .legacyOverrides: tr("maintenance.legacy_overrides")
        case .networkReset: tr("maintenance.network_reset")
        case .permissions: tr("maintenance.permissions")
        case .spotlightRebuild: tr("maintenance.spotlight_rebuild")
        case .spotlightRules: tr("maintenance.spotlight_rules")
        case .periodic: tr("maintenance.periodic")
        case .finderLists: tr("maintenance.finder_lists")
        case .gatekeeper: tr("maintenance.gatekeeper")
        case .notifications: tr("maintenance.notifications")
        case .coreDuet: tr("maintenance.coreduet")
        case .sensorReport: tr("maintenance.sensor_report")
        case .backups: tr("maintenance.backups")
        case .dockerAudit: tr("docker.audit")
        case .dockerPrune: tr("docker.prune")
        }
    }
    var command: (String, [String])? {
        switch self {
        case .spotlight: ("/usr/bin/mdutil", ["-s", "/"])
        case .loginItems: ("/usr/bin/sfltool", ["dumpbtm"])
        case .verifyDisk: ("/usr/sbin/diskutil", ["verifyVolume", "/"])
        case .dns: ("/usr/bin/killall", ["-HUP", "mDNSResponder"])
        case .quickLook: ("/usr/bin/qlmanage", ["-r", "cache"])
        case .iconCache: ("/usr/bin/killall", ["-HUP", "iconservicesagent"])
        case .preventDSStore: ("/usr/bin/defaults", ["write", "com.apple.desktopservices", "DSDontWriteNetworkStores", "-bool", "true"])
        case .legacyOverrides: ("/usr/bin/defaults", ["read", "NSGlobalDomain", "NSAppSleepDisabled"])
        case .networkReset: ("/sbin/route", ["-n", "flush"])
        case .permissions: ("/usr/sbin/diskutil", ["resetUserPermissions", "/", String(getuid())])
        case .spotlightRebuild: ("/usr/bin/mdutil", ["-E", "/"])
        case .spotlightRules: ("/usr/bin/mdutil", ["-s", "-a"])
        case .periodic: ("/usr/sbin/periodic", ["daily", "weekly", "monthly"])
        case .sensorReport:
            #if arch(arm64)
            ("/usr/bin/powermetrics", ["-n", "1", "-i", "1000", "--samplers", "cpu_power,gpu_power,ane_power,thermal"])
            #else
            ("/usr/bin/powermetrics", ["-n", "1", "-i", "1000", "--samplers", "smc,gpu_power"])
            #endif
        case .backups: ("/usr/bin/tmutil", ["listbackups"])
        case .launchAgents, .preferences, .savedStates, .repairPreferences, .sqlite, .finderLists, .gatekeeper, .notifications, .coreDuet, .dockerAudit, .dockerPrune: nil
        }
    }

    func run(home: URL, control: ScanControl, searchRoots: [URL]? = nil,
             executor: (String, [String], ScanControl) -> ShellResult = { executable, args, flag in Shell.run(executable, args, timeout: 120, shouldCancel: { flag.isCancelled }) },
             usage: ApplicationUsageSnapshot? = nil) -> ShellResult {
        if control.isCancelled { return ShellResult(status: -2, stdout: "", stderr: tr("general.cancelled")) }
        if self == .dockerAudit || self == .dockerPrune { return DockerMaintenance.run(execute: self == .dockerPrune, control: control, runner: { executor($0, $1, control) }) }
        if let (executable, args) = command {
            guard FileManager.default.isExecutableFile(atPath: executable) else { return ShellResult(status: 127, stdout: "", stderr: tr("maintenance.unsupported")) }
            if self == .permissions {
                let capability = executor("/usr/sbin/diskutil", [], control)
                guard capability.stdout.contains("resetUserPermissions") || capability.stderr.contains("resetUserPermissions") else {
                    return ShellResult(status: 127, stdout: "", stderr: tr("maintenance.unsupported"))
                }
            }
            if requiresAdmin {
                let shell = ([executable] + args).map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
                let literal = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                return executor("/usr/bin/osascript", ["-e", "do shell script \"" + literal + "\" with administrator privileges"], control)
            }
            let result = executor(executable, args, control)
            if self == .preventDSStore && result.status == 0 {
                return executor("/usr/bin/defaults", ["write", "com.apple.desktopservices", "DSDontWriteUSBStores", "-bool", "true"], control)
            }
            return result
        }
        if reviewsFiles {
            let report = MaintenanceFiles.scan(self, home: home, control: control)
            return ShellResult(status: report.complete ? 0 : 1, stdout: (report.entries.map { $0.url.path } + report.issues).joined(separator: "\n"), stderr: "")
        }
        if [.sqlite, .gatekeeper, .notifications, .coreDuet].contains(self) {
            let relative: String
            switch self {
            case .sqlite: relative = "Library/Safari/History.db"
            case .gatekeeper: relative = "Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2"
            case .notifications: relative = "Library/Group Containers/group.com.apple.usernoted/db2/db"
            default: relative = "Library/Application Support/Knowledge/knowledgeC.db"
            }
            let file = home.appendingPathComponent(relative)
            guard PathGlob.exists(file.path) else { return ShellResult(status: 1, stdout: "", stderr: tr("maintenance.unsupported")) }
            let snapshot = usage ?? ApplicationUsageSnapshot.capture(includeApplications: self == .sqlite)
            if self == .sqlite && (snapshot.runningBundleIDs == nil || snapshot.runningBundleIDs!.contains("com.apple.Safari")) {
                return ShellResult(status: 1, stdout: "", stderr: tr("maintenance.database_busy"))
            }
            return MaintenanceDatabase.compact(file, backupRoot: home.appendingPathComponent("Library/Application Support/DevSweep/Backups"),
                usage: snapshot, control: control, deleteOldQuarantine: self == .gatekeeper)
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
