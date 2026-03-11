import Foundation

/// Central source of truth for all ~/.blitz/ paths used across the app.
/// Every file that needs a .blitz path should use these instead of hardcoding.
public enum BlitzPaths {
    /// Root: ~/.blitz/
    public static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".blitz")
    }

    /// Projects directory: ~/.blitz/projects/
    public static var projects: URL { root.appendingPathComponent("projects") }

    /// Settings file: ~/.blitz/settings.json
    public static var settings: URL { root.appendingPathComponent("settings.json") }

    /// MCP port file: ~/.blitz/mcp-port
    public static var mcpPort: URL { root.appendingPathComponent("mcp-port") }

    /// MCP bridge script: ~/.blitz/blitz-mcp-bridge.sh
    public static var mcpBridge: URL { root.appendingPathComponent("blitz-mcp-bridge.sh") }

    /// Macros directory: ~/.blitz/macros/
    public static var macros: URL { root.appendingPathComponent("macros") }

    /// Issues directory: ~/.blitz/issues/
    public static var issues: URL { root.appendingPathComponent("issues") }

    /// Signing base directory: ~/.blitz/signing/
    public static var signing: URL { root.appendingPathComponent("signing") }

    /// Signing directory for a specific bundle ID
    public static func signing(bundleId: String) -> URL {
        signing.appendingPathComponent(bundleId)
    }

    /// Python idb path: ~/.blitz/python/bin/idb
    public static var idbPath: URL { root.appendingPathComponent("python/bin/idb") }

    /// idb companion path: ~/.blitz/idb-companion/bin/idb_companion
    public static var idbCompanionPath: URL {
        root.appendingPathComponent("idb-companion/bin/idb_companion")
    }

    /// Node runtime: ~/.blitz/node-runtime/bin/node
    public static var nodeRuntime: URL {
        root.appendingPathComponent("node-runtime/bin/node")
    }
}
