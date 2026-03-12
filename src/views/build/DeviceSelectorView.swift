import SwiftUI

struct DeviceSelectorView: View {
    @Bindable var appState: AppState
    @State private var isBooting = false

    var body: some View {
        Menu {
            Section("Simulators") {
                ForEach(appState.simulatorManager.simulators) { sim in
                    Button(action: {
                        Task { await selectSimulator(sim) }
                    }) {
                        HStack {
                            Text(sim.name)
                            if sim.isBooted {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }

                if appState.simulatorManager.simulators.isEmpty {
                    Text("No simulators found")
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            Button("Refresh Devices") {
                Task { await appState.simulatorManager.loadSimulators() }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "iphone")
                if let bootedId = appState.simulatorManager.bootedDeviceId,
                   let sim = appState.simulatorManager.simulators.first(where: { $0.udid == bootedId }) {
                    Text(sim.name)
                        .font(.system(size: 11))
                } else {
                    Text("Select Device")
                        .font(.system(size: 11))
                }
                if isBooting {
                    ProgressView()
                        .scaleEffect(0.6)
                }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func selectSimulator(_ sim: SimulatorInfo) async {
        if sim.isBooted {
            appState.simulatorManager.bootedDeviceId = sim.udid
            return
        }

        isBooting = true
        defer { isBooting = false }

        let service = SimulatorService()
        do {
            try await service.boot(udid: sim.udid)
            appState.simulatorManager.bootedDeviceId = sim.udid
            await appState.simulatorManager.loadSimulators()
        } catch {
            print("Failed to boot simulator: \(error)")
        }
    }
}
