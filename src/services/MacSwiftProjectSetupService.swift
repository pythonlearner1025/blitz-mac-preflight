import Foundation

/// Scaffolds a new macOS Swift/SwiftUI project from the bundled template.
/// Sandboxed by default for Mac App Store submission.
struct MacSwiftProjectSetupService {

    /// Set up a new macOS Swift project from the bundled template.
    static func setup(
        projectId: String,
        projectName: String,
        projectPath: String,
        onStep: @MainActor (ProjectSetupService.SetupStep) -> Void
    ) async throws {

        let fm = FileManager.default
        let appName = SwiftProjectSetupService.toSwiftAppName(projectId)
        let bundleId = SwiftProjectSetupService.toBundleId(appName)

        // --- Step 1: Copy & patch template ---
        await onStep(.copying)
        print("[mac-swift-setup] Scaffolding: appName=\(appName) bundleId=\(bundleId)")

        guard let templateURL = Bundle.appResources.url(forResource: "swift-mac-template", withExtension: nil, subdirectory: "templates") else {
            throw ProjectSetupService.SetupError(message: "Bundled macOS Swift template not found")
        }

        // Back up project metadata before overwriting dir
        let metadataPath = projectPath + "/.blitz/project.json"
        let metadataData = try? Data(contentsOf: URL(fileURLWithPath: metadataPath))

        // Remove existing (near-empty) project dir
        if fm.fileExists(atPath: projectPath) {
            try fm.removeItem(atPath: projectPath)
        }
        try fm.createDirectory(atPath: projectPath, withIntermediateDirectories: true)

        // Recursively copy template, replacing placeholders in names & contents
        try copyTemplateDir(
            src: templateURL.path,
            dest: projectPath,
            appName: appName,
            bundleId: bundleId
        )

        // Restore project metadata
        let blitzDir = projectPath + "/.blitz"
        if !fm.fileExists(atPath: blitzDir) {
            try fm.createDirectory(atPath: blitzDir, withIntermediateDirectories: true)
        }
        if let data = metadataData {
            try data.write(to: URL(fileURLWithPath: metadataPath))
        }

        print("[mac-swift-setup] Template copied and patched")

        // No npm install needed for Swift projects — go straight to ready
        await onStep(.ready)
        print("[mac-swift-setup] Project setup complete!")
    }

    // MARK: - Helpers

    private static let appNamePlaceholder = "__APP_NAME__"
    private static let bundleIdPlaceholder = "__BUNDLE_ID__"

    private static func copyTemplateDir(
        src: String,
        dest: String,
        appName: String,
        bundleId: String
    ) throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: dest, withIntermediateDirectories: true)

        let entries = try fm.contentsOfDirectory(atPath: src)
        for entry in entries {
            let resolvedName = entry.replacingOccurrences(of: appNamePlaceholder, with: appName)
            let srcPath = src + "/" + entry
            let destPath = dest + "/" + resolvedName

            var isDir: ObjCBool = false
            fm.fileExists(atPath: srcPath, isDirectory: &isDir)

            if isDir.boolValue {
                try copyTemplateDir(src: srcPath, dest: destPath, appName: appName, bundleId: bundleId)
            } else {
                var content = try String(contentsOfFile: srcPath, encoding: .utf8)
                content = content
                    .replacingOccurrences(of: appNamePlaceholder, with: appName)
                    .replacingOccurrences(of: bundleIdPlaceholder, with: bundleId)
                try content.write(toFile: destPath, atomically: true, encoding: .utf8)
            }
        }
    }
}
