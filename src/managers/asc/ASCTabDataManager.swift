import Foundation

extension ASCManager {
    func ensureTabData(_ tab: AppTab) async {
        guard credentials != nil else { return }

        if loadedTabs.contains(tab) {
            if shouldRefreshTabCache(tab) {
                await refreshTabData(tab)
            }
            return
        }

        await fetchTabData(tab)
    }

    func hasLoadedTabData(_ tab: AppTab) -> Bool {
        loadedTabs.contains(tab)
    }

    func isTabLoading(_ tab: AppTab) -> Bool {
        isLoadingTab[tab] == true || isLoadingApp
    }

    func isFeedbackLoading(for buildId: String?) -> Bool {
        guard let buildId, !buildId.isEmpty else {
            return isLoadingTab[.feedback] == true
        }
        return loadingFeedbackBuildIds.contains(buildId)
    }

    @discardableResult
    func fetchApp(bundleId: String, exactName: String? = nil) async -> Bool {
        guard let service else { return false }
        isLoadingApp = true
        do {
            let fetched = try await service.fetchApp(bundleId: bundleId, exactName: exactName)
            app = fetched
            credentialsError = nil
            isLoadingApp = false
            return true
        } catch {
            app = nil
            credentialsError = error.localizedDescription
            isLoadingApp = false
            return false
        }
    }

    func fetchTabData(_ tab: AppTab) async {
        guard let service else { return }
        guard credentials != nil else { return }
        guard !loadedTabs.contains(tab) else { return }
        guard isLoadingTab[tab] != true else { return }

        cancelBackgroundHydration(for: tab)
        isLoadingTab[tab] = true
        tabError.removeValue(forKey: tab)

        do {
            try await loadData(for: tab, service: service)
            isLoadingTab[tab] = false
            loadedTabs.insert(tab)
            tabLoadedAt[tab] = Date()
        } catch {
            isLoadingTab[tab] = false
            tabError[tab] = error.localizedDescription
        }
    }

    /// Called after bundle ID setup completes and the app is confirmed in ASC.
    /// Clears all tab errors and forces data to be re-fetched.
    func resetTabState() {
        cancelBackgroundHydrationTasks()
        tabError.removeAll()
        loadedTabs.removeAll()
        tabLoadedAt.removeAll()
        loadingFeedbackBuildIds = []
    }

    func refreshTabData(_ tab: AppTab) async {
        guard let service else { return }
        guard credentials != nil else { return }

        let hadLoadedData = loadedTabs.contains(tab)
        cancelBackgroundHydration(for: tab)
        isLoadingTab[tab] = true
        tabError.removeValue(forKey: tab)

        do {
            try await loadData(for: tab, service: service)
            isLoadingTab[tab] = false
            loadedTabs.insert(tab)
            tabLoadedAt[tab] = Date()
        } catch {
            isLoadingTab[tab] = false
            if !hadLoadedData {
                loadedTabs.remove(tab)
                tabLoadedAt.removeValue(forKey: tab)
            }
            tabError[tab] = error.localizedDescription
        }
    }

    func refreshSubmissionReadinessData() async {
        await refreshMonetization()
        await refreshAttachedSubmissionItemIDs()
    }

    func startOverviewReadinessLoading(_ fields: Set<String>) {
        overviewReadinessLoadingFields = fields
    }

    func finishOverviewReadinessLoading(_ fields: Set<String>) {
        overviewReadinessLoadingFields.subtract(fields)
    }

    func isCurrentProject(_ projectId: String?) -> Bool {
        guard let projectId else { return false }
        return loadedProjectId == projectId
    }

