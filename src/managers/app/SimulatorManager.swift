import Foundation

@MainActor
@Observable
final class SimulatorManager {
    var simulators: [SimulatorInfo] = []
    var bootedDeviceId: String?
    var isStreaming = false
    var isBooting = false
    var bootingDeviceName: String?

    func loadSimulators() async {
        let client = SimctlClient()
        do {
            let devices = try await client.listDevices()
            simulators = devices.map { device in
                SimulatorInfo(
                    udid: device.udid,
                    name: device.name,
                    state: device.state,
                    deviceTypeIdentifier: device.deviceTypeIdentifier,
                    lastBootedAt: device.lastBootedAt
                )
            }
            // Only auto-select a booted device if it's supported
            bootedDeviceId = simulators.first(where: {
                $0.isBooted && SimulatorConfigDatabase.isSupported($0.name)
            })?.udid
        } catch {
            print("Failed to load simulators: \(error)")
        }
    }

    /// Boot a simulator if none is currently running. Called when a project opens.
    /// Prefers supported devices (iPhone 16/17); falls back to any iPhone.
    func bootIfNeeded() async {
        await loadSimulators()

        // If a supported device is already booted, keep it
        if let bootedId = bootedDeviceId,
           let booted = simulators.first(where: { $0.udid == bootedId }),
           SimulatorConfigDatabase.isSupported(booted.name) { return }

        // Otherwise pick a supported device to boot (prefer shutdown ones to avoid conflicts)
        guard let target = simulators.first(where: {
            SimulatorConfigDatabase.isSupported($0.name) && !$0.isBooted
        }) ?? simulators.first(where: {
            SimulatorConfigDatabase.isSupported($0.name)
        }) else { return }

        isBooting = true
        defer { isBooting = false }

        let service = SimulatorService()
        do {
            try await service.boot(udid: target.udid)
            bootedDeviceId = target.udid
            await loadSimulators()
        } catch {
            print("Failed to auto-boot simulator: \(error)")
        }
    }

    /// Shutdown the booted simulator. Called on app quit.
    func shutdownBooted() {
        guard let udid = bootedDeviceId else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "shutdown", udid]
        try? process.run()
        process.waitUntilExit()
    }
}
