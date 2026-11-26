import Foundation

struct ConfigReference: Codable, Identifiable, Sendable {
    let path: String
    let line: Int
    let kind: String
    var id: String { path + ":" + String(line) }
}

/// Reports locations only. Config contents, environment values and matching lines never leave this scanner.
enum ConfigReferences {
    struct Result: Sendable {
        var references: [ConfigReference] = []
        var issues: [String] = []
        var complete = true
    }
    static func scan(home: URL, application: URL, bundleID: String, control: ScanControl) -> Result {
        let shells = [".zshrc", ".zprofile", ".zshenv", ".bashrc", ".bash_profile", ".profile", ".config/fish/config.fish"]
        let configs = [".claude.json", ".cursor/mcp.json", ".vscode/mcp.json", ".config/Code/User/mcp.json",
                       "Library/Application Support/Code/User/mcp.json", "Library/Application Support/Claude/claude_desktop_config.json", ".codex/config.toml"]
        var result = Result()
        let tokens = [bundleID, application.path]
        let expressions = tokens.compactMap { token in
            try? NSRegularExpression(pattern: "(?<![A-Za-z0-9_./-])" + NSRegularExpression.escapedPattern(for: token) + "(?![A-Za-z0-9_.-])")
        }
        for relative in shells + configs {
            if control.isCancelled { result.complete = false; break }
            let file = home.appendingPathComponent(relative)
            do {
                let attributes: [FileAttributeKey: Any]
                do { attributes = try FileManager.default.attributesOfItem(atPath: file.path) }
                catch let error as NSError where error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { continue }
                guard FileIdentity.read(file) != nil, !FileFootprint.isDataless(file), attributes[.type] as? FileAttributeType == .typeRegular,
                      (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 524_288 else { throw CocoaError(.fileReadUnknown) }
                let handle = try FileHandle(forReadingFrom: file)
                defer { try? handle.close() }
                guard let data = try handle.read(upToCount: 524_289), data.count <= 524_288,
                      let contents = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadUnknown) }
                let lines = contents.components(separatedBy: .newlines)
                if lines.count > 8192 { result.complete = false; result.issues.append(file.path) }
                for (index, line) in lines.prefix(8192).enumerated() {
                    if control.isCancelled || result.references.count >= 1024 { result.complete = false; break }
                    if expressions.contains(where: { $0.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil }) {
                        result.references.append(ConfigReference(path: file.path, line: index + 1, kind: shells.contains(relative) ? "shell" : "mcp_config"))
                    }
                }
            } catch { result.complete = false; result.issues.append(file.path) }
        }
        return result
    }
}
