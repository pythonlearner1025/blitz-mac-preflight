import Foundation

@MainActor
@Observable
final class DashboardSummaryStore {
    static let shared = DashboardSummaryStore()

    private static let freshness: TimeInterval = 120

    var summary = ASCDashboardSummary.empty
    var projectStatuses: [String: ASCDashboardProjectStatus] = [:]
    var hasLoadedSummary = false
    var isLoadingSummary = false

    private(set) var cacheKey: String?
    private var refreshedAt: Date?

    private init() {}

    func shouldRefresh(for key: String) -> Bool {
        guard cacheKey == key, let refreshedAt else { return true }
        return Date().timeIntervalSince(refreshedAt) > Self.freshness
    }

    func isLoading(for key: String) -> Bool {
        isLoadingSummary && cacheKey == key
    }

    func beginLoading(for key: String) {
        if cacheKey != key {
            summary = .empty
            projectStatuses = [:]
            hasLoadedSummary = false
        }
        cacheKey = key
        isLoadingSummary = true
    }

    func store(summary: ASCDashboardSummary, projectStatuses: [String: ASCDashboardProjectStatus], for key: String) {
        self.summary = summary
        self.projectStatuses = projectStatuses
        hasLoadedSummary = true
        cacheKey = key
        refreshedAt = Date()
        isLoadingSummary = false
    }

    func markEmpty(for key: String) {
        summary = .empty
        projectStatuses = [:]
        hasLoadedSummary = true
        cacheKey = key
        refreshedAt = Date()
        isLoadingSummary = false
    }

    func markUnavailable(for key: String) {
        summary = .empty
        projectStatuses = [:]
        hasLoadedSummary = false
        cacheKey = key
        refreshedAt = Date()
        isLoadingSummary = false
    }

    func cancelLoading(for key: String) {
        guard cacheKey == key else { return }
        isLoadingSummary = false
    }
}
