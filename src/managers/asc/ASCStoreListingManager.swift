import Foundation

// MARK: - Store Listing Manager
// Extension containing store listing-related functionality for ASCManager

extension ASCManager {
    // MARK: - Localization Updates

    func updateLocalizationField(_ field: String, value: String, locId: String) async {
        guard let service else { return }
        writeError = nil
        do {
            try await service.patchLocalization(id: locId, fields: [field: value])
            if let latestId = appStoreVersions.first?.id {
                localizations = try await service.fetchLocalizations(versionId: latestId)
            }
        } catch {
            writeError = error.localizedDescription
        }
    }

}

