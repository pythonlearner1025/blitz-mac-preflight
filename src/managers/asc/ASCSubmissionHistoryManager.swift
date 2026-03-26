import Foundation

extension ASCManager {
    func buildFeedbackCache(appId: String, versionString: String) -> IrisFeedbackCache {
        let messages = rejectionMessages.map { message in
            IrisFeedbackCache.CachedMessage(
                body: message.attributes.messageBody.map { htmlToPlainText($0) } ?? "",
                date: message.attributes.createdDate
            )
        }
        let reasons = rejectionReasons.flatMap { rejection in
            (rejection.attributes.reasons ?? []).map { reason in
                IrisFeedbackCache.CachedReason(
                    section: reason.reasonSection ?? "",
                    description: reason.reasonDescription ?? "",
                    code: reason.reasonCode ?? ""
                )
            }
        }

        return IrisFeedbackCache(
            appId: appId,
            versionString: versionString,
            fetchedAt: Date(),
            messages: messages,
            reasons: reasons
        )
    }

    func rebuildSubmissionHistory(appId: String) {
        let cache = refreshSubmissionHistoryCache(appId: appId)
        let versionSnapshots = cache.versionSnapshots

        let submissionEvents = reviewSubmissions.compactMap { submission -> ASCSubmissionHistoryEvent? in
            guard let submittedAt = submission.attributes.submittedDate else { return nil }
            let versionId = reviewSubmissionItemsBySubmissionId[submission.id]?
                .compactMap(\.appStoreVersionId)
                .first
                ?? closestVersion(before: submittedAt)?.id
            let resolvedVersionString = versionString(for: versionId, versionSnapshots: versionSnapshots) ?? "Unknown"
            let resolvedVersionState = versionState(for: versionId, versionSnapshots: versionSnapshots)
            let eventType = ASCReleaseStatus.reviewSubmissionEventType(forVersionState: resolvedVersionState)
            return ASCSubmissionHistoryEvent(
                id: "submission:\(submission.id)",
                versionId: versionId,
                versionString: resolvedVersionString,
                eventType: eventType,
                appleState: resolvedVersionState ?? "WAITING_FOR_REVIEW",
                occurredAt: submittedAt,
                source: .reviewSubmission,
                accuracy: .exact,
                submissionId: submission.id,
                note: nil
            )
        }

        var rejectionEventsByVersion: [String: ASCSubmissionHistoryEvent] = [:]
        for cacheEntry in IrisFeedbackCache.loadAll(appId: appId) {
            let rejectionAt = cacheEntry.messages
                .compactMap(\.date)
                .sorted(by: { historyDate($0) < historyDate($1) })
                .first
                ?? ISO8601DateFormatter().string(from: cacheEntry.fetchedAt)

            rejectionEventsByVersion[cacheEntry.versionString] = ASCSubmissionHistoryEvent(
                id: "iris:\(cacheEntry.versionString):\(rejectionAt)",
                versionId: versionId(for: cacheEntry.versionString, versionSnapshots: versionSnapshots),
                versionString: cacheEntry.versionString,
                eventType: .rejected,
                appleState: "REJECTED",
                occurredAt: rejectionAt,
                source: .irisFeedback,
                accuracy: .derived,
                submissionId: nil,
                note: cacheEntry.reasons.first?.section
            )
        }

        if let rejectedVersion = appStoreVersions.first(where: { $0.attributes.appStoreState == "REJECTED" }) {
            let rejectionAt = resolutionCenterThreads.first?.attributes.createdDate
                ?? rejectionMessages.compactMap(\.attributes.createdDate)
                    .sorted(by: { historyDate($0) < historyDate($1) })
                    .first
            if let rejectionAt {
                rejectionEventsByVersion[rejectedVersion.attributes.versionString] = ASCSubmissionHistoryEvent(
                    id: "iris-live:\(rejectedVersion.id):\(rejectionAt)",
                    versionId: rejectedVersion.id,
                    versionString: rejectedVersion.attributes.versionString,
                    eventType: .rejected,
                    appleState: "REJECTED",
                    occurredAt: rejectionAt,
                    source: .irisFeedback,
                    accuracy: .derived,
                    submissionId: nil,
                    note: rejectionReasons.first?.attributes.reasons?.first?.reasonSection
                )
            }
        }

        let durableEvents = submissionEvents
            + Array(rejectionEventsByVersion.values)
            + cache.transitionEvents

        let coveredEventKeys = Set(
            durableEvents.map {
                historyCoverageKey(versionId: $0.versionId, versionString: $0.versionString, eventType: $0.eventType)
            }
        )

        let fallbackEvents = appStoreVersions.compactMap { version -> ASCSubmissionHistoryEvent? in
            let state = version.attributes.appStoreState ?? ""
            guard let eventType = historyEventType(forVersionState: state) else { return nil }

            let coverageKey = historyCoverageKey(
                versionId: version.id,
                versionString: version.attributes.versionString,
                eventType: eventType
            )
            guard !coveredEventKeys.contains(coverageKey) else { return nil }

            let occurredAt = version.attributes.createdDate
                ?? cache.versionSnapshots[version.id]?.lastSeenAt
                ?? historyNowString()

            return ASCSubmissionHistoryEvent(
                id: "version:\(version.id):\(state)",
                versionId: version.id,
                versionString: version.attributes.versionString,
                eventType: eventType,
                appleState: state,
                occurredAt: occurredAt,
                source: .currentVersion,
                accuracy: .derived,
                submissionId: nil,
                note: nil
            )
        }

        submissionHistoryEvents = (durableEvents + fallbackEvents)
            .sorted { lhs, rhs in
                historyDate(lhs.occurredAt) > historyDate(rhs.occurredAt)
            }
    }

