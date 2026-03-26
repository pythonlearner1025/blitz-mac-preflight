import Foundation

// MARK: - Store Listing Manager
// Extension containing store listing-related functionality for ASCManager

extension ASCManager {
    // MARK: - Locale Selection

    func effectiveStoreListingLocale() -> String? {
        if let selectedStoreListingLocale,
           localizations.contains(where: { $0.attributes.locale == selectedStoreListingLocale }) {
            return selectedStoreListingLocale
        }
        return localizations.first?.attributes.locale
    }

    func storeListingLocalization(locale: String? = nil) -> ASCVersionLocalization? {
        if let locale,
           let localization = localizations.first(where: { $0.attributes.locale == locale }) {
            return localization
        }
        if let effectiveLocale = effectiveStoreListingLocale() {
            return localizations.first(where: { $0.attributes.locale == effectiveLocale }) ?? localizations.first
        }
        return localizations.first
    }

    func appInfoLocalizationForLocale(_ locale: String? = nil) -> ASCAppInfoLocalization? {
        if let locale {
            return appInfoLocalizationsByLocale[locale]
        }
        if let effectiveLocale = effectiveStoreListingLocale() {
            return appInfoLocalizationsByLocale[effectiveLocale]
        }
        return appInfoLocalization
    }

    func setSelectedStoreListingLocale(_ locale: String?) {
        let locales = Set(localizations.map(\.attributes.locale))
        if let locale, locales.contains(locale) {
            selectedStoreListingLocale = locale
        } else {
            selectedStoreListingLocale = localizations.first?.attributes.locale
        }
    }

    // MARK: - Data Hydration

    func applyStoreListingMetadata(
        versionLocalizations: [ASCVersionLocalization],
        appInfoLocalizations: [ASCAppInfoLocalization]
    ) {
        localizations = versionLocalizations
        appInfoLocalizationsByLocale = Dictionary(uniqueKeysWithValues: appInfoLocalizations.map {
            ($0.attributes.locale, $0)
        })

        let primaryLocale = versionLocalizations.first?.attributes.locale
        appInfoLocalization = primaryLocale.flatMap { appInfoLocalizationsByLocale[$0] } ?? appInfoLocalizations.first

        setSelectedStoreListingLocale(selectedStoreListingLocale)
        storeListingDataRevision += 1
    }

    func refreshStoreListingMetadata(
        service: AppStoreConnectService,
        appId: String,
        preferredLocale: String? = nil
    ) async throws {
        async let versionsTask = service.fetchAppStoreVersions(appId: appId)
        async let appInfoTask: ASCAppInfo? = try? await service.fetchAppInfo(appId: appId)

        let versions = try await versionsTask
        let fetchedAppInfo = await appInfoTask ?? appInfo

        appStoreVersions = versions
        appInfo = fetchedAppInfo

        let versionLocalizations: [ASCVersionLocalization]
        if let latestId = versions.first?.id {
            versionLocalizations = try await service.fetchLocalizations(versionId: latestId)
        } else {
            versionLocalizations = []
        }

        let fetchedAppInfoLocalizations: [ASCAppInfoLocalization]
        if let infoId = fetchedAppInfo?.id {
            fetchedAppInfoLocalizations = try await service.fetchAppInfoLocalizations(appInfoId: infoId)
        } else {
            fetchedAppInfoLocalizations = []
        }

        if let preferredLocale {
            selectedStoreListingLocale = preferredLocale
        }

        applyStoreListingMetadata(
            versionLocalizations: versionLocalizations,
            appInfoLocalizations: fetchedAppInfoLocalizations
        )
    }

    // MARK: - Localization Updates

    private func mappedAppInfoLocalizationFields(_ fields: [String: String]) -> [String: String] {
        var mapped: [String: String] = [:]
        for (field, value) in fields {
            mapped[field == "title" ? "name" : field] = value
        }
        return mapped
    }

    func updateLocalizationField(_ field: String, value: String, locale: String) async {
        await updateStoreListingFields(
            versionFields: [field: value],
            appInfoFields: [:],
            locale: locale
        )
    }

    func updateStoreListingFields(
        versionFields: [String: String],
        appInfoFields rawAppInfoFields: [String: String],
        locale: String
    ) async {
        guard let service else { return }
        let trimmedLocale = locale.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLocale.isEmpty else {
            writeError = "No store listing locale selected."
            return
        }

        writeError = nil

        do {
            if !versionFields.isEmpty {
                guard let locId = storeListingLocalization(locale: trimmedLocale)?.id else {
                    throw ASCError.notFound("Version localization for locale '\(trimmedLocale)'")
                }
                try await service.patchLocalization(id: locId, fields: versionFields)
            }

            let appInfoFields = mappedAppInfoLocalizationFields(rawAppInfoFields)
            if !appInfoFields.isEmpty {
                guard let infoId = appInfo?.id else {
                    throw ASCError.notFound("AppInfo")
                }

                if let locId = appInfoLocalizationForLocale(trimmedLocale)?.id {
                    try await service.patchAppInfoLocalization(id: locId, fields: appInfoFields)
                } else {
                    _ = try await service.createAppInfoLocalization(
                        appInfoId: infoId,
                        locale: trimmedLocale,
                        fields: appInfoFields
                    )
                }
            }

            guard let appId = app?.id else { return }
            try await refreshStoreListingMetadata(
                service: service,
                appId: appId,
                preferredLocale: trimmedLocale
            )
        } catch {
            writeError = error.localizedDescription
        }
    }
}
