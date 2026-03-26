import Foundation

@MainActor
@Observable
final class SimulatorStreamManager {
    let captureService = SimulatorCaptureService()
    var renderer: MetalRenderer?
    var isCapturing = false
    var errorMessage: String?
    var statusMessage: String?
    /// True when the stream was paused by a tab switch (not manually stopped)
    var isPaused = false

    private var rendererInitialized = false

    func ensureRenderer() {
        guard !rendererInitialized else { return }
        rendererInitialized = true
        do {
            renderer = try MetalRenderer()
        } catch {
            errorMessage = "Metal init failed: \(error.localizedDescription)"
        }
    }

    /// Full start: ensure renderer, open Simulator.app, connect SCStream.
    func startStreaming(bootedDeviceId: String?) async {
        guard !isCapturing else { return }
        guard bootedDeviceId != nil else {
            statusMessage = "No simulator booted"
            return
        }

        errorMessage = nil
        isPaused = false
        ensureRenderer()

        statusMessage = "Opening Simulator.app..."
        let service = SimulatorService()
        try? await service.openSimulatorApp()

        statusMessage = "Connecting to simulator..."
        do {
            try await captureService.startCapture(retryForWindow: true)
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = nil
            return
        }

        if captureService.isCapturing {
            isCapturing = true
            statusMessage = nil
        }
    }

    /// Full stop: stop SCStream, clear state.
    func stopStreaming() async {
        await captureService.stopCapture()
        isCapturing = false
        isPaused = false
    }

    /// Pause: stop SCStream but keep simulator booted. Lightweight for tab switches.
    func pauseStream() async {
        guard isCapturing else { return }
        isPaused = true
        await captureService.stopCapture()
        isCapturing = false
    }

    /// Resume: restart SCStream after a pause. No window retry needed since sim is already running.
    func resumeStream() async {
        guard isPaused else { return }
        isPaused = false
        ensureRenderer()

        do {
            try await captureService.startCapture(retryForWindow: false)
            if captureService.isCapturing {
                isCapturing = true
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
