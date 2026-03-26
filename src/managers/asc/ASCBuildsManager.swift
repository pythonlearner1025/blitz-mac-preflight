import Foundation

// MARK: - Builds Manager
// Extension containing builds-related functionality for ASCManager

extension ASCManager {
    // MARK: - Beta Feedback

    func refreshBetaFeedback(buildId: String) async {
        guard let service else { return }
        guard !buildId.isEmpty else { return }

        loadingFeedbackBuildIds.insert(buildId)
        defer { loadingFeedbackBuildIds.remove(buildId) }

        do {
            betaFeedback[buildId] = try await service.fetchBetaFeedback(buildId: buildId)
        } catch {
            // Feedback may not be available for all apps; non-fatal.
            betaFeedback[buildId] = []
        }
    }
}

