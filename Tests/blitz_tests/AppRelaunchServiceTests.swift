import Foundation
import Testing
@testable import Blitz

@MainActor
private func makeTestDefaults() -> UserDefaults {
    let suiteName = "AppRelaunchServiceTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}

@Test @MainActor func testScreenRecordingRelaunchSchedulesWhenPermissionWasGranted() {
    let defaults = makeTestDefaults()
    let appPath = "/Applications/Blitz's Test.app"
    let start = Date(timeIntervalSince1970: 1_000)
    let now = start
    var launchedPath: String?
    var launchedPID: Int32?

    let service = AppRelaunchService(
        defaults: defaults,
        now: { now },
        appURLProvider: { URL(fileURLWithPath: appPath) },
        screenRecordingAccessProvider: { true },
        launcher: { path, pid in
            launchedPath = path
            launchedPID = pid
            return true
        }
    )

    service.prepareForScreenRecordingPermissionRestart()

    let scheduled = service.schedulePendingScreenRecordingRelaunchIfNeeded(pid: 4242)

    #expect(scheduled)
    #expect(launchedPath == appPath)
    #expect(launchedPID == 4242)

    launchedPath = nil
    launchedPID = nil
    let scheduledAgain = service.schedulePendingScreenRecordingRelaunchIfNeeded(pid: 4242)
    #expect(!scheduledAgain)
    #expect(launchedPath == nil)
    #expect(launchedPID == nil)
}

@Test @MainActor func testScreenRecordingRelaunchDoesNotScheduleWhenRequestIsStale() {
    let defaults = makeTestDefaults()
    let appPath = "/Applications/Blitz.app"
    let start = Date(timeIntervalSince1970: 2_000)
    var now = start
    var launched = false

    let service = AppRelaunchService(
        defaults: defaults,
        now: { now },
        appURLProvider: { URL(fileURLWithPath: appPath) },
        screenRecordingAccessProvider: { true },
        launcher: { _, _ in
            launched = true
            return true
        }
    )

    service.prepareForScreenRecordingPermissionRestart()
    now = start.addingTimeInterval(AppRelaunchService.pendingWindow + 1)

    let scheduled = service.schedulePendingScreenRecordingRelaunchIfNeeded(pid: 111)

    #expect(!scheduled)
    #expect(!launched)
}

@Test @MainActor func testScreenRecordingRelaunchDoesNotScheduleWithoutGrantedPermission() {
    let defaults = makeTestDefaults()
    var launched = false

    let service = AppRelaunchService(
        defaults: defaults,
        now: { Date(timeIntervalSince1970: 3_000) },
        appURLProvider: { URL(fileURLWithPath: "/Applications/Blitz.app") },
        screenRecordingAccessProvider: { false },
        launcher: { _, _ in
            launched = true
            return true
        }
    )

    service.prepareForScreenRecordingPermissionRestart()
    let scheduled = service.schedulePendingScreenRecordingRelaunchIfNeeded(pid: 222)

    #expect(!scheduled)
    #expect(!launched)
}

@Test func testRelaunchShellCommandQuotesAppPaths() {
    let command = AppRelaunchService.relaunchShellCommand(
        appPath: "/Applications/Blitz's Test.app",
        pid: 9876
    )

    #expect(command.contains("while kill -0 9876 2>/dev/null; do sleep 0.2; done;"))
    #expect(command.contains("open '/Applications/Blitz'\\''s Test.app'"))
}
