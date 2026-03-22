import Foundation

/// Filesystem operations for ~/.blitz/projects/
struct ProjectStorage {
    let baseDirectory: URL

    init() {
        self.baseDirectory = BlitzPaths.projects
    }

    /// List all projects in ~/.blitz/projects/
    func listProjects() async -> [Project] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: baseDirectory, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return []
        }

        var projects: [Project] = []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for entry in entries {
            // fileExists(atPath:isDirectory:) follows symlinks;
            // isDirectoryKey does NOT, so symlinked project dirs would be skipped.
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue else { continue }

            let metadataFile = entry.appendingPathComponent(".blitz/project.json")
            guard let data = try? Data(contentsOf: metadataFile),
                  let metadata = try? decoder.decode(BlitzProjectMetadata.self, from: data) else {
                continue
            }

            let project = Project(
                id: entry.lastPathComponent,
                metadata: metadata,
                path: entry.path
            )
            projects.append(project)
        }

        return projects.sorted { ($0.metadata.lastOpenedAt ?? .distantPast) > ($1.metadata.lastOpenedAt ?? .distantPast) }
    }

    /// Read a specific project's metadata
    func readMetadata(projectId: String) -> BlitzProjectMetadata? {
        let metadataFile = baseDirectory
            .appendingPathComponent(projectId)
            .appendingPathComponent(".blitz/project.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: metadataFile) else { return nil }
        return try? decoder.decode(BlitzProjectMetadata.self, from: data)
    }

    /// Write project metadata into ~/.blitz/projects/{id}/.blitz/project.json
    func writeMetadata(projectId: String, metadata: BlitzProjectMetadata) throws {
        let projectDir = baseDirectory.appendingPathComponent(projectId)
        try writeMetadataToDirectory(projectDir, metadata: metadata)
    }

    /// Write project metadata into an arbitrary directory (e.g. the original project path before symlinking).
    func writeMetadataToDirectory(_ dir: URL, metadata: BlitzProjectMetadata) throws {
        let blitzDir = dir.appendingPathComponent(".blitz")
        try FileManager.default.createDirectory(at: blitzDir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(metadata)
        try data.write(to: blitzDir.appendingPathComponent("project.json"))
    }

    /// Delete a project directory
    func deleteProject(projectId: String) throws {
        let projectDir = baseDirectory.appendingPathComponent(projectId)
        let path = projectDir.path
        // Check if this is a symlink — if so, only remove the symlink itself, not the target
        var isSymlink = false
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           attrs[.type] as? FileAttributeType == .typeSymbolicLink {
            isSymlink = true
        }
        if isSymlink {
            // unlink only removes the symlink, not the target directory
            unlink(path)
        } else {
            try FileManager.default.removeItem(at: projectDir)
        }
    }

    /// Open a project at the given URL. Validates .blitz/project.json exists,
    /// registers it in ~/.blitz/projects/ if needed, and returns the projectId.
    func openProject(at url: URL) throws -> String {
        let metadataFile = url.appendingPathComponent(".blitz/project.json")
        guard FileManager.default.fileExists(atPath: metadataFile.path) else {
            throw ProjectOpenError.notABlitzProject
        }

        var folderName = url.lastPathComponent
        let existingDir = baseDirectory.appendingPathComponent(folderName)

        if FileManager.default.fileExists(atPath: existingDir.path) {
            // Check if it resolves to the same location
            let resolvedExisting = existingDir.resolvingSymlinksInPath().path
            let resolvedNew = url.resolvingSymlinksInPath().path
            if resolvedExisting == resolvedNew {
                updateLastOpened(projectId: folderName)
                return folderName
            }
            // Name collision with different project — disambiguate
            var counter = 2
            while FileManager.default.fileExists(
                atPath: baseDirectory.appendingPathComponent("\(folderName)-\(counter)").path
            ) { counter += 1 }
            folderName = "\(folderName)-\(counter)"
        }

        // Create symlink: ~/.blitz/projects/{folderName} → selectedPath
        let symlinkDir = baseDirectory.appendingPathComponent(folderName)
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: symlinkDir, withDestinationURL: url)

        updateLastOpened(projectId: folderName)
        return folderName
    }

    /// Update lastOpenedAt timestamp for a project
    func updateLastOpened(projectId: String) {
        guard var metadata = readMetadata(projectId: projectId) else { return }
        metadata.lastOpenedAt = Date()
        do {
            try writeMetadata(projectId: projectId, metadata: metadata)
        } catch {
            print("[ProjectStorage] Failed to update lastOpenedAt for \(projectId): \(error)")
        }
    }

    /// Ensure .mcp.json contains blitz-macos and blitz-iphone MCP server entries.
    /// If the file exists, merges into the existing mcpServers key without overwriting other entries.
    /// If it doesn't exist, creates it.
    func ensureMCPConfig(projectId: String) {
        let projectDir = baseDirectory.appendingPathComponent(projectId)
        let mcpFile = projectDir.appendingPathComponent(".mcp.json")
        let bridgePath = BlitzPaths.mcpBridge.path

        let blitzMacosEntry: [String: Any] = [
            "command": "bash",
            "args": [bridgePath]
        ]
        // Use full path to npx from Blitz's bundled Node.js runtime.
        // Also set PATH env so that #!/usr/bin/env node resolves correctly —
        // npx and the packages it runs use env shebang lookups.
        let nodeRuntimeBin = BlitzPaths.nodeDir.path
        let blitzIphoneEntry: [String: Any] = [
            "command": nodeRuntimeBin + "/npx",
            "args": ["-y", "@blitzdev/iphone-mcp"],
            "env": [
                "PATH": "\(nodeRuntimeBin):/usr/bin:/bin:/usr/sbin:/sbin"
            ]
        ]

        var root: [String: Any]
        if let data = try? Data(contentsOf: mcpFile),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = existing
            var servers = root["mcpServers"] as? [String: Any] ?? [:]
            servers["blitz-macos"] = blitzMacosEntry
            servers["blitz-iphone"] = blitzIphoneEntry
            root["mcpServers"] = servers
        } else {
            root = ["mcpServers": [
                "blitz-macos": blitzMacosEntry,
                "blitz-iphone": blitzIphoneEntry
            ]]
        }

        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) else { return }
        do {
            try data.write(to: mcpFile)
        } catch {
            print("[ProjectStorage] Failed to write .mcp.json: \(error)")
        }
    }

    /// Ensure CLAUDE.md, .claude/settings.local.json, and .claude/rules/ exist for a project.
    func ensureClaudeFiles(projectId: String, projectType: ProjectType) {
        let fm = FileManager.default
        let projectDir = baseDirectory.appendingPathComponent(projectId)
        let claudeDir = projectDir.appendingPathComponent(".claude")

        // 1. .claude/settings.local.json
        // Always update enabledMcpjsonServers (Blitz-owned structural setting).
        let settingsFile = claudeDir.appendingPathComponent("settings.local.json")
        try? fm.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let correctServers = ["blitz-macos", "blitz-iphone"]
        var settings: [String: Any]
        if fm.fileExists(atPath: settingsFile.path),
           let data = try? Data(contentsOf: settingsFile),
           var existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // Preserve user customisations; only force-update the server list
            existing["enabledMcpjsonServers"] = correctServers
            settings = existing
        } else {
            settings = [
                "permissions": [
                    "allow": [
                        "Bash(curl:*)",
                        "Bash(xcrun simctl terminate:*)",
                        "Bash(xcrun simctl launch:*)",
                        "mcp__blitz-macos__app_get_state",
                    ]
                ],
                "enabledMcpjsonServers": correctServers,
            ]
        }
        if let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: settingsFile)
        }

        // 2. CLAUDE.md — write only if absent; user may have their own
        let claudeMdFile = projectDir.appendingPathComponent("CLAUDE.md")
        if !fm.fileExists(atPath: claudeMdFile.path) {
            let content = Self.claudeMdContent(projectType: projectType)
            try? content.write(to: claudeMdFile, atomically: true, encoding: .utf8)
        }

        // 3. .claude/rules/ — Blitz-owned files, always overwrite.
        // These auto-load in every Claude Code session alongside any existing CLAUDE.md,
        // so agents get Blitz/Teenybase context even on projects with pre-existing docs.
        let rulesDir = claudeDir.appendingPathComponent("rules")
        try? fm.createDirectory(at: rulesDir, withIntermediateDirectories: true)

        let blitzRules = rulesDir.appendingPathComponent("blitz.md")
        try? Self.blitzRulesContent().write(to: blitzRules, atomically: true, encoding: .utf8)

        let teenybaseRules = rulesDir.appendingPathComponent("teenybase.md")
        try? Self.teenybaseRulesContent(projectDir: projectDir, projectType: projectType)
            .write(to: teenybaseRules, atomically: true, encoding: .utf8)

        // 4. App Store Review Agent — clone from public repo, symlink into .claude/agents/
        ensureReviewerAgent(projectDir: projectDir)

        // 5. ASC CLI skills — clone from public repo, copy into .claude/skills/
        ensureASCSkills(projectDir: projectDir)

        // 6. ASC CLI — headless install if not already present
        ensureASCCLI()
    }

    /// Clone or update the app-store-review-agent repo and symlink the agent
    /// into .claude/agents/ where Claude Code can discover it.
    /// Runs git operations on a background queue so it never blocks the UI.
    func ensureReviewerAgent(projectDir: URL) {
        let fm = FileManager.default
        let claudeDir = projectDir.appendingPathComponent(".claude")
        let agentRepoDir = claudeDir.appendingPathComponent("app-store-review-agent")
        let agentsDir = claudeDir.appendingPathComponent("agents")
        let symlinkPath = agentsDir.appendingPathComponent("reviewer.md")

        // If symlink already exists and resolves to a real file, nothing to do.
        // (Still dispatch a background pull to pick up rule updates.)
        let symlinkExists = fm.fileExists(atPath: symlinkPath.path)

        DispatchQueue.global(qos: .utility).async {
            let repoURL = BlitzPaths.reviewerAgentRepo

            if fm.fileExists(atPath: agentRepoDir.appendingPathComponent(".git").path) {
                // Already cloned — pull latest in background
                let pull = Process()
                pull.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                pull.arguments = ["-C", agentRepoDir.path, "pull", "--quiet", "--ff-only"]
                pull.standardOutput = FileHandle.nullDevice
                pull.standardError = FileHandle.nullDevice
                try? pull.run()
                pull.waitUntilExit()
            } else {
                // First time — clone
                let clone = Process()
                clone.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                clone.arguments = ["clone", "--quiet", "--depth", "1", repoURL, agentRepoDir.path]
                clone.standardOutput = FileHandle.nullDevice
                clone.standardError = FileHandle.nullDevice
                try? clone.run()
                clone.waitUntilExit()
                guard clone.terminationStatus == 0 else {
                    print("[ProjectStorage] Failed to clone app-store-review-agent")
                    return
                }
            }

            // Create .claude/agents/ and symlink reviewer.md
            if !symlinkExists {
                try? fm.createDirectory(at: agentsDir, withIntermediateDirectories: true)
                // Relative symlink so it works regardless of absolute project path
                try? fm.createSymbolicLink(
                    atPath: symlinkPath.path,
                    withDestinationPath: "../app-store-review-agent/agents/reviewer.md"
                )
                print("[ProjectStorage] Reviewer agent installed")
            }
        }
    }

    /// Clone or update the ASC CLI skills repo and copy skill directories
    /// into .claude/skills/ where Claude Code can discover them.
    /// Overwrites asc-app-create-ui/SKILL.md with the pre-cached-session version.
    /// Runs git operations on a background queue so it never blocks the UI.
    func ensureASCSkills(projectDir: URL) {
        let fm = FileManager.default
        let claudeDir = projectDir.appendingPathComponent(".claude")
        let repoDir = claudeDir.appendingPathComponent("asc-skills")
        let skillsDir = claudeDir.appendingPathComponent("skills")

        DispatchQueue.global(qos: .utility).async {
            let repoURL = BlitzPaths.ascSkillsRepo

            if fm.fileExists(atPath: repoDir.appendingPathComponent(".git").path) {
                // Already cloned — pull latest
                let pull = Process()
                pull.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                pull.arguments = ["-C", repoDir.path, "pull", "--quiet", "--ff-only"]
                pull.standardOutput = FileHandle.nullDevice
                pull.standardError = FileHandle.nullDevice
                try? pull.run()
                pull.waitUntilExit()
            } else {
                // First time — clone
                let clone = Process()
                clone.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                clone.arguments = ["clone", "--quiet", "--depth", "1", repoURL, repoDir.path]
                clone.standardOutput = FileHandle.nullDevice
                clone.standardError = FileHandle.nullDevice
                try? clone.run()
                clone.waitUntilExit()
                guard clone.terminationStatus == 0 else {
                    print("[ProjectStorage] Failed to clone asc-skills")
                    return
                }
            }

            // Copy each skill directory from the cloned repo into .claude/skills/
            let repoSkillsDir = repoDir.appendingPathComponent("skills")
            guard let skillDirs = try? fm.contentsOfDirectory(
                at: repoSkillsDir,
                includingPropertiesForKeys: [.isDirectoryKey]
            ) else { return }

            try? fm.createDirectory(at: skillsDir, withIntermediateDirectories: true)

            for srcSkillDir in skillDirs {
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: srcSkillDir.path, isDirectory: &isDir),
                      isDir.boolValue else { continue }

                let destSkillDir = skillsDir.appendingPathComponent(srcSkillDir.lastPathComponent)

                if fm.fileExists(atPath: destSkillDir.path) {
                    // Update: remove and re-copy to pick up changes
                    try? fm.removeItem(at: destSkillDir)
                }
                try? fm.copyItem(at: srcSkillDir, to: destSkillDir)
            }

            // Overwrite asc-app-create-ui/SKILL.md with Blitz's pre-cached-session version
            let ascCreateSkillFile = skillsDir
                .appendingPathComponent("asc-app-create-ui")
                .appendingPathComponent("SKILL.md")
            try? Self.ascAppCreateSkillContent()
                .write(to: ascCreateSkillFile, atomically: true, encoding: .utf8)

            print("[ProjectStorage] ASC skills installed")
        }
    }

    /// Content for the Blitz-specific asc-app-create-ui skill that uses
    /// pre-cached Apple ID session instead of requiring browser automation.
    private static func ascAppCreateSkillContent() -> String {
        return """
        ---
        name: asc-app-create-ui
        description: Create an App Store Connect app using pre-cached Apple ID session from Blitz
        ---

        Create an App Store Connect app using the `asc` CLI. The user's Apple ID session has already been captured by Blitz and bridged into the ASC CLI keychain, so **no password or 2FA is needed**.

        Extract from the conversation context:
        - `bundleId` — the bundle identifier (e.g. `com.blitz.myapp`)
        - `sku` — the SKU string
        - `appleId` — the Apple ID email (may be provided; if missing, ask the user)

        ## Steps

        1. **Ask the user** what primary language the app should use. Common choices: `en-US` (English US), `en-GB` (English UK), `ja` (Japanese), `zh-Hans` (Simplified Chinese), `ko` (Korean), `fr-FR` (French), `de-DE` (German).

        2. **Derive the app name** from the bundle ID: take the last component after the final `.`, capitalize the first letter.

        3. **Run the create command** — auth is pre-cached, no prompts expected:

        ```bash
        asc apps create \\
          --apple-id "<appleId>" \\
          --bundle-id "<bundleId>" \\
          --sku "<sku>" \\
          --primary-locale "<locale>" \\
          --name "<appName>"
        ```

        4. Report the App ID and store URL back to the user on success.

        5. If the command fails with an auth error, tell the user to re-authenticate through Blitz (Release > Overview > "Automatically create using Claude Code") and try again.
        """
    }

    /// Install the `asc` CLI if not already present on the system.
    /// Checks common install locations first; if missing, runs the headless installer.
    /// Runs on a background queue so it never blocks the UI.
    func ensureASCCLI() {
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            let searchPaths = [
                "/opt/homebrew/bin/asc",
                "/usr/local/bin/asc",
                NSHomeDirectory() + "/.local/bin/asc",
            ]

            for path in searchPaths {
                if fm.isExecutableFile(atPath: path) { return }
            }

            // Not found — install headlessly
            let install = Process()
            install.executableURL = URL(fileURLWithPath: "/bin/bash")
            install.arguments = ["-c", "curl -fsSL https://asccli.sh/install | bash"]
            install.standardOutput = FileHandle.nullDevice
            install.standardError = FileHandle.nullDevice
            try? install.run()
            install.waitUntilExit()

            if install.terminationStatus == 0 {
                print("[ProjectStorage] ASC CLI installed")
            } else {
                print("[ProjectStorage] Failed to install ASC CLI")
            }
        }
    }

    private static func claudeMdContent(projectType: ProjectType) -> String {
        guard let templateURL = Bundle.appResources.url(forResource: "CLAUDE.md", withExtension: "template"),
              var template = try? String(contentsOf: templateURL, encoding: .utf8) else {
            return "# Blitz AI Agent Guide\n"
        }

        let header: String
        switch projectType {
        case .swift:
            header = "Swift Project — Blitz AI Agent Guide"
        case .reactNative:
            header = "React Native Project — Blitz AI Agent Guide"
        case .flutter:
            header = "Flutter Project — Blitz AI Agent Guide"
        }
        template = template.replacingOccurrences(of: "{{PROJECT_TYPE_HEADER}}", with: header)

        return template
    }

    private static func blitzRulesContent() -> String {
        guard let url = Bundle.appResources.url(forResource: "blitz-rules", withExtension: "md"),
              let content = try? String(contentsOf: url, encoding: .utf8) else {
            return "# Blitz MCP Integration\n"
        }
        return content
    }

    private static func teenybaseRulesContent(projectDir: URL, projectType: ProjectType) -> String {
        let fm = FileManager.default

        let backendDir: URL
        let schemaPath: String
        let commandPrefix: String
        switch projectType {
        case .reactNative:
            backendDir = projectDir
            schemaPath = "teenybase.ts"
            commandPrefix = ""
        case .swift, .flutter:
            backendDir = projectDir.appendingPathComponent("backend")
            schemaPath = "backend/teenybase.ts"
            commandPrefix = "cd backend && "
        }

        let hasBackend = fm.fileExists(atPath: backendDir.appendingPathComponent("teenybase.ts").path)
        let templateName = hasBackend ? "teenybase-rules-backend" : "teenybase-rules-no-backend"

        guard let url = Bundle.appResources.url(forResource: templateName, withExtension: "md"),
              var content = try? String(contentsOf: url, encoding: .utf8) else {
            return "# Teenybase Backend\n"
        }

        content = content.replacingOccurrences(of: "{{DEVVARS_PATH}}", with: backendDir.appendingPathComponent(".dev.vars").path)
        content = content.replacingOccurrences(of: "{{SCHEMA_PATH}}", with: schemaPath)
        content = content.replacingOccurrences(of: "{{COMMAND_PREFIX}}", with: commandPrefix)
        return content
    }

    // MARK: - Teenybase backend scaffolding

    /// Copy Teenybase backend files into a project if not already present.
    /// RN projects get files at the project root; Swift/Flutter get a backend/ subdirectory.
    func ensureTeenybaseBackend(projectId: String, projectType: ProjectType) {
        let fm = FileManager.default
        let projectDir = baseDirectory.appendingPathComponent(projectId)

        guard let templateURL = Bundle.appResources.url(
            forResource: "rn-notes-template", withExtension: nil, subdirectory: "templates"
        ) else {
            print("[ProjectStorage] Teenybase template not found in bundle")
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
            ensureStandalonePackageJson(at: backendDir.appendingPathComponent("package.json"),
                                        projectId: projectId, fm: fm)
        }
    }

    /// Copy teenybase.ts, wrangler.toml, src-backend/worker.ts, and .dev.vars into dest.
    /// Skips each file if it already exists so existing configs are never overwritten.
    private func copyTeenybaseFiles(from templateURL: URL, to dest: URL, fm: FileManager) {
        // teenybase.ts — skip if present (indicates backend already set up)
        let teenybaseDest = dest.appendingPathComponent("teenybase.ts")
        guard !fm.fileExists(atPath: teenybaseDest.path) else { return }

        try? fm.copyItem(at: templateURL.appendingPathComponent("teenybase.ts"), to: teenybaseDest)

        // wrangler.toml
        let wranglerDest = dest.appendingPathComponent("wrangler.toml")
        if !fm.fileExists(atPath: wranglerDest.path) {
            let src = templateURL.appendingPathComponent("wrangler.toml")
            if var content = try? String(contentsOf: src, encoding: .utf8) {
                content = content.replacingOccurrences(of: "sample-app", with: dest.deletingLastPathComponent().lastPathComponent)
                try? content.write(to: wranglerDest, atomically: true, encoding: .utf8)
            }
        }

        // src-backend/worker.ts
        let srcBackendDest = dest.appendingPathComponent("src-backend")
        try? fm.createDirectory(at: srcBackendDest, withIntermediateDirectories: true)
        let workerDest = srcBackendDest.appendingPathComponent("worker.ts")
        if !fm.fileExists(atPath: workerDest.path) {
            try? fm.copyItem(
                at: templateURL.appendingPathComponent("src-backend/worker.ts"),
                to: workerDest
            )
        }

        // .dev.vars — from sample.vars
        let devVarsDest = dest.appendingPathComponent(".dev.vars")
        if !fm.fileExists(atPath: devVarsDest.path) {
            let sampleVars = templateURL.appendingPathComponent("sample.vars")
            if fm.fileExists(atPath: sampleVars.path) {
                try? fm.copyItem(at: sampleVars, to: devVarsDest)
            }
        }
    }

    /// For RN projects: merge teenybase scripts + devDependency into existing package.json.
    /// No-op if teenybase is already in devDependencies.
    private func mergeTeenybaseScripts(into packageJsonURL: URL, fm: FileManager) {
        guard fm.fileExists(atPath: packageJsonURL.path),
              let data = try? Data(contentsOf: packageJsonURL),
              var pkg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        var devDeps = pkg["devDependencies"] as? [String: Any] ?? [:]
        guard devDeps["teenybase"] == nil else { return } // already set up

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

    /// For Swift/Flutter: write a standalone package.json for the backend/ subdirectory.
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

    /// Clear lastOpenedAt on all projects
    func clearRecentProjects() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: baseDirectory, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for entry in entries {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let projectId = entry.lastPathComponent
            guard var metadata = readMetadata(projectId: projectId) else { continue }
            metadata.lastOpenedAt = nil
            try? writeMetadata(projectId: projectId, metadata: metadata)
        }
    }
}

enum ProjectOpenError: LocalizedError {
    case notABlitzProject

    var errorDescription: String? {
        switch self {
        case .notABlitzProject:
            return "Not a Blitz project. The selected folder does not contain .blitz/project.json. Use Import to add an external project."
        }
    }
}