    private func hydrateOverviewSecondaryData(
        projectId: String?,
        appId: String,
        firstLocalizationId: String?,
        firstLocalizationLocale: String?,
        appInfoId: String?,
        service: AppStoreConnectService
    ) async {
        if let firstLocalizationId, let firstLocalizationLocale {
            do {
                let fetchedSets = try await service.fetchScreenshotSets(localizationId: firstLocalizationId)
                let fetchedScreenshots = try await withThrowingTaskGroup(of: (String, [ASCScreenshot]).self) { group in
                    for set in fetchedSets {
                        group.addTask {
                            let screenshots = try await service.fetchScreenshots(setId: set.id)
                            return (set.id, screenshots)
                        }
                    }

                    var pairs: [(String, [ASCScreenshot])] = []
                    for try await pair in group {
                        pairs.append(pair)
                    }
                    return pairs
                }

                guard !Task.isCancelled, isCurrentProject(projectId) else { return }
                cacheScreenshots(
                    locale: firstLocalizationLocale,
                    sets: fetchedSets,
                    screenshots: Dictionary(uniqueKeysWithValues: fetchedScreenshots)
                )
                finishOverviewReadinessLoading(Self.overviewScreenshotFieldLabels)
            } catch {
                print("Failed to hydrate overview screenshots: \(error)")
                finishOverviewReadinessLoading(Self.overviewScreenshotFieldLabels)
            }
        } else {
            finishOverviewReadinessLoading(Self.overviewScreenshotFieldLabels)
        }

        if let appInfoId {
            async let ageRatingTask: ASCAgeRatingDeclaration? = try? service.fetchAgeRating(appInfoId: appInfoId)
            async let appInfoLocalizationTask: ASCAppInfoLocalization? = try? service.fetchAppInfoLocalization(appInfoId: appInfoId)

            let fetchedAgeRating = await ageRatingTask
            let fetchedAppInfoLocalization = await appInfoLocalizationTask

            guard !Task.isCancelled, isCurrentProject(projectId) else { return }
            ageRatingDeclaration = fetchedAgeRating
            appInfoLocalization = fetchedAppInfoLocalization
            finishOverviewReadinessLoading(Self.overviewMetadataFieldLabels)
        } else {
            finishOverviewReadinessLoading(Self.overviewMetadataFieldLabels)
        }

        guard !Task.isCancelled, isCurrentProject(projectId) else { return }
        await refreshReviewSubmissionData(appId: appId, service: service)
        guard !Task.isCancelled, isCurrentProject(projectId) else { return }
        rebuildSubmissionHistory(appId: appId)
        refreshSubmissionFeedbackIfNeeded()

        if monetizationStatus == nil {
            let hasPricing = await service.fetchPricingConfigured(appId: appId)
            guard !Task.isCancelled, isCurrentProject(projectId) else { return }
            monetizationStatus = hasPricing ? "Configured" : nil
        }

        guard !Task.isCancelled, isCurrentProject(projectId) else { return }
        await refreshSubmissionReadinessData()
        finishOverviewReadinessLoading(Self.overviewPricingFieldLabels)
    }

    private func hydrateScreenshotsSecondaryData(
        projectId: String?,
        locale: String,
        localizationId: String,
        service: AppStoreConnectService
    ) async {
        do {
            let (fetchedSets, fetchedScreenshots) = try await fetchScreenshotData(
                localizationId: localizationId,
                service: service
            )
            guard !Task.isCancelled, isCurrentProject(projectId) else { return }
            storeScreenshots(
                locale: locale,
                sets: fetchedSets,
                screenshots: fetchedScreenshots,
                makeActive: true
            )
        } catch {
            print("Failed to hydrate screenshots: \(error)")
        }
    }

    private func hydrateReviewSecondaryData(
        projectId: String?,
        appId: String,
        appInfoId: String?,
        service: AppStoreConnectService
    ) async {
        if let appInfoId {
            let fetchedAgeRating = try? await service.fetchAgeRating(appInfoId: appInfoId)
            guard !Task.isCancelled, isCurrentProject(projectId) else { return }
            ageRatingDeclaration = fetchedAgeRating
        } else {
            ageRatingDeclaration = nil
        }

        guard !Task.isCancelled, isCurrentProject(projectId) else { return }
        await refreshReviewSubmissionData(appId: appId, service: service)
        guard !Task.isCancelled, isCurrentProject(projectId) else { return }
        rebuildSubmissionHistory(appId: appId)
        refreshSubmissionFeedbackIfNeeded()
    }

    private func hydrateMonetizationSecondaryData(
        projectId: String?,
        appId: String,
        groups: [ASCSubscriptionGroup],
        service: AppStoreConnectService
    ) async {
        do {
            let fetchedSubscriptions = try await withThrowingTaskGroup(of: (String, [ASCSubscription]).self) { taskGroup in
                for subscriptionGroup in groups {
                    taskGroup.addTask {
                        let subscriptions = try await service.fetchSubscriptionsInGroup(groupId: subscriptionGroup.id)
                        return (subscriptionGroup.id, subscriptions)
                    }
                }

                var pairs: [(String, [ASCSubscription])] = []
                for try await pair in taskGroup {
                    pairs.append(pair)
                }
                return pairs
            }

            guard !Task.isCancelled, isCurrentProject(projectId) else { return }
            subscriptionsPerGroup = Dictionary(uniqueKeysWithValues: fetchedSubscriptions)
        } catch {
            print("Failed to hydrate monetization subscriptions: \(error)")
        }

        if currentAppPricePointId == nil && scheduledAppPricePointId == nil && monetizationStatus == nil {
            let hasPricing = await service.fetchPricingConfigured(appId: appId)
            guard !Task.isCancelled, isCurrentProject(projectId) else { return }
            monetizationStatus = hasPricing ? "Configured" : nil
        }
    }

