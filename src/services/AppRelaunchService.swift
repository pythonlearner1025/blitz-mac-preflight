import AppKit
import Foundation

/// Tracks permission-driven restart flows and can reopen the current app bundle
/// after macOS terminates Blitz.
final class AppRelaunchService {
    static let shared = AppRelaunchService()

    private enum Keys {
        static let pendingReason = "blitz.pendingRelaunch.reason"
        static let pendingCreatedAt = "blitz.pendingRelaunch.createdAt"
        static let pendingAppPath = "blitz.pendingRelaunch.appPath"
    }

    private enum PendingReason: String {
        case screenRecordingPermission
    }

    private let defaults: UserDefaults
    private let now: () -> Date
    private let appURLProvider: () -> URL?
    private let screenRecordingAccessProvider: () -> Bool
    private let launcher: (String, Int32) -> Bool

    static let pendingWindow: TimeInterval = 180

    init(
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        appURLProvider: @escaping () -> URL? = AppRelaunchService.defaultAppURL,
        screenRecordingAccessProvider: @escaping () -> Bool = { CGPreflightScreenCaptureAccess() },
        launcher: @escaping (String, Int32) -> Bool = AppRelaunchService.launchDetachedRelaunchProcess
    ) {
        self.defaults = defaults
        self.now = now
        self.appURLProvider = appURLProvider
        self.screenRecordingAccessProvider = screenRecordingAccessProvider
        self.launcher = launcher
    }

    func prepareForScreenRecordingPermissionRestart() {
        guard let appURL = appURLProvider() else { return }
        defaults.set(PendingReason.screenRecordingPermission.rawValue, forKey: Keys.pendingReason)
        defaults.set(now().timeIntervalSince1970, forKey: Keys.pendingCreatedAt)
        defaults.set(appURL.path, forKey: Keys.pendingAppPath)
    }

    func clearPendingRestart() {
        defaults.removeObject(forKey: Keys.pendingReason)
        defaults.removeObject(forKey: Keys.pendingCreatedAt)
        defaults.removeObject(forKey: Keys.pendingAppPath)
    }

    /// If Blitz becomes active again, the OS restart did not happen and the
    /// pending relaunch should not survive future manual quits.
    func clearPendingRestartAfterReturningToApp() {
        guard pendingReason() != nil else { return }
        clearPendingRestart()
    }

    @discardableResult
    func schedulePendingScreenRecordingRelaunchIfNeeded(pid: Int32 = ProcessInfo.processInfo.processIdentifier) -> Bool {
        defer { clearPendingRestart() }

        guard pendingReason() == .screenRecordingPermission else { return false }
        guard let createdAt = pendingCreatedAt(), now().timeIntervalSince(createdAt) <= Self.pendingWindow else {
            return false
        }
        guard screenRecordingAccessProvider() else { return false }
        guard let appPath = pendingAppPath() else { return false }

        return launcher(appPath, pid)
    }

    private func pendingReason() -> PendingReason? {
        guard let rawValue = defaults.string(forKey: Keys.pendingReason) else { return nil }
        return PendingReason(rawValue: rawValue)
    }

    private func pendingCreatedAt() -> Date? {
        guard defaults.object(forKey: Keys.pendingCreatedAt) != nil else { return nil }
        return Date(timeIntervalSince1970: defaults.double(forKey: Keys.pendingCreatedAt))
    }

    private func pendingAppPath() -> String? {
        guard let path = defaults.string(forKey: Keys.pendingAppPath), !path.isEmpty else { return nil }
        return path
    }

    static func launchDetachedRelaunchProcess(appPath: String, pid: Int32) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", relaunchShellCommand(appPath: appPath, pid: pid)]
        process.standardOutput = nil
        process.standardError = nil

        do {
            try process.run()
            return true
        } catch {
            print("[Relaunch] Failed to schedule app relaunch: \(error)")
            return false
        }
    }

    static func relaunchShellCommand(appPath: String, pid: Int32) -> String {
        "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; open \(shellQuote(appPath))"
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func defaultAppURL() -> URL? {
        let bundleURL = Bundle.main.bundleURL.standardizedFileURL
        if bundleURL.pathExtension == "app" {
            return bundleURL
        }

        if let bundleID = Bundle.main.bundleIdentifier,
           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return appURL.standardizedFileURL
        }

        return nil
    }
}
