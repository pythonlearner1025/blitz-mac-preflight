import Darwin
import Foundation

public enum BlitzMCPTransportPaths {
    public static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".blitz")
    }

    public static var helper: URL {
        root.appendingPathComponent("blitz-macos-mcp")
    }

    public static var bridgeScript: URL {
        root.appendingPathComponent("blitz-mcp-bridge.sh")
    }

    public static var socket: URL {
        URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("blitz-mcp-\(getuid()).sock")
    }
}
