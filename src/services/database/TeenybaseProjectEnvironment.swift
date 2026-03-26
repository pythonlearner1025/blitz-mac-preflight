import Foundation

enum TeenybaseProjectEnvironment {
    static func adminToken(projectPath: String) -> String? {
        readDevVar("ADMIN_SERVICE_TOKEN", projectPath: projectPath)
    }

    static func environment(
        projectPath: String,
        port: Int,
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var env = base
        let localBin = projectPath + "/node_modules/.bin"
        if let existingPath = env["PATH"] {
            env["PATH"] = localBin + ":" + existingPath
        } else {
            env["PATH"] = localBin
        }

        env["TEENY_DEV_PORT"] = String(port)
        env["WRANGLER_SEND_METRICS"] = "false"

        for (key, value) in loadDevVars(projectPath: projectPath) {
            env[key] = value
        }
        return env
    }

    static func readDevVar(_ key: String, projectPath: String) -> String? {
        loadDevVars(projectPath: projectPath)[key]
    }

    static func loadDevVars(projectPath: String) -> [String: String] {
        let path = projectPath + "/.dev.vars"
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }

        var values: [String: String] = [:]
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }

            let parts = trimmed.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }

            let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
            let value = String(parts[1]).trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            values[key] = value
        }
        return values
    }
}
