import Foundation

/// Scaffolds Blitz-managed Teenybase backend files into projects.
struct ProjectTeenybaseScaffolder {
    let baseDirectory: URL

    func ensureTeenybaseBackend(projectId: String, projectType: ProjectType) {
        let fm = FileManager.default
        let projectDir = baseDirectory.appendingPathComponent(projectId)

        guard let templateURL = Bundle.appResources.url(
            forResource: "rn-notes-template",
            withExtension: nil,
            subdirectory: "templates"
        ) else {
            print("[ProjectTeenybaseScaffolder] Teenybase template not found in bundle")
            return
        }

        switch projectType {
        case .reactNative:
            copyTeenybaseFiles(from: templateURL, to: projectDir, fm: fm)
            mergeTeenybaseScripts(into: projectDir.appendingPathComponent("package.json"), fm: fm)
        case .swift, .flutter:
            let backendDir = projectDir.appendingPathComponent("backend")
            try? fm.createDirectory(at: backendDir, withIntermediateDirectories: true)
            copyTeenybaseFiles(from: templateURL, to: backendDir, fm: fm)
            ensureStandalonePackageJson(
                at: backendDir.appendingPathComponent("package.json"),
                projectId: projectId,
                fm: fm
            )
        }
    }

    /// Copies backend files into `dest` and never overwrites an existing setup.
    private func copyTeenybaseFiles(from templateURL: URL, to dest: URL, fm: FileManager) {
        let teenybaseDest = dest.appendingPathComponent("teenybase.ts")
        guard !fm.fileExists(atPath: teenybaseDest.path) else { return }

        try? fm.copyItem(at: templateURL.appendingPathComponent("teenybase.ts"), to: teenybaseDest)

        let wranglerDest = dest.appendingPathComponent("wrangler.toml")
        if !fm.fileExists(atPath: wranglerDest.path) {
            let src = templateURL.appendingPathComponent("wrangler.toml")
            if var content = try? String(contentsOf: src, encoding: .utf8) {
                let appName = resolvedProjectName(for: dest)
                content = content.replacingOccurrences(of: "sample-app", with: appName)
                try? content.write(to: wranglerDest, atomically: true, encoding: .utf8)
            }
        }

        let srcBackendDest = dest.appendingPathComponent("src-backend")
        try? fm.createDirectory(at: srcBackendDest, withIntermediateDirectories: true)
        let workerDest = srcBackendDest.appendingPathComponent("worker.ts")
        if !fm.fileExists(atPath: workerDest.path) {
            try? fm.copyItem(
                at: templateURL.appendingPathComponent("src-backend/worker.ts"),
                to: workerDest
            )
        }

        let devVarsDest = dest.appendingPathComponent(".dev.vars")
        if !fm.fileExists(atPath: devVarsDest.path) {
            let sampleVars = templateURL.appendingPathComponent("sample.vars")
            if fm.fileExists(atPath: sampleVars.path) {
                try? fm.copyItem(at: sampleVars, to: devVarsDest)
            }
        }
    }

    private func mergeTeenybaseScripts(into packageJsonURL: URL, fm: FileManager) {
        guard fm.fileExists(atPath: packageJsonURL.path),
              let data = try? Data(contentsOf: packageJsonURL),
              var pkg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        var devDeps = pkg["devDependencies"] as? [String: Any] ?? [:]
        guard devDeps["teenybase"] == nil else { return }

        devDeps["teenybase"] = "0.0.10"
        pkg["devDependencies"] = devDeps

        var scripts = pkg["scripts"] as? [String: Any] ?? [:]
        let backendScripts: [String: String] = [
            "generate:backend": "teeny generate --local",
            "migrate:backend": "teeny migrate --local",
            "dev:backend": "teeny dev --local",
            "build:backend": "teeny build --local",
            "exec:backend": "teeny exec --local",
            "deploy:backend:remote": "teeny deploy --migrate --remote",
        ]
        for (key, value) in backendScripts where scripts[key] == nil {
            scripts[key] = value
        }
        pkg["scripts"] = scripts

        if let updated = try? JSONSerialization.data(withJSONObject: pkg, options: [.prettyPrinted, .sortedKeys]) {
            try? updated.write(to: packageJsonURL)
        }
    }

    private func ensureStandalonePackageJson(at url: URL, projectId: String, fm: FileManager) {
        guard !fm.fileExists(atPath: url.path) else { return }
        let content = """
        {
          "name": "\(projectId)-backend",
          "version": "1.0.0",
          "scripts": {
            "generate": "teeny generate --local",
            "migrate": "teeny migrate --local",
            "dev": "teeny dev --local",
            "build": "teeny build --local",
            "exec": "teeny exec --local",
            "deploy": "teeny deploy --migrate --remote"
          },
          "devDependencies": {
            "teenybase": "0.0.10"
          }
        }
        """
        try? content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func resolvedProjectName(for destination: URL) -> String {
        destination.lastPathComponent == "backend"
            ? destination.deletingLastPathComponent().lastPathComponent
            : destination.lastPathComponent
    }
}
