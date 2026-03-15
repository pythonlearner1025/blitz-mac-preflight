import AppKit
import Foundation

/// Handles checking for updates, downloading, and installing them.
/// Mirrors the Tauri updater approach: fetch latest.json, download .app.zip,
/// replace /Applications/Blitz.app via osascript, relaunch.
@MainActor
@Observable
final class AutoUpdateManager {
    enum State: Equatable {
        case idle
        case checking
        case available(version: String, releaseNotes: String)
        case downloading(percent: Int)
        case installing
        case failed(String)
    }

    var state: State = .idle

    var isUpdateAvailable: Bool {
        if case .available = state { return true }
        return false
    }

    /// True when the update UI should cover the entire welcome window.
    var showsFullScreenOverlay: Bool {
        switch state {
        case .idle, .checking: return false
        default: return true
        }
    }

    private var latestVersion: String?
    private var downloadURL: String?
    private var downloadFilename: String?

    private static let releasesURL = "https://api.github.com/repos/blitzdotdev/blitz-mac/releases/latest"

    /// Current app version from Info.plist (falls back to "0.0.0" in dev builds).
    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    // MARK: - Check

    func checkForUpdate() async {
        state = .checking

        do {
            var request = URLRequest(url: URL(string: Self.releasesURL)!)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String,
                  let assets = json["assets"] as? [[String: Any]] else {
                state = .idle
                return
            }

            let remoteVersion = tagName.replacingOccurrences(of: "v", with: "")

            // Find the .pkg asset first, fall back to .app.zip
            let pkgAsset = assets.first { ($0["name"] as? String)?.hasSuffix(".pkg") == true }
            let zipAsset = assets.first { ($0["name"] as? String)?.hasSuffix(".app.zip") == true }
            guard let asset = pkgAsset ?? zipAsset,
                  let downloadUrl = asset["browser_download_url"] as? String,
                  let filename = asset["name"] as? String else {
                state = .idle
                return
            }

            guard Self.isNewer(remote: remoteVersion, current: currentVersion) else {
                print("[AutoUpdate] Up to date (current: \(currentVersion), remote: \(remoteVersion))")
                state = .idle
                return
            }

            print("[AutoUpdate] Update available: \(currentVersion) -> \(remoteVersion)")
            latestVersion = remoteVersion
            downloadURL = downloadUrl
            downloadFilename = filename

            let notes = json["body"] as? String ?? ""
            state = .available(version: remoteVersion, releaseNotes: notes)
        } catch {
            print("[AutoUpdate] Check failed: \(error)")
            state = .idle
        }
    }

    // MARK: - Download & Install

