import Foundation

// MARK: - Release Manager
// Extension containing release-related functionality for ASCManager

extension ASCManager {
    // MARK: - Build Attachment

    func attachBuild(buildId: String) async {
        guard let service else { return }
        guard let versionId = pendingVersionId else {
            writeError = "No app store version found to attach build to."
            return
        }
        writeError = nil
        do {
            try await service.attachBuild(versionId: versionId, buildId: buildId)
        } catch {
            writeError = error.localizedDescription
        }
    }

    // MARK: - Submission

    func submitForReview(attachBuildId: String? = nil) async {
        guard let service else { return }
        guard let appId = app?.id, let versionId = pendingVersionId else { return }
        isSubmitting = true
        submissionError = nil
        do {
            // Attach build if specified
            if let buildId = attachBuildId {
                try await service.attachBuild(versionId: versionId, buildId: buildId)
            }
            try await service.submitForReview(appId: appId, versionId: versionId)
            isSubmitting = false
            await refreshTabData(.app)
        } catch {
            isSubmitting = false
            submissionError = error.localizedDescription
        }
    }

    // MARK: - Localization Flushing

    func flushPendingLocalizations() async {
        guard let service else { return }
        let appInfoLocFieldNames: Set<String> = ["name", "title", "subtitle", "privacyPolicyUrl"]
        for (tab, fields) in pendingFormValues {
            if tab == "storeListing" {
                let locale = activeStoreListingLocale()
                var versionLocFields: [String: String] = [:]
                var infoLocFields: [String: String] = [:]
                for (field, value) in fields {
                    if appInfoLocFieldNames.contains(field) {
                        let apiField = (field == "title") ? "name" : field
                        infoLocFields[apiField] = value
                    } else {
                        versionLocFields[field] = value
                    }
                }
                if !versionLocFields.isEmpty, let locId = storeListingLocalization(locale: locale)?.id {
                    try? await service.patchLocalization(id: locId, fields: versionLocFields)
                }
                if !infoLocFields.isEmpty, let infoLocId = appInfoLocalizationForLocale(locale)?.id {
                    try? await service.patchAppInfoLocalization(id: infoLocId, fields: infoLocFields)
                }
            }
        }
        pendingFormValues = [:]
    }

    // MARK: - Computed Properties

    /// The pending version ID (not live / not removed).
    var pendingVersionId: String? {
        appStoreVersions.first {
            let s = $0.attributes.appStoreState ?? ""
            return s != "READY_FOR_SALE" && s != "REMOVED_FROM_SALE"
                && s != "DEVELOPER_REMOVED_FROM_SALE" && !s.isEmpty
        }?.id ?? appStoreVersions.first?.id
    }
}
