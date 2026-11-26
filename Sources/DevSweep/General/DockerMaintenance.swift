import Foundation

enum DockerMaintenance {
    static func run(execute: Bool, control: ScanControl, environment: [String: String] = ProcessInfo.processInfo.environment,
                    runner: (String, [String]) -> ShellResult = { Shell.run($0, $1, timeout: 30) }) -> ShellResult {
        func denied() -> ShellResult { ShellResult(status: 1, stdout: "", stderr: tr("docker.local_only")) }
        if control.isCancelled { return ShellResult(status: -2, stdout: "", stderr: tr("general.cancelled")) }
        if let host = environment["DOCKER_HOST"], !host.isEmpty, !host.hasPrefix("unix://") { return denied() }
        let current = runner("docker", ["context", "show"])
        let context = current.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard current.status == 0, !context.isEmpty, context.count < 200 else { return denied() }
        let endpoint = runner("docker", ["context", "inspect", context, "--format", "{{json .Endpoints.docker.Host}}"])
        guard endpoint.status == 0, let data = endpoint.stdout.data(using: .utf8),
              let host = try? JSONDecoder().decode(String.self, from: data), host.hasPrefix("unix:///") else { return denied() }
        let prefix = ["--context", context]
        let info = runner("docker", prefix + ["info", "--format", "{{.ID}}"])
        guard info.status == 0, !info.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return denied() }
        if !execute { return runner("docker", prefix + ["system", "df"]) }
        let inspect = runner("docker", prefix + ["buildx", "inspect", "--format", "{{json .}}"])
        guard inspect.status == 0, let json = inspect.stdout.data(using: .utf8),
              let builder = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              builder["Driver"] as? String == "docker", let name = builder["Name"] as? String, !name.isEmpty,
              let nodes = builder["Nodes"] as? [[String: Any]], nodes.count == 1,
              let node = nodes[0]["Endpoint"] as? String, node == context || node == host else { return denied() }
        let fresh = runner("docker", prefix + ["info", "--format", "{{.ID}}"])
        guard !control.isCancelled, fresh.status == 0, fresh.stdout == info.stdout else { return denied() }
        let build = runner("docker", prefix + ["buildx", "prune", "--builder", name, "--force", "--filter", "until=168h"])
        guard build.status == 0 else { return build }
        if control.isCancelled { return ShellResult(status: -2, stdout: build.stdout, stderr: tr("general.cancelled")) }
        let remainingEngine = runner("docker", prefix + ["info", "--format", "{{.ID}}"])
        guard remainingEngine.status == 0, remainingEngine.stdout == info.stdout else {
            return ShellResult(status: 1, stdout: build.stdout, stderr: tr("docker.partial"))
        }
        let images = runner("docker", prefix + ["image", "prune", "--force", "--filter", "until=168h"])
        return ShellResult(status: images.status, stdout: build.stdout + "\n" + images.stdout, stderr: build.stderr + "\n" + images.stderr)
    }
}
