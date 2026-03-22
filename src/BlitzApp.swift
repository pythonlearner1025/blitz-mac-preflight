import SwiftUI

/// Manages MCP server lifecycle independently of SwiftUI view callbacks.
@MainActor
final class MCPBootstrap {
    static let shared = MCPBootstrap()
    private(set) var server: MCPServerService?
    private var started = false

    func boot(appState: AppState) {
        guard !started else { return }
        started = true

        installBridgeScript()
        installClaudeSkills()
        updateIphoneMCP()
        ProjectStorage().ensureGlobalMCPConfigs()

        let server = MCPServerService(appState: appState)
        self.server = server
        appState.mcpServer = server

        Task.detached {
            do {
                try await server.start()
            } catch {
                print("[MCP] Failed to start server: \(error)")
            }
        }
    }

    func shutdown() {
        guard let server else { return }
        // Fire-and-forget — app is terminating
        Task.detached { await server.stop() }
        // Brief wait to allow cleanup
        Thread.sleep(forTimeInterval: 0.1)
    }

    /// Copies bundled Claude skills to ~/.claude/skills/ so they're globally available.
    /// Overwrites on every launch to keep skills in sync with the app version.
    private func installClaudeSkills() {
        let fm = FileManager.default
        let destRoot = BlitzPaths.claudeSkills

        // Look for embedded skills in the app bundle
        guard let bundleSkills = Bundle.main.resourceURL?
                .appendingPathComponent("claude-skills") else { return }
        guard fm.fileExists(atPath: bundleSkills.path) else { return }

        do {
            try fm.createDirectory(at: destRoot, withIntermediateDirectories: true)
            let skills = try fm.contentsOfDirectory(atPath: bundleSkills.path)
            for skill in skills {
                let src = bundleSkills.appendingPathComponent(skill)
                let dst = destRoot.appendingPathComponent(skill)
                // Remove old version and copy fresh
                try? fm.removeItem(at: dst)
                try fm.copyItem(at: src, to: dst)
            }
        } catch {
            print("[MCP] Failed to install Claude skills: \(error)")
        }
    }

    /// Background-update @blitzdev/iphone-mcp in the bundled Node runtime.
    /// Runs `npm install -g @blitzdev/iphone-mcp@latest` so the binary at
    /// ~/.blitz/node-runtime/bin/iphone-mcp stays current with each app launch.
    private func updateIphoneMCP() {
        let npm = BlitzPaths.nodeDir.appendingPathComponent("npm").path
        guard FileManager.default.isExecutableFile(atPath: npm) else { return }

        Task.detached(priority: .utility) {
            do {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: npm)
                process.arguments = ["install", "-g", "@blitzdev/iphone-mcp@latest"]
                process.environment = [
                    "PATH": "\(BlitzPaths.nodeDir.path):/usr/bin:/bin",
                    "HOME": FileManager.default.homeDirectoryForCurrentUser.path
                ]
                process.standardOutput = nil
                process.standardError = nil
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    print("[MCP] iphone-mcp updated successfully")
                } else {
                    print("[MCP] iphone-mcp update failed (exit \(process.terminationStatus))")
                }
            } catch {
                print("[MCP] iphone-mcp update error: \(error)")
            }
        }
    }

    private func installBridgeScript() {
        let destDir = BlitzPaths.root
        let destFile = BlitzPaths.mcpBridge

        if let bundlePath = Bundle.main.path(forResource: "blitz-mcp-bridge", ofType: "sh") {
            try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: destFile)
            try? FileManager.default.copyItem(atPath: bundlePath, toPath: destFile.path)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destFile.path)
        } else {
            let script = """
            #!/bin/bash
            PORT_FILE="$HOME/.blitz/mcp-port"
            WAITED=0
            while [ ! -f "$PORT_FILE" ] && [ "$WAITED" -lt 10 ]; do
                sleep 1
                WAITED=$((WAITED + 1))
            done
            if [ ! -f "$PORT_FILE" ]; then
                echo '{"jsonrpc":"2.0","id":1,"error":{"code":-1,"message":"Blitz is not running."}}' >&2
                exit 1
            fi
            PORT=$(cat "$PORT_FILE")
            WAITED=0
            while ! curl -s -o /dev/null -w '' "http://127.0.0.1:${PORT}/mcp" 2>/dev/null && [ "$WAITED" -lt 5 ]; do
                sleep 1
                WAITED=$((WAITED + 1))
            done
            while IFS= read -r line; do
                [ -z "$line" ] && continue
                response=$(curl -s -X POST "http://127.0.0.1:${PORT}/mcp" \\
                    -H "Content-Type: application/json" -d "$line" 2>/dev/null)
                if [ $? -ne 0 ]; then
                    echo '{"jsonrpc":"2.0","id":null,"error":{"code":-1,"message":"Cannot connect to Blitz."}}' >&2
                    exit 1
                fi
                echo "$response"
            done
            """
            try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
            try? script.write(to: destFile, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destFile.path)
        }
    }
}

final class BlitzAppDelegate: NSObject, NSApplicationDelegate {
    var appState: AppState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let fileMenu = NSApp.mainMenu?.item(withTitle: "File") {
            fileMenu.title = "Project"
        }
        // Set dock icon from bundled resource (needed for swift run / non-.app launches)
        if let icon = Bundle.appResources.image(forResource: "blitz-icon") {
            NSApp.applicationIconImage = icon
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        MCPBootstrap.shared.shutdown()
        // Don't block termination with synchronous simctl shutdown —
        // this prevents macOS TCC "Quit & Reopen" from relaunching the app.
        // Fire-and-forget: let simctl handle cleanup in the background.
        if let udid = appState?.simulatorManager.bootedDeviceId {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["simctl", "shutdown", udid]
            try? process.run()
            // Do NOT call waitUntilExit() — let the app terminate immediately
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            if appState?.activeProjectId != nil {
                for window in NSApp.windows where window.canBecomeMain {
                    window.makeKeyAndOrderFront(nil)
                    return false
                }
            }
            for window in NSApp.windows {
                window.makeKeyAndOrderFront(nil)
                return false
            }
        }
        return true
    }
}

@main
struct BlitzApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: BlitzAppDelegate
    @State private var appState = AppState()

    var body: some Scene {
        Window("Welcome to Blitz", id: "welcome") {
            WelcomeWindow(appState: appState)
                .frame(width: 700, height: 440)
                .onAppear {
                    appDelegate.appState = appState
                }
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 700, height: 440)
        .commands {
            AppCommands(appState: appState)
        }

        WindowGroup(id: "main", for: String.self) { _ in
            ContentView(appState: appState)
                .frame(minWidth: 800, minHeight: 600)
        }
        .defaultSize(width: 1200, height: 900)
        .windowToolbarStyle(.unified(showsTitle: false))
    }
}