    private func hydrateFeedbackSecondaryData(
        projectId: String?,
        buildId: String,
        service: AppStoreConnectService
    ) async {
        guard isCurrentProject(projectId) else { return }
        guard !Task.isCancelled else { return }
        loadingFeedbackBuildIds.insert(buildId)
        defer { loadingFeedbackBuildIds.remove(buildId) }

        do {
            let items = try await service.fetchBetaFeedback(buildId: buildId)
            guard !Task.isCancelled, isCurrentProject(projectId) else { return }
            betaFeedback[buildId] = items
        } catch {
            guard !Task.isCancelled, isCurrentProject(projectId) else { return }
            betaFeedback[buildId] = []
        }
    }

    private func loadData(for tab: AppTab, service: AppStoreConnectService) async throws {
        guard let appId = app?.id else {
            throw ASCError.notFound("App - check your bundle ID in project settings")
        }

        switch tab {
        case .app:
            refreshAppIconStatusIfNeeded(for: loadedProjectId)
            startOverviewReadinessLoading(
                Self.overviewLocalizationFieldLabels
                    .union(Self.overviewVersionFieldLabels)
                    .union(Self.overviewAppInfoFieldLabels)
                    .union(Self.overviewMetadataFieldLabels)
                    .union(Self.overviewReviewFieldLabels)
                    .union(Self.overviewBuildFieldLabels)
                    .union(Self.overviewPricingFieldLabels)
                    .union(Self.overviewScreenshotFieldLabels)
            )
            async let versionsTask = service.fetchAppStoreVersions(appId: appId)
            async let appInfoTask: ASCAppInfo? = try? service.fetchAppInfo(appId: appId)
            async let buildsTask = service.fetchBuilds(appId: appId)

            let versions = try await versionsTask
            appStoreVersions = versions
            finishOverviewReadinessLoading(Self.overviewVersionFieldLabels)
            appInfo = await appInfoTask
            finishOverviewReadinessLoading(Self.overviewAppInfoFieldLabels)
            builds = try await buildsTask
            finishOverviewReadinessLoading(Self.overviewBuildFieldLabels)

            var firstLocalizationId: String?
            var firstLocalizationLocale: String?
            if let latestId = versions.first?.id {
                async let localizationsTask = service.fetchLocalizations(versionId: latestId)
                async let reviewDetailTask: ASCReviewDetail? = try? service.fetchReviewDetail(versionId: latestId)

                let fetchedLocalizations = try await localizationsTask
                localizations = fetchedLocalizations
                firstLocalizationId = fetchedLocalizations.first?.id
                firstLocalizationLocale = fetchedLocalizations.first?.attributes.locale
                finishOverviewReadinessLoading(Self.overviewLocalizationFieldLabels)
                reviewDetail = await reviewDetailTask
                finishOverviewReadinessLoading(Self.overviewReviewFieldLabels)
            } else {
                finishOverviewReadinessLoading(
                    Self.overviewLocalizationFieldLabels
                        .union(Self.overviewReviewFieldLabels)
                )
            }

            refreshSubmissionFeedbackIfNeeded()

            let projectId = loadedProjectId
            let currentAppInfoId = appInfo?.id
            startBackgroundHydration(for: .app) {
                await self.hydrateOverviewSecondaryData(
                    projectId: projectId,
                    appId: appId,
                    firstLocalizationId: firstLocalizationId,
                    firstLocalizationLocale: firstLocalizationLocale,
                    appInfoId: currentAppInfoId,
                    service: service
                )
            }

        case .storeListing:
            try await refreshStoreListingMetadata(
                service: service,
                appId: appId,
                preferredLocale: selectedStoreListingLocale
            )

        case .screenshots:
            let versions = try await service.fetchAppStoreVersions(appId: appId)
            appStoreVersions = versions
            if let latestId = versions.first?.id {
                let localizations = try await service.fetchLocalizations(versionId: latestId)
                self.localizations = localizations
                let preferredLocale = selectedScreenshotsLocale ?? activeScreenshotsLocale
                let targetLocalization = localizations.first(where: { $0.attributes.locale == preferredLocale })
                    ?? localizations.first
                if let targetLocalization {
                    selectedScreenshotsLocale = targetLocalization.attributes.locale
                    let projectId = loadedProjectId
                    startBackgroundHydration(for: .screenshots) {
                        await self.hydrateScreenshotsSecondaryData(
                            projectId: projectId,
                            locale: targetLocalization.attributes.locale,
                            localizationId: targetLocalization.id,
                            service: service
                        )
                    }
                } else {
                    screenshotSets = []
                    screenshots = [:]
                    screenshotSetsByLocale = [:]
                    screenshotsByLocale = [:]
                    selectedScreenshotsLocale = nil
                    activeScreenshotsLocale = nil
                    lastScreenshotDataLocale = nil
                }
            } else {
                localizations = []
                screenshotSets = []
                screenshots = [:]
                screenshotSetsByLocale = [:]
                screenshotsByLocale = [:]
                selectedScreenshotsLocale = nil
                activeScreenshotsLocale = nil
                lastScreenshotDataLocale = nil
            }

        case .appDetails:
            async let versionsTask = service.fetchAppStoreVersions(appId: appId)
            async let appInfoTask: ASCAppInfo? = try? await service.fetchAppInfo(appId: appId)

            appStoreVersions = try await versionsTask
            appInfo = await appInfoTask

        case .review:
            async let versionsTask = service.fetchAppStoreVersions(appId: appId)
            async let appInfoTask: ASCAppInfo? = try? await service.fetchAppInfo(appId: appId)
            async let buildsTask = service.fetchBuilds(appId: appId)

            let versions = try await versionsTask
            appStoreVersions = versions
            if let latestId = versions.first?.id {
                reviewDetail = try? await service.fetchReviewDetail(versionId: latestId)
            } else {
                reviewDetail = nil
            }
            appInfo = await appInfoTask
            builds = try await buildsTask
            let projectId = loadedProjectId
            let currentAppInfoId = appInfo?.id
            startBackgroundHydration(for: .review) {
                await self.hydrateReviewSecondaryData(
                    projectId: projectId,
                    appId: appId,
                    appInfoId: currentAppInfoId,
                    service: service
                )
            }

        case .monetization:
            async let pricePointsTask = service.fetchAppPricePoints(appId: appId)
            async let pricingStateTask = (try? await service.fetchAppPricingState(appId: appId))
                ?? ASCAppPricingState(currentPricePointId: nil, scheduledPricePointId: nil, scheduledEffectiveDate: nil)
            async let iapTask = service.fetchInAppPurchases(appId: appId)
            async let groupsTask = service.fetchSubscriptionGroups(appId: appId)

            appPricePoints = try await pricePointsTask
            applyAppPricingState(await pricingStateTask)
            inAppPurchases = try await iapTask
            let groups = try await groupsTask
            subscriptionGroups = groups

            let projectId = loadedProjectId
            startBackgroundHydration(for: .monetization) {
                await self.hydrateMonetizationSecondaryData(
                    projectId: projectId,
                    appId: appId,
                    groups: groups,
                    service: service
                )
            }

        case .analytics:
            break

        case .reviews:
            customerReviews = try await service.fetchCustomerReviews(appId: appId)

        case .builds:
            builds = try await service.fetchBuilds(appId: appId)

        case .groups:
            betaGroups = try await service.fetchBetaGroups(appId: appId)

        case .betaInfo:
            betaLocalizations = try await service.fetchBetaLocalizations(appId: appId)

        case .feedback:
            let fetchedBuilds = try await service.fetchBuilds(appId: appId)
            builds = fetchedBuilds
            let resolvedBuildId: String?
            if let currentSelectedBuildId = selectedBuildId,
               fetchedBuilds.contains(where: { $0.id == currentSelectedBuildId }) {
                resolvedBuildId = currentSelectedBuildId
            } else {
                resolvedBuildId = fetchedBuilds.first?.id
            }
            selectedBuildId = resolvedBuildId
            if let resolvedBuildId {
                let projectId = loadedProjectId
                startBackgroundHydration(for: .feedback) {
                    await self.hydrateFeedbackSecondaryData(
                        projectId: projectId,
                        buildId: resolvedBuildId,
                        service: service
                    )
                }
            } else {
                betaFeedback = [:]
            }

        default:
            break
        }
    }
}
