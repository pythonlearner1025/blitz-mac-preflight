import Foundation
import AppKit
import ImageIO

// MARK: - Screenshots Manager
// Extension containing screenshot-related functionality for ASCManager

extension ASCManager {
    // MARK: - Track Synchronization

    func syncTrackToASC(displayType: String, locale: String) async {
        guard let service else { writeError = "ASC service not configured"; return }
        isSyncing = true
        writeError = nil

        // Ensure localizations are loaded
        if localizations.isEmpty, let versionId = appStoreVersions.first?.id {
            localizations = (try? await service.fetchLocalizations(versionId: versionId)) ?? []
        }
        if localizations.isEmpty, let appId = app?.id {
            let versions = (try? await service.fetchAppStoreVersions(appId: appId)) ?? []
            appStoreVersions = versions
            if let versionId = versions.first?.id {
                localizations = (try? await service.fetchLocalizations(versionId: versionId)) ?? []
            }
        }
        guard let loc = localizations.first(where: { $0.attributes.locale == locale })
                ?? localizations.first else {
            writeError = "No localizations found for locale '\(locale)'."
            isSyncing = false
            return
        }

        let current = trackSlots[displayType] ?? Array(repeating: nil, count: 10)
        let saved = savedTrackState[displayType] ?? Array(repeating: nil, count: 10)

        do {
            // 1. Delete screenshots that were in saved state but not in current track
            let savedIds = Set(saved.compactMap { $0?.id })
            let currentIds = Set(current.compactMap { $0?.id })
            let toDelete = savedIds.subtracting(currentIds)
            for id in toDelete {
                try await service.deleteScreenshot(screenshotId: id)
            }

            // 2. Check if existing ASC screenshots need reorder
            let currentASCIds = current.compactMap { slot -> String? in
                guard let slot, slot.isFromASC else { return nil }
                return slot.id
            }
            let savedASCIds = saved.compactMap { slot -> String? in
                guard let slot, slot.isFromASC else { return nil }
                return slot.id
            }
            let remainingASCIds = Set(currentASCIds)
            let reorderNeeded = currentASCIds != savedASCIds.filter { remainingASCIds.contains($0) }

            if reorderNeeded {
                // Delete remaining ASC screenshots and re-upload in new order
                for id in currentASCIds {
                    if !toDelete.contains(id) {
                        try await service.deleteScreenshot(screenshotId: id)
                    }
                }
            }

            // 3. Upload local assets + re-upload reordered ASC screenshots
            for slot in current {
                guard let slot else { continue }
                if let path = slot.localPath {
                    try await service.uploadScreenshot(localizationId: loc.id, path: path, displayType: displayType)
                } else if reorderNeeded, slot.isFromASC, let ascShot = slot.ascScreenshot {
                    // For reordered ASC screenshots, we need the original file
                    // Download from ASC URL and re-upload
                    if let url = ascShot.imageURL,
                       let (data, _) = try? await URLSession.shared.data(from: url),
                       let fileName = ascShot.attributes.fileName {
                        let tmpPath = FileManager.default.temporaryDirectory.appendingPathComponent(fileName).path
                        try data.write(to: URL(fileURLWithPath: tmpPath))
                        try await service.uploadScreenshot(localizationId: loc.id, path: tmpPath, displayType: displayType)
                        try? FileManager.default.removeItem(atPath: tmpPath)
                    }
                }
            }

            // 4. Reload from ASC
            let sets = try await service.fetchScreenshotSets(localizationId: loc.id)
            screenshotSets = sets
            for set in sets {
                screenshots[set.id] = try await service.fetchScreenshots(setId: set.id)
            }
            loadTrackFromASC(displayType: displayType)
        } catch {
            writeError = error.localizedDescription
        }

        isSyncing = false
    }

    // MARK: - Screenshot Deletion

    func deleteScreenshot(screenshotId: String) async throws {
        guard let service else { throw ASCError.notFound("ASC service not configured") }
        try await service.deleteScreenshot(screenshotId: screenshotId)
    }

    // MARK: - Local Assets

