import Foundation

/// Parses `xcrun simctl list devices -j` output
public struct SimctlClient: Sendable {

    public init() {}

    public struct DeviceList: Codable, Sendable {
        public let devices: [String: [SimctlDevice]]
    }

    public struct SimctlDevice: Codable, Sendable, Identifiable {
        public let udid: String
        public let name: String
        public let state: String
        public let isAvailable: Bool
        public let deviceTypeIdentifier: String?
        public let lastBootedAt: String?

        public var id: String { udid }
        public var isBooted: Bool { state == "Booted" }
    }

    /// Parse the JSON output of `xcrun simctl list devices -j`
    public func parseDeviceList(json: Data) throws -> [SimctlDevice] {
        let decoded = try JSONDecoder().decode(DeviceList.self, from: json)
        return decoded.devices.values
            .flatMap { $0 }
            .filter { $0.isAvailable }
            .sorted { ($0.name) < ($1.name) }
    }

    /// List all available simulators
    public func listDevices() async throws -> [SimctlDevice] {
        let result = try await ProcessRunner.run("xcrun", arguments: ["simctl", "list", "devices", "-j"])
        return try parseDeviceList(json: Data(result.utf8))
    }

    /// Boot a simulator
    public func boot(udid: String) async throws {
        _ = try await ProcessRunner.run("xcrun", arguments: ["simctl", "boot", udid])
    }

    /// Shutdown a simulator
    public func shutdown(udid: String) async throws {
        _ = try await ProcessRunner.run("xcrun", arguments: ["simctl", "shutdown", udid])
    }

    /// Install an app bundle
    public func install(udid: String, appPath: String) async throws {
        _ = try await ProcessRunner.run("xcrun", arguments: ["simctl", "install", udid, appPath])
    }

    /// Launch an app by bundle ID
    public func launch(udid: String, bundleId: String) async throws {
        _ = try await ProcessRunner.run("xcrun", arguments: ["simctl", "launch", udid, bundleId])
    }

    /// Take a screenshot
    public func screenshot(udid: String, path: String) async throws {
        _ = try await ProcessRunner.run("xcrun", arguments: ["simctl", "io", udid, "screenshot", path])
    }

    /// Send a tap event
    public func tap(udid: String, x: Double, y: Double) async throws {
        _ = try await ProcessRunner.run("xcrun", arguments: [
            "simctl", "io", udid, "tap", "\(Int(x))", "\(Int(y))"
        ])
    }

    /// Send a swipe event
    public func swipe(udid: String, fromX: Double, fromY: Double, toX: Double, toY: Double, duration: Double = 0.3) async throws {
        _ = try await ProcessRunner.run("xcrun", arguments: [
            "simctl", "io", udid, "swipe",
            "\(Int(fromX))", "\(Int(fromY))",
            "\(Int(toX))", "\(Int(toY))",
            "--duration", "\(duration)"
        ])
    }

    /// Send a button press
    public func pressButton(udid: String, button: String) async throws {
        // Map button names to simctl commands
        switch button.lowercased() {
        case "home":
            _ = try await ProcessRunner.run("xcrun", arguments: [
                "simctl", "io", udid, "sendkey", "home"
            ])
        case "lock", "side_button":
            _ = try await ProcessRunner.run("xcrun", arguments: [
                "simctl", "io", udid, "sendkey", "lock"
            ])
        default:
            _ = try await ProcessRunner.run("xcrun", arguments: [
                "simctl", "io", udid, "sendkey", button
            ])
        }
    }

    /// Input text into the simulator
    public func inputText(udid: String, text: String) async throws {
        _ = try await ProcessRunner.run("xcrun", arguments: [
            "simctl", "io", udid, "input-text", text
        ])
    }

    /// Open a URL in the simulator
    public func openURL(udid: String, url: String) async throws {
        _ = try await ProcessRunner.run("xcrun", arguments: [
            "simctl", "openurl", udid, url
        ])
    }
}
