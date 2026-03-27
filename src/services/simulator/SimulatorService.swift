import AppKit
import Foundation
import os

private let logger = Logger(subsystem: "com.blitz.macos", category: "SimulatorService")

/// High-level simulator management service
actor SimulatorService {
    private let simctl = SimctlClient()

    /// List all available simulators
    func listDevices() async throws -> [SimctlClient.SimctlDevice] {
        try await simctl.listDevices()
    }

    /// Boot a simulator, then opens Simulator.app to show its window
    func boot(udid: String) async throws {
        logger.info("Booting simulator \(udid)...")

        // Boot the specific device FIRST — before opening Simulator.app,
        // otherwise Simulator.app auto-boots its last-used device.
        do {
            try await simctl.boot(udid: udid)
        } catch {
            // "Unable to boot device in current state: Booted" is not a real error
            if let processError = error as? ProcessRunner.ProcessError,
               processError.stderr.contains("current state: Booted") {
                logger.info("Simulator already booted")
            } else {
                throw error
            }
        }

        // Wait for boot to complete — poll until state is Booted
        logger.info("Waiting for simulator to finish booting...")
        for i in 1...15 {
            let devices = try await simctl.listDevices()
            if let device = devices.first(where: { $0.udid == udid }), device.isBooted {
                logger.info("Simulator booted after \(i)s")
                break
            }
            try await Task.sleep(for: .seconds(1))
        }

        // Open Simulator.app AFTER boot so it shows the correct device window
        // (opening before boot causes it to auto-boot its last-used device)
        try await openSimulatorApp()
    }

    /// Boot a simulator without bringing Simulator.app to the foreground.
    func bootInBackground(udid: String) async throws {
        logger.info("Booting simulator \(udid) in background...")

        do {
            try await simctl.boot(udid: udid)
        } catch {
            if let processError = error as? ProcessRunner.ProcessError,
               processError.stderr.contains("current state: Booted") {
                logger.info("Simulator already booted")
            } else {
                throw error
            }
        }

        // Wait for boot
        for i in 1...15 {
            let devices = try await simctl.listDevices()
            if let device = devices.first(where: { $0.udid == udid }), device.isBooted {
                logger.info("Simulator booted after \(i)s")
                break
            }
            try await Task.sleep(for: .seconds(1))
        }

        // Open Simulator.app
        try await openSimulatorApp()
    }

    /// Shutdown a simulator
    func shutdown(udid: String) async throws {
        try await simctl.shutdown(udid: udid)
    }

    /// Install an app bundle
    func installApp(udid: String, appPath: String) async throws {
        try await simctl.install(udid: udid, appPath: appPath)
    }

    /// Launch an app by bundle ID
    func launchApp(udid: String, bundleId: String) async throws {
        try await simctl.launch(udid: udid, bundleId: bundleId)
    }

    /// Take a screenshot and save to path
    func screenshot(udid: String, saveTo path: String) async throws {
        try await simctl.screenshot(udid: udid, path: path)
    }

    /// Open the Simulator.app (-g flag opens in background)
    func openSimulatorApp() async throws {
        _ = try await ProcessRunner.run("open", arguments: ["-g", "-a", "Simulator"])
        try await Task.sleep(for: .milliseconds(500))
    }

    /// Move Simulator.app's window to the same position as Blitz's window
    /// using the Accessibility API, so it's completely hidden behind Blitz.
    private static func moveSimulatorWindowBehind(blitzFrame: NSRect) {
        guard let simApp = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.iphonesimulator"
        ).first else { return }

        let appRef = AXUIElementCreateApplication(simApp.processIdentifier)

        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement],
              let simWindow = windows.first else { return }

        // Accessibility uses top-left origin; NSRect uses bottom-left
        let screenHeight = NSScreen.main?.frame.height ?? 0
        var position = CGPoint(
            x: blitzFrame.origin.x,
            y: screenHeight - blitzFrame.origin.y - blitzFrame.height
        )
        if let posValue = AXValueCreate(.cgPoint, &position) {
            AXUIElementSetAttributeValue(simWindow, kAXPositionAttribute as CFString, posValue)
        }

        var size = CGSize(width: blitzFrame.width, height: blitzFrame.height)
        if let sizeValue = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(simWindow, kAXSizeAttribute as CFString, sizeValue)
        }
    }
}
