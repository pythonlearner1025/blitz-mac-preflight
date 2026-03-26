import Foundation
import Testing
@testable import Blitz

@MainActor
@Test func loadTrackFromASCPreservesUnsavedLocaleTrack() {
    let manager = ASCManager()
    let locale = "en-US"
    let displayType = "APP_IPHONE_67"
    let set = makeScreenshotSet(id: "set-us", displayType: displayType, count: 1)

    manager.cacheScreenshots(
        locale: locale,
        sets: [set],
        screenshots: [set.id: [makeScreenshot(id: "remote-1", fileName: "remote-1.png")]]
    )
    manager.loadTrackFromASC(displayType: displayType, locale: locale)

    let trackKey = manager.screenshotTrackKey(displayType: displayType, locale: locale)
    manager.trackSlots[trackKey] = [
        TrackSlot(
            id: "local-1",
            localPath: "/tmp/local-1.png",
            localImage: nil,
            ascScreenshot: nil,
            isFromASC: false
        )
    ] + Array(repeating: nil, count: 9)

    #expect(manager.hasUnsavedChanges(displayType: displayType, locale: locale))

    manager.cacheScreenshots(
        locale: locale,
        sets: [set],
        screenshots: [set.id: [makeScreenshot(id: "remote-2", fileName: "remote-2.png")]]
    )
    manager.loadTrackFromASC(displayType: displayType, locale: locale)

    let slots = manager.trackSlotsForDisplayType(displayType, locale: locale)
    #expect(slots[0]?.id == "local-1")
    #expect(manager.hasUnsavedChanges(displayType: displayType, locale: locale))
}

@MainActor
@Test func submissionReadinessUsesPrimaryLocaleScreenshotCache() {
    let manager = ASCManager()
    manager.localizations = [
        makeLocalization(id: "loc-us", locale: "en-US"),
        makeLocalization(id: "loc-gb", locale: "en-GB"),
    ]

    let usSet = makeScreenshotSet(id: "set-us", displayType: "APP_IPHONE_67", count: 1)
    manager.cacheScreenshots(
        locale: "en-US",
        sets: [usSet],
        screenshots: [usSet.id: [makeScreenshot(id: "shot-us", fileName: "us.png")]]
    )

    manager.activeScreenshotsLocale = "en-GB"
    manager.screenshotSets = []
    manager.screenshots = [:]

    let readiness = manager.submissionReadiness
    let iphoneField = readiness.fields.first { $0.label == "iPhone Screenshots" }

    #expect(iphoneField?.value == "1 screenshot(s)")
}

private func makeLocalization(id: String, locale: String) -> ASCVersionLocalization {
    ASCVersionLocalization(
        id: id,
        attributes: ASCVersionLocalization.Attributes(
            locale: locale,
            title: nil,
            subtitle: nil,
            description: nil,
            keywords: nil,
            promotionalText: nil,
            marketingUrl: nil,
            supportUrl: nil,
            whatsNew: nil
        )
    )
}

private func makeScreenshotSet(id: String, displayType: String, count: Int?) -> ASCScreenshotSet {
    ASCScreenshotSet(
        id: id,
        attributes: ASCScreenshotSet.Attributes(
            screenshotDisplayType: displayType,
            screenshotCount: count
        )
    )
}

private func makeScreenshot(id: String, fileName: String) -> ASCScreenshot {
    ASCScreenshot(
        id: id,
        attributes: ASCScreenshot.Attributes(
            fileName: fileName,
            fileSize: nil,
            imageAsset: nil,
            assetDeliveryState: nil
        )
    )
}
