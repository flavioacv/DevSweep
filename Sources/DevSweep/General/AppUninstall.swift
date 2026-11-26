import Foundation

enum AppFileKind: String, Sendable {
    case application, cache, logs, savedState, preferences, support, container, service
    var personal: Bool { self == .preferences || self == .support || self == .container }
    var title: String {
        switch self {
        case .application: tr("uninstall.application")
        case .cache: tr("uninstall.cache")
        case .logs: tr("uninstall.logs")
        case .savedState: tr("uninstall.state")
        case .preferences: tr("uninstall.preferences")
        case .support: tr("uninstall.support")
        case .container: tr("uninstall.container")
        case .service: tr("orphans.service")
        }
    }
}

struct AppAssociation: Sendable {
    let bundleID: String
    let kind: AppFileKind
    var evidence: String { tr("uninstall.evidence", ["id": bundleID]) }
}

struct AppRemovalContext: Sendable {
    let application: URL
    let bundleID: String
    let infoGrant: PathAuthorization
    let inventoryRoots: [URL]
    var relatedData = true

    func validates() -> Bool {
        guard infoGrant.validates(application.appendingPathComponent("Contents/Info.plist")),
              AppUninstall.identifier(application) == bundleID else { return false }
        if !relatedData { return true }
        let inventory = AppUninstall.inventory(roots: inventoryRoots, control: ScanControl())
        return inventory.complete && inventory.apps.filter { $0.value.lowercased() == bundleID.lowercased() }.map(\.key) == [application.path]
    }
}

enum AppUninstall {
    struct Inventory {
        var apps: [String: String] = [:]
        var issues: [String] = []
        var complete = true
    }

    static func identifier(_ application: URL) -> String? {
        let info = application.appendingPathComponent("Contents/Info.plist")
        guard FileIdentity.read(info) != nil,
              let attrs = try? FileManager.default.attributesOfItem(atPath: info.path),
              (attrs[.size] as? NSNumber)?.intValue ?? Int.max < 2_000_000,
              let data = try? Data(contentsOf: info),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let id = plist["CFBundleIdentifier"] as? String,
              id.count <= 200, id.contains("."), !id.contains(".."), !id.hasPrefix("."), !id.hasSuffix("."),
              id.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-").contains($0) }) else { return nil }
        return id
    }

    static func inventory(roots: [URL], control: ScanControl) -> Inventory {
        var result = Inventory()
        for root in Set(roots) {
            do { _ = try FileManager.default.attributesOfItem(atPath: root.path) }
            catch let error as NSError {
                if error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { continue }
                result.complete = false; result.issues.append(root.path); continue
            }
            let walk = DirectoryWalker.walk(root, depth: 2, control: control, limit: 5000, seconds: 10, reportDepthLimit: true)
            result.complete = result.complete && walk.complete; result.issues += walk.issues
            for app in walk.directories where app.pathExtension.lowercased() == "app" {
                guard let id = identifier(app) else { result.complete = false; result.issues.append(app.path); continue }
                result.apps[app.path] = id
            }
        }
        return result
    }

    static func scan(application: URL, home: URL, control: ScanControl, roots: [URL]? = nil) -> GeneralReport {
        guard let id = identifier(application), !id.lowercased().hasPrefix("com.apple."),
              let grant = PathAuthorization.issue(application.appendingPathComponent("Contents/Info.plist"), within: application) else {
            return GeneralReport(issues: [tr("uninstall.unverified")], complete: false)
        }
        let roots = roots ?? [URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/System/Applications"), home.appendingPathComponent("Applications"), application.deletingLastPathComponent()]
        let installed = inventory(roots: roots, control: control)
        let soleOwner = installed.complete && installed.apps.filter { $0.value.lowercased() == id.lowercased() }.map(\.key) == [application.path]
        let context = AppRemovalContext(application: application, bundleID: id, infoGrant: grant, inventoryRoots: roots)
        var report = GeneralReport(issues: installed.issues, complete: installed.complete)
        if !soleOwner { report.issues.append(tr("uninstall.shared")) }
        var app = GeneralScanner.entry(application, root: application.deletingLastPathComponent(), area: .applications, home: home).target
        app.requiresAppsClosed = [id]
        var appContext = context; appContext.relatedData = false; app.appRemovalContext = appContext
        report.entries = [GeneralEntry(target: app, modified: PathGlob.modificationDate(application), association: AppAssociation(bundleID: id, kind: .application))]
        let locations: [(String, AppFileKind)] = [
            ("Caches/" + id, .cache), ("Logs/" + id, .logs), ("Saved Application State/" + id + ".savedState", .savedState),
            ("Preferences/" + id + ".plist", .preferences), ("Application Support/" + id, .support), ("Containers/" + id, .container)
        ]
        for (relative, kind) in locations {
            if control.isCancelled { report.complete = false; report.issues.append(tr("general.cancelled")); break }
            let file = home.appendingPathComponent("Library/" + relative)
            do { _ = try FileManager.default.attributesOfItem(atPath: file.path) }
            catch let error as NSError {
                if error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { continue }
                report.complete = false; report.issues.append(file.path); continue
            }
            report.inspected += 1
            var target = GeneralScanner.entry(file, root: home.appendingPathComponent("Library"), area: .applications, home: home).target
            target.requiresAppsClosed = [id]; target.appRemovalContext = context
            if kind == .preferences { target.pathRules[file.path] = PathSpec(glob: file.path, filesOnly: true) }
            if !soleOwner || kind == .container { target.pathAuthorizations = [:] }
            report.entries.append(GeneralEntry(target: target, modified: PathGlob.modificationDate(file), association: AppAssociation(bundleID: id, kind: kind)))
        }
        return report
    }
}
