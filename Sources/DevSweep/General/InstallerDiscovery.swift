import Foundation

enum InstallerSource: String, Sendable {
    case downloads, desktop, homebrew, icloud, mail, telegram, firmware, custom
    var title: String {
        switch self {
        case .downloads: tr("installer.downloads")
        case .desktop: tr("installer.desktop")
        case .homebrew: "Homebrew"
        case .icloud: "iCloud"
        case .mail: "Mail"
        case .telegram: "Telegram"
        case .firmware: tr("installer.firmware")
        case .custom: tr("installer.custom")
        }
    }
}

enum InstallerDiscovery {
    static func scan(home: URL, selectedRoot: URL?, control: ScanControl) -> GeneralReport {
        let sources: [(URL, InstallerSource)] = selectedRoot.map { [($0, .custom)] } ?? [
            (home.appendingPathComponent("Downloads"), .downloads), (home.appendingPathComponent("Desktop"), .desktop),
            (home.appendingPathComponent("Library/Caches/Homebrew/downloads"), .homebrew),
            (home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Downloads"), .icloud),
            (home.appendingPathComponent("Library/Containers/com.apple.mail/Data/Library/Mail Downloads"), .mail),
            (home.appendingPathComponent("Library/Mail Downloads"), .mail),
            (home.appendingPathComponent("Downloads/Telegram Desktop"), .telegram),
            (home.appendingPathComponent("Library/iTunes/iPhone Software Updates"), .firmware),
            (home.appendingPathComponent("Library/iTunes/iPad Software Updates"), .firmware),
            (home.appendingPathComponent("Library/iTunes/iPod Software Updates"), .firmware)
        ]
        var report = GeneralReport()
        var seen = Set<String>()
        // Specific origins precede a covering Downloads walk so Telegram has a useful source label.
        for (root, source) in sources.sorted(by: { $0.0.path.count > $1.0.path.count }) {
            if control.isCancelled { report.complete = false; report.issues.append(tr("general.cancelled")); break }
            do { _ = try FileManager.default.attributesOfItem(atPath: root.path) }
            catch let error as NSError {
                if error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { continue }
                report.complete = false; report.issues.append("\(root.path): \(error.localizedDescription)"); continue
            }
            if FileFootprint.isDataless(root) { report.issues.append(tr("installer.online_only", ["path": root.path])); continue }
            let walk = DirectoryWalker.walk(root, depth: 4, control: control, pruneNames: ["node_modules", ".git"], reportDepthLimit: true)
            report.complete = report.complete && walk.complete; report.issues += walk.issues; report.inspected += walk.visited
            for file in walk.files {
                if control.isCancelled { report.complete = false; break }
                let ext = file.pathExtension.lowercased()
                let firmware = ext == "ipsw" && InstallerArchive.containsFirmware(file)
                let recognized = ["dmg", "pkg", "mpkg", "iso", "xip", "ipa", "apk", "aab", "apks"].contains(ext)
                    || (ext == "zip" && InstallerArchive.containsInstaller(file)) || firmware
                guard recognized, seen.insert(file.path).inserted else { continue }
                if source == .firmware {
                    guard firmware, let date = PathGlob.modificationDate(file), date < Date().addingTimeInterval(-30 * 86400) else { continue }
                }
                var entry = GeneralScanner.entry(file, root: root, area: .installers, home: home, age: source == .firmware ? 30 : nil)
                var target = entry.target
                if firmware { target.requiresToolsIdle = ["ampdevicesagent", "mobiledeviceupdater", "cfgutil"] }
                if source == .mail || source == .icloud || managed(file, home: home) { target.pathAuthorizations = [:] }
                entry = GeneralEntry(target: target, modified: entry.modified, installerSource: source)
                report.entries.append(entry)
            }
        }
        return report
    }

    static func managed(_ file: URL, home: URL) -> Bool {
        ["Library/Mobile Documents", "Library/CloudStorage", "Library/Mail", "Library/Mail Downloads", "Library/Containers", "Library/Group Containers"].contains {
            let root = home.appendingPathComponent($0).path.lowercased()
            return file.path.lowercased() == root || file.path.lowercased().hasPrefix(root + "/")
        }
    }
}