    func refreshReviewSubmissionData(appId: String, service: AppStoreConnectService) async {
        let submissions = (try? await service.fetchReviewSubmissions(appId: appId)) ?? []
        reviewSubmissions = submissions

        guard !submissions.isEmpty else {
            reviewSubmissionItemsBySubmissionId = [:]
            latestSubmissionItems = []
            return
        }

        var itemsBySubmissionId: [String: [ASCReviewSubmissionItem]] = [:]
        await withTaskGroup(of: (String, [ASCReviewSubmissionItem]).self) { group in
            for submission in submissions {
                group.addTask {
                    let items = (try? await service.fetchReviewSubmissionItems(submissionId: submission.id)) ?? []
                    return (submission.id, items)
                }
            }

            for await (submissionId, items) in group {
                itemsBySubmissionId[submissionId] = items
            }
        }

        reviewSubmissionItemsBySubmissionId = itemsBySubmissionId
        latestSubmissionItems = itemsBySubmissionId[submissions.first?.id ?? ""] ?? []
    }

    private func historyNowString() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    private func historyDate(_ iso: String?) -> Date {
        guard let iso else { return .distantPast }
        let formatterWithFractionalSeconds = ISO8601DateFormatter()
        formatterWithFractionalSeconds.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let formatter = ISO8601DateFormatter()
        return formatterWithFractionalSeconds.date(from: iso) ?? formatter.date(from: iso) ?? .distantPast
    }

    private func closestVersion(before dateString: String) -> ASCAppStoreVersion? {
        let submittedDate = historyDate(dateString)
        return appStoreVersions
            .filter { historyDate($0.attributes.createdDate) <= submittedDate }
            .max { historyDate($0.attributes.createdDate) < historyDate($1.attributes.createdDate) }
            ?? ASCReleaseStatus.sortedVersionsByRecency(appStoreVersions).first
    }

    private func historyEventType(forVersionState state: String) -> ASCSubmissionHistoryEventType? {
        ASCReleaseStatus.submissionHistoryEventType(forVersionState: state)
    }

    private func historyCoverageKey(
        versionId: String?,
        versionString: String,
        eventType: ASCSubmissionHistoryEventType
    ) -> String {
        "\(versionId ?? "version:\(versionString)")::\(eventType.rawValue)"
    }

    private func versionString(
        for versionId: String?,
        versionSnapshots: [String: ASCSubmissionHistoryCache.VersionSnapshot]
    ) -> String? {
        guard let versionId else { return nil }
        if let version = appStoreVersions.first(where: { $0.id == versionId }) {
            return version.attributes.versionString
        }
        return versionSnapshots[versionId]?.versionString
    }

    private func versionId(
        for versionString: String,
        versionSnapshots: [String: ASCSubmissionHistoryCache.VersionSnapshot]
    ) -> String? {
        if let version = appStoreVersions.first(where: { $0.attributes.versionString == versionString }) {
            return version.id
        }
        return versionSnapshots.values.first(where: { $0.versionString == versionString })?.versionId
    }

    private func versionState(
        for versionId: String?,
        versionSnapshots: [String: ASCSubmissionHistoryCache.VersionSnapshot]
    ) -> String? {
        guard let versionId else { return nil }
        if let version = appStoreVersions.first(where: { $0.id == versionId }) {
            return version.attributes.appStoreState
        }
        return versionSnapshots[versionId]?.lastKnownState
    }

    private func refreshSubmissionHistoryCache(appId: String) -> ASCSubmissionHistoryCache {
        var cache = ASCSubmissionHistoryCache.load(appId: appId)
        let now = historyNowString()

        for version in appStoreVersions {
            let state = version.attributes.appStoreState ?? ""
            guard !state.isEmpty else { continue }

            if var snapshot = cache.versionSnapshots[version.id] {
                snapshot.versionString = version.attributes.versionString
                if snapshot.lastKnownState != state,
                   let eventType = historyEventType(forVersionState: state) {
                    cache.transitionEvents.append(
                        ASCSubmissionHistoryEvent(
                            id: "ledger:\(version.id):\(state):\(now)",
                            versionId: version.id,
                            versionString: version.attributes.versionString,
                            eventType: eventType,
                            appleState: state,
                            occurredAt: now,
                            source: .transitionLedger,
                            accuracy: .firstSeen,
                            submissionId: nil,
                            note: nil
                        )
                    )
                    snapshot.lastKnownState = state
                    snapshot.lastSeenAt = now
                } else {
                    snapshot.lastSeenAt = now
                }
                cache.versionSnapshots[version.id] = snapshot
            } else {
                cache.versionSnapshots[version.id] = .init(
                    versionId: version.id,
                    versionString: version.attributes.versionString,
                    lastKnownState: state,
                    lastSeenAt: now
                )
            }
        }

        cache.transitionEvents.sort { historyDate($0.occurredAt) > historyDate($1.occurredAt) }
        try? cache.save()
        return cache
    }
}
