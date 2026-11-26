import Darwin
import Foundation

struct ServiceRemovalContext: Sendable {
    let label: String
    let executable: String
    func validates(probe: (String, [String]) -> ShellResult = { Shell.run($0, $1, timeout: 5) }) -> Bool {
        guard label.range(of: #"^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$"#, options: .regularExpression) != nil,
              executable.hasPrefix("/"), !FileManager.default.fileExists(atPath: executable) else { return false }
        // A service can be registered outside the GUI domain too. Unknown/denied domains preserve it.
        return ["gui/\(getuid())", "user/\(getuid())", "system"].allSatisfy { domain in
            let result = probe("/bin/launchctl", ["print", domain + "/" + label])
            return result.status != 0 && (result.stderr + result.stdout).contains("Could not find service")
        }
    }
}
