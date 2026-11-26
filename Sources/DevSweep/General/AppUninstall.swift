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
    var jetbrainsSelector: String? = nil
    var relatedData = true

    func validates() -> Bool {
        guard infoGrant.validates(application.appendingPathComponent("Contents/Info.plist")),
              AppUninstall.identifier(application) == bundleID,
              AppUninstall.jetbrainsSelector(application) == jetbrainsSelector else { return false }
        if !relatedData { return true }
        let inventory = AppUninstall.inventory(roots: inventoryRoots, control: ScanControl())
        return AppUninstall.isSoleOwner(application: application, bundleID: bundleID, jetbrainsSelector: jetbrainsSelector, inventory: inventory)
    }
}

enum AppUninstall {
    struct Inventory {
        var apps: [String: String] = [:]
        var selectors: [String: String] = [:]
        var issues: [String] = []
        var complete = true
    }

    private static let protectedSupportFolders: Set<String> = [
        "steam", "crossover", "openemu", "dolphin", "retroarch", "prismlauncher", "minecraft", "virtualbuddy"
    ]
    private static let protectedBundleIDs: Set<String> = [
        "com.valvesoftware.steam", "com.utmapp.utm"
    ]

    static func isProtectedDataRoot(_ url: URL, bundleID: String, kind: AppFileKind) -> Bool {
        if kind == .container { return true }
        if kind == .support {
            let folder = url.lastPathComponent.lowercased()
            if protectedSupportFolders.contains(folder) || protectedBundleIDs.contains(bundleID.lowercased()) {
                return true
            }
        }
        return false
    }

    static func infoPlist(_ application: URL) -> [String: Any]? {
        let info = application.appendingPathComponent("Contents/Info.plist")
        guard FileIdentity.read(info) != nil,
              let attrs = try? FileManager.default.attributesOfItem(atPath: info.path),
              (attrs[.size] as? NSNumber)?.intValue ?? Int.max < 2_000_000,
              let data = try? Data(contentsOf: info),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return plist
    }

    static func identifier(_ application: URL) -> String? {
        guard let plist = infoPlist(application),
              let id = plist["CFBundleIdentifier"] as? String,
              id.count <= 200, id.contains("."), !id.contains(".."), !id.hasPrefix("."), !id.hasSuffix("."),
              id.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-").contains($0) }) else { return nil }
        return id
    }

    /// Reads `JVMOptions.Properties["idea.paths.selector"]` for JetBrains / Android Studio bundles.
    static func jetbrainsSelector(_ application: URL) -> String? {
        guard let plist = infoPlist(application),
              let jvm = plist["JVMOptions"] as? [String: Any],
              let props = jvm["Properties"] as? [String: Any],
              let selector = props["idea.paths.selector"] as? String,
              !selector.isEmpty, selector.count <= 80, !selector.contains(".."), !selector.hasPrefix("."),
              selector.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-").contains($0) }) else { return nil }
        return selector
    }

    static func isSoleOwner(application: URL, bundleID: String, jetbrainsSelector: String?, inventory: Inventory) -> Bool {
        guard inventory.complete else { return false }
        let sameID = inventory.apps.filter { $0.value.lowercased() == bundleID.lowercased() }.map(\.key)
        guard sameID == [application.path] else { return false }
        if let selector = jetbrainsSelector?.lowercased() {
            let sameSelector = inventory.selectors.filter { $0.value.lowercased() == selector }.map(\.key)
            guard sameSelector == [application.path] else { return false }
        }
        return true
    }

