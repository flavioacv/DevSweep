import XCTest
import Yams
@testable import DevSweep

/// Exercises the real bundled globs against disposable profiles with personal-data decoys.
final class MacCleanupScopeTests: XCTestCase {
    private var root: URL!
    private var definitions: [StorageDefinition] = []
    private let now = Date()

    override func setUpWithError() throws {
        root = try TestSupport.temporaryDirectory().resolvingSymlinksInPath()
        let yaml = try String(contentsOf: TestSupport.stacksDirectory.appendingPathComponent("mac.yaml"), encoding: .utf8)
        // Decode the same rules with a fixture home. Production loader still rejects absolute paths.
        definitions = try YAMLDecoder().decode(StackFile.self, from: yaml.replacingOccurrences(of: "~/", with: root.path + "/")).storage ?? []
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    private func make(_ relative: String, directory: Bool = false, days: Int = 40) throws -> URL {
        let path = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: directory ? path : path.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !directory { try "fixture".write(to: path, atomically: true, encoding: .utf8) }
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-Double(days) * 86_400)], ofItemAtPath: path.path)
        return path
    }

    private func paths(_ id: String) throws -> Set<String> {
        let definition = try XCTUnwrap(definitions.first { $0.id == id })
        return Set((definition.paths ?? []).flatMap { PathResolver.resolve($0, now: now) }.map(\.path))
    }

    func testFirefoxOnlySelectsHTTPDiskCachesAndKeepsPersistentProfiles() throws {
        let first = try make("Library/Caches/Firefox/Profiles/one.default/cache2", directory: true)
        let second = try make("Library/Caches/Firefox/Profiles/two.work/cache2", directory: true)
        for path in ["Library/Caches/Firefox/Profiles/one.default/startupCache",
                     "Library/Caches/Firefox/Profiles/one.default/cache2-backup",
                     "Library/Application Support/Firefox/Profiles/one.default/cookies.sqlite",
                     "Library/Application Support/Firefox/Profiles/one.default/logins.json",
                     "Library/Application Support/Firefox/Profiles/one.default/places.sqlite",
                     "custom-profile/cache2"] {
            try make(path)
        }
        XCTAssertEqual(try paths("mac-firefox-cache"), [first.path, second.path])
    }

    func testDiscordOnlySelectsNamedCachesAndKeepsSessionsModulesAndOtherChannels() throws {
        let base = "Library/Application Support/discord/"
        var expected = Set<URL>()
        for name in ["Cache", "Code Cache", "GPUCache"] {
            expected.insert(try make(base + name, directory: true))
        }
        for name in ["Local Storage/data", "Session Storage/data", "Network/Cookies", "settings.json",
                     "modules/installed.json", "partitions/work/Cache", "Cache-backup"] {
            try make(base + name)
        }
        try make("Library/Application Support/discordcanary/Cache", directory: true)
        XCTAssertEqual(try paths("mac-discord-cache"), Set(expected.map(\.path)))
    }

    func testDiscordLogsExcludeRecentFilesArchivesDirectoriesLinksAndNestedTrees() throws {
        let base = "Library/Application Support/discord/"
        let first = try make(base + "debug.log")
        let second = try make(base + "logs/updater.log")
        try make(base + "logs/recent.log", days: 1)
        try make(base + "logs/archive.zip")
        try make(base + "settings.json")
        try make(base + "logs/folder.log", directory: true)
        try make(base + "logs/nested/other.log")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(base + "logs/link.log"), withDestinationURL: first)
        XCTAssertEqual(try paths("mac-discord-old-logs"), [first.path, second.path])
    }

    func testZoomLogsKeepRecordingsChatDataArchivesAndNestedLogs() throws {
        let base = "Library/Logs/zoom.us/"
        let old = try make(base + "troubleshooting.log")
        try make(base + "recent.log", days: 1)
        try make(base + "ticket.zip")
        try make(base + "folder.log", directory: true)
        try make(base + "nested/other.log")
        try make("Documents/Zoom/meeting/recording.mp4")
        try make("Documents/Zoom/meeting/chat.txt")
        try make("Library/Application Support/zoom.us/settings.log")
        try make("System/Library/Logs/zoom.us/system.log")
        XCTAssertEqual(try paths("mac-zoom-old-logs"), [old.path])
    }
}
