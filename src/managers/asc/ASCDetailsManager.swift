import Foundation

// MARK: - App Details Manager
// Extension containing app details-related functionality for ASCManager

extension ASCManager {
    // MARK: - App Info Updates

    func updateAppInfoField(_ field: String, value: String) async {
        guard let service else { return }
        writeError = nil

        // Fields that live on different ASC resources:
        // - copyright → appStoreVersions (PATCH /v1/appStoreVersions/{id})
        // - contentRightsDeclaration → apps (PATCH /v1/apps/{id})
        // - primaryCategory, subcategories → appInfos relationships (PATCH /v1/appInfos/{id})
        if field == "copyright" {
            guard let versionId = appStoreVersions.first?.id else { return }
            do {
                try await service.patchVersion(id: versionId, fields: [field: value])
                // Re-fetch versions so submissionReadiness picks up the new copyright
                if let appId = app?.id {
                    appStoreVersions = try await service.fetchAppStoreVersions(appId: appId)
                }
            } catch {
                writeError = error.localizedDescription
            }
        } else if field == "contentRightsDeclaration" {
            guard let appId = app?.id else { return }
            do {
                try await service.patchApp(id: appId, fields: [field: value])
                // Refetch app to reflect the change
                app = try await service.fetchApp(bundleId: app?.bundleId ?? "")
            } catch {
                writeError = error.localizedDescription
            }
        } else if let infoId = appInfo?.id {
            do {
                try await service.patchAppInfo(id: infoId, fields: [field: value])
                appInfo = try? await service.fetchAppInfo(appId: app?.id ?? "")
            } catch {
                writeError = error.localizedDescription
            }
        }
    }

    func updatePrivacyPolicyUrl(_ url: String) async {
        await updateAppInfoLocalizationField("privacyPolicyUrl", value: url)
    }

    /// Update a field on appInfoLocalizations (name, subtitle, privacyPolicyUrl)
    func updateAppInfoLocalizationField(_ field: String, value: String) async {
        guard let service else { return }
        guard let locId = appInfoLocalization?.id else { return }
        writeError = nil
        // Map UI field names to API field names
        let apiField = (field == "title") ? "name" : field
        do {
            try await service.patchAppInfoLocalization(id: locId, fields: [apiField: value])
            if let infoId = appInfo?.id {
                appInfoLocalization = try? await service.fetchAppInfoLocalization(appInfoId: infoId)
            }
        } catch {
            writeError = error.localizedDescription
        }
    }

    // MARK: - Age Rating

    func updateAgeRating(_ attributes: [String: Any]) async {
        guard let service else { return }
        guard let id = ageRatingDeclaration?.id else { return }
        writeError = nil
        do {
            try await service.patchAgeRating(id: id, attributes: attributes)
            if let infoId = appInfo?.id {
                ageRatingDeclaration = try? await service.fetchAgeRating(appInfoId: infoId)
            }
        } catch {
            writeError = error.localizedDescription
        }
    }
}