    static func matchingUUIDContainers(bundleID: String, home: URL, control: ScanControl) -> [URL] {
        let containers = home.appendingPathComponent("Library/Containers")
        guard let items = try? FileManager.default.contentsOfDirectory(at: containers, includingPropertiesForKeys: nil) else { return [] }
        var matched: [URL] = []
        for item in items {
            if control.isCancelled { break }
            guard UUID(uuidString: item.lastPathComponent) != nil,
                  FileIdentity.read(item) != nil else { continue }
            let meta = item.appendingPathComponent(".com.apple.containermanagerd.metadata.plist")
            guard FileIdentity.read(meta) != nil,
                  let attrs = try? FileManager.default.attributesOfItem(atPath: meta.path),
                  (attrs[.size] as? NSNumber)?.intValue ?? Int.max < 65_536,
                  let data = try? Data(contentsOf: meta),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let metaID = plist["MCMMetadataIdentifier"] as? String,
                  metaID.lowercased() == bundleID.lowercased() else { continue }
            matched.append(URL(fileURLWithPath: item.standardizedFileURL.path))
        }
        return matched.sorted { $0.path < $1.path }
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
                if let selector = jetbrainsSelector(app) { result.selectors[app.path] = selector }
            }
        }
        return result
    }

    static func scan(application: URL, home: URL, control: ScanControl, roots: [URL]? = nil) -> GeneralReport {
        guard let id = identifier(application), !id.lowercased().hasPrefix("com.apple."),
              let grant = PathAuthorization.issue(application.appendingPathComponent("Contents/Info.plist"), within: application) else {
            return GeneralReport(issues: [tr("uninstall.unverified")], complete: false)
        }
        let selector = jetbrainsSelector(application)
        let roots = roots ?? [URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/System/Applications"), home.appendingPathComponent("Applications"), application.deletingLastPathComponent()]
        let installed = inventory(roots: roots, control: control)
        let soleOwner = isSoleOwner(application: application, bundleID: id, jetbrainsSelector: selector, inventory: installed)
        let context = AppRemovalContext(application: application, bundleID: id, infoGrant: grant, inventoryRoots: roots, jetbrainsSelector: selector)
        var report = GeneralReport(issues: installed.issues, complete: installed.complete)
        if !soleOwner { report.issues.append(tr("uninstall.shared")) }
        var app = GeneralScanner.entry(application, root: application.deletingLastPathComponent(), area: .applications, home: home).target
        app.requiresAppsClosed = [id]
        var appContext = context; appContext.relatedData = false; app.appRemovalContext = appContext
        report.entries = [GeneralEntry(target: app, modified: PathGlob.modificationDate(application), association: AppAssociation(bundleID: id, kind: .application))]
        var locations: [(String, AppFileKind)] = [
            ("Caches/" + id, .cache),
            ("Caches/" + id + ".ShipIt", .cache),
            ("HTTPStorages/" + id, .cache),
            ("WebKit/" + id, .cache),
            ("Logs/" + id, .logs),
            ("Saved Application State/" + id + ".savedState", .savedState),
            ("Preferences/" + id + ".plist", .preferences),
            ("Application Support/" + id, .support),
            ("Containers/" + id, .container)
        ]
        if let selector, (id.lowercased().hasPrefix("com.jetbrains.") || id.lowercased().hasPrefix("com.google.android.studio")) {
            locations += [
                ("Caches/JetBrains/" + selector, .cache),
                ("Logs/JetBrains/" + selector, .logs),
                ("Application Support/JetBrains/" + selector, .support)
            ]
        }
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
            if !soleOwner || isProtectedDataRoot(file, bundleID: id, kind: kind) { target.pathAuthorizations = [:] }
            report.entries.append(GeneralEntry(target: target, modified: PathGlob.modificationDate(file), association: AppAssociation(bundleID: id, kind: kind)))
        }
        for container in matchingUUIDContainers(bundleID: id, home: home, control: control) {
            report.inspected += 1
            var target = GeneralScanner.entry(container, root: home.appendingPathComponent("Library"), area: .applications, home: home).target
            target.requiresAppsClosed = [id]; target.appRemovalContext = context
            target.pathAuthorizations = [:]
            report.entries.append(GeneralEntry(target: target, modified: PathGlob.modificationDate(container), association: AppAssociation(bundleID: id, kind: .container)))
        }
        let references = ConfigReferences.scan(home: home, application: application, bundleID: id, control: control)
        report.references = references.references; report.referencesComplete = references.complete; report.referenceIssues = references.issues
        return report
    }
}