    func scanLocalAssets(projectId: String) {
        let dir = BlitzPaths.screenshots(projectId: projectId)
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            localScreenshotAssets = []
            return
        }
        let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "webp"]
        localScreenshotAssets = files
            .filter { imageExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                // Try NSImage first, fall back to CGImageSource for WebP
                var image = NSImage(contentsOf: url)
                if image == nil || image!.representations.isEmpty {
                    if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                       let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                        image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                    }
                }
                guard let image else { return nil }
                return LocalScreenshotAsset(id: UUID(), url: url, image: image, fileName: url.lastPathComponent)
            }
    }

    // MARK: - Track Management

    @discardableResult
    func addAssetToTrack(displayType: String, slotIndex: Int, localPath: String) -> String? {
        guard slotIndex >= 0 && slotIndex < 10 else { return "Invalid slot index" }

        guard let image = NSImage(contentsOfFile: localPath) else {
            return "Could not load image"
        }

        // Validate dimensions
        var pixelWidth = 0, pixelHeight = 0
        if let rep = image.representations.first, rep.pixelsWide > 0, rep.pixelsHigh > 0 {
            pixelWidth = rep.pixelsWide
            pixelHeight = rep.pixelsHigh
        } else if let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff) {
            pixelWidth = bitmap.pixelsWide
            pixelHeight = bitmap.pixelsHigh
        }

        if let error = Self.validateDimensions(width: pixelWidth, height: pixelHeight, displayType: displayType) {
            return error
        }

        var slots = trackSlots[displayType] ?? Array(repeating: nil, count: 10)
        let slot = TrackSlot(
            id: UUID().uuidString,
            localPath: localPath,
            localImage: image,
            ascScreenshot: nil,
            isFromASC: false
        )
        // If target slot occupied, shift right
        if slots[slotIndex] != nil {
            slots.insert(slot, at: slotIndex)
            slots = Array(slots.prefix(10))
        } else {
            slots[slotIndex] = slot
        }
        // Pad back to 10
        while slots.count < 10 { slots.append(nil) }
        trackSlots[displayType] = slots
        return nil
    }

    func removeFromTrack(displayType: String, slotIndex: Int) {
        guard slotIndex >= 0 && slotIndex < 10 else { return }
        var slots = trackSlots[displayType] ?? Array(repeating: nil, count: 10)
        slots.remove(at: slotIndex)
        slots.append(nil) // maintain 10 elements
        trackSlots[displayType] = slots
    }

    func reorderTrack(displayType: String, fromIndex: Int, toIndex: Int) {
        guard fromIndex >= 0 && fromIndex < 10 && toIndex >= 0 && toIndex < 10 else { return }
        guard fromIndex != toIndex else { return }
        var slots = trackSlots[displayType] ?? Array(repeating: nil, count: 10)
        let item = slots.remove(at: fromIndex)
        slots.insert(item, at: toIndex)
        trackSlots[displayType] = slots
    }

    // MARK: - Track Loading

    func loadTrackFromASC(displayType: String) {
        let previousSlots = trackSlots[displayType] ?? []
        let set = screenshotSets.first { $0.attributes.screenshotDisplayType == displayType }
        var slots: [TrackSlot?] = Array(repeating: nil, count: 10)
        if let set, let shots = screenshots[set.id] {
            for (i, shot) in shots.prefix(10).enumerated() {
                // If ASC hasn't processed the image yet, carry forward the local preview
                var localImage: NSImage? = nil
                if shot.imageURL == nil, i < previousSlots.count, let prev = previousSlots[i] {
                    localImage = prev.localImage
                }
                slots[i] = TrackSlot(
                    id: shot.id,
                    localPath: nil,
                    localImage: localImage,
                    ascScreenshot: shot,
                    isFromASC: true
                )
            }
        }
        trackSlots[displayType] = slots
        savedTrackState[displayType] = slots
    }

    // MARK: - Validation

    func hasUnsavedChanges(displayType: String) -> Bool {
        let current = trackSlots[displayType] ?? Array(repeating: nil, count: 10)
        let saved = savedTrackState[displayType] ?? Array(repeating: nil, count: 10)
        return zip(current, saved).contains { c, s in c?.id != s?.id }
    }

    /// Validate pixel dimensions for a display type. Returns nil if valid, or an error string.
    static func validateDimensions(width: Int, height: Int, displayType: String) -> String? {
        switch displayType {
        case "APP_IPHONE_67":
            let validSizes: Set<String> = ["1290x2796", "1284x2778", "1242x2688", "1260x2736"]
            if validSizes.contains("\(width)x\(height)") { return nil }
            return "\(width)×\(height) — need 1290×2796, 1284×2778, 1242×2688, or 1260×2736 for iPhone"
        case "APP_IPAD_PRO_3GEN_129":
            if width == 2048 && height == 2732 { return nil }
            return "\(width)×\(height) — need 2048×2732 for iPad"
        case "APP_DESKTOP":
            let valid: Set<String> = ["1280x800", "1440x900", "2560x1600", "2880x1800"]
            if valid.contains("\(width)x\(height)") { return nil }
            return "\(width)×\(height) — need 1280×800, 1440×900, 2560×1600, or 2880×1800 for Mac"
        default:
            return nil
        }
    }
}