    func performUpdate() async {
        guard let url = downloadURL, let filename = downloadFilename else { return }

        state = .downloading(percent: 0)

        do {
            let downloadedPath = try await downloadApp(url: url, filename: filename)
            state = .installing
            if filename.hasSuffix(".pkg") {
                try await installPkg(pkgPath: downloadedPath)
            } else {
                try await installApp(zipPath: downloadedPath)
            }
            // If we get here, the app is about to relaunch
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func dismiss() {
        state = .idle
    }

    // MARK: - Private

    private func downloadApp(url: String, filename: String) async throws -> URL {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        // Remove stale download
        try? FileManager.default.removeItem(at: destination)

        let (asyncBytes, response) = try await URLSession.shared.bytes(from: URL(string: url)!)

        let totalBytes = (response as? HTTPURLResponse)
            .flatMap { Int($0.value(forHTTPHeaderField: "Content-Length") ?? "") } ?? 0

        var data = Data()
        data.reserveCapacity(totalBytes > 0 ? totalBytes : 50_000_000)

        var lastReportedPercent = 0
        for try await byte in asyncBytes {
            data.append(byte)
            if totalBytes > 0 {
                let percent = Int(Double(data.count) / Double(totalBytes) * 100)
                if percent != lastReportedPercent {
                    lastReportedPercent = percent
                    state = .downloading(percent: min(percent, 100))
                }
            }
        }

        try data.write(to: destination)
        print("[AutoUpdate] Downloaded \(data.count) bytes to \(destination.path)")
        return destination
    }

    private func installPkg(pkgPath: URL) async throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let pkg = pkgPath.path.replacingOccurrences(of: "'", with: "'\\''")

        let installScript = """
        do shell script "installer -pkg '\(pkg)' -target / 2>&1" with administrator privileges
        """

        let relaunchScript = """
        do shell script "(while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; open /Applications/Blitz.app) &>/dev/null &"
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", installScript, "-e", relaunchScript]
        process.standardOutput = nil
        process.standardError = nil

        try process.run()
        process.waitUntilExit()

        try? FileManager.default.removeItem(at: pkgPath)

        guard process.terminationStatus == 0 else {
            throw UpdateError(message: "Installation failed (exit code \(process.terminationStatus))")
        }

        await MainActor.run {
            NSApplication.shared.terminate(nil)
        }
    }

    private func installApp(zipPath: URL) async throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let zip = zipPath.path.replacingOccurrences(of: "'", with: "'\\''")

        // AppleScript statement 1: unzip, run preinstall, replace app, run postinstall
        // The PKG postinstall chowns Blitz.app to the current user, so no admin needed.
        // Pre/postinstall scripts are embedded in the .app at Contents/Resources/pkg-scripts/.
        let installScript = """
        do shell script "\
        TMPZIP='\(zip)'; \
        UNZIP_DIR=$(mktemp -d); \
        unzip -qo \\"$TMPZIP\\" -d \\"$UNZIP_DIR\\"; \
        APP_SRC=$(find \\"$UNZIP_DIR\\" -maxdepth 1 -name '*.app' -type d | head -1); \
        if [ -z \\"$APP_SRC\\" ]; then rm -rf \\"$UNZIP_DIR\\"; exit 1; fi; \
        PREINSTALL=\\"$APP_SRC/Contents/Resources/pkg-scripts/preinstall\\"; \
        if [ -x \\"$PREINSTALL\\" ]; then \\"$PREINSTALL\\" '' '' '/' >> /tmp/blitz_install.log 2>&1 || true; fi; \
        rm -rf /Applications/Blitz.app; \
        mv \\"$APP_SRC\\" /Applications/Blitz.app; \
        POSTINSTALL='/Applications/Blitz.app/Contents/Resources/pkg-scripts/postinstall'; \
        if [ -x \\"$POSTINSTALL\\" ]; then \\"$POSTINSTALL\\" '' '' '/' >> /tmp/blitz_install.log 2>&1 || true; fi; \
        rm -rf \\"$UNZIP_DIR\\" \\"$TMPZIP\\"\
        "
        """

        // AppleScript statement 2: background wait-for-exit + relaunch
        let relaunchScript = """
        do shell script "(while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; open /Applications/Blitz.app) &>/dev/null &"
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", installScript, "-e", relaunchScript]
        process.standardOutput = nil
        process.standardError = nil

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw UpdateError(message: "Installation failed (exit code \(process.terminationStatus))")
        }

        // Exit the current app so the background relaunch can kick in
        await MainActor.run {
            NSApplication.shared.terminate(nil)
        }
    }

    /// Simple semver comparison (major.minor.patch).
    private static func isNewer(remote: String, current: String) -> Bool {
        let parse = { (v: String) -> [Int] in
            v.trimmingCharacters(in: .whitespaces)
             .replacingOccurrences(of: "v", with: "")
             .split(separator: ".")
             .compactMap { Int($0) }
        }
        let r = parse(remote)
        let c = parse(current)
        guard r.count >= 3, c.count >= 3 else { return false }
        if r[0] != c[0] { return r[0] > c[0] }
        if r[1] != c[1] { return r[1] > c[1] }
        return r[2] > c[2]
    }

    struct UpdateError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
