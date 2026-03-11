# Code Review Fix Plan

## Phase 1: Shared infrastructure (constants, paths, logging)

- [x] Create `Sources/BlitzCore/BlitzPaths.swift` — central `enum BlitzPaths` with static computed properties for all `.blitz/` subdirectories (`root`, `projects`, `settings`, `mcpPort`, `signingDir`, `macros`, `issues`)
- [x] Update `ProjectStorage.swift` (line 10) to use `BlitzPaths.projects`
- [x] Update `SettingsService.swift` (line 25) to use `BlitzPaths.settings`
- [x] Update `MCPServerService.swift` (line 17) to use `BlitzPaths.mcpPort`
- [x] Update `BlitzApp.swift` (lines 41-42) to use `BlitzPaths.root`
- [x] Update `NodeSidecarService.swift` (lines 13, 78) to use `BlitzPaths`
- [x] Update `IDBProtocol.swift` (lines 14, 25) to use `BlitzPaths`
- [x] Update `MacroService.swift` to use `BlitzPaths.macros`
- [x] Update `IssueService.swift` to use `BlitzPaths.issues`
- [x] Update `BuildPipelineService.swift` (line 46) to use `BlitzPaths.signingDir`

## Phase 2: Critical security and data-loss fixes

- [x] **SQL injection** — `AppState.swift:505-507`: Add `sqlEscape()` helper, use it in `DatabaseManager.loadRows()` to escape `searchText` before interpolating into WHERE clause
- [x] **SQL injection** — `TeenybaseClient.swift:69`: Escape single quotes in `id` parameter in `deleteRecord()`
- [x] **Symlink data loss** — `ProjectStorage.swift:75`: Check if path is symlink before deleting; if symlink, only unlink the symlink, don't follow through to original directory
- [x] **Deadlock** — `BlitzApp.swift:30-37`: Replace `DispatchSemaphore` in `MCPBootstrap.shutdown()` with fire-and-forget `Task.detached` + brief `Thread.sleep(0.1)`
- [x] **Network exposure** — `MCPServerService.swift:48`: Change `INADDR_ANY` to `INADDR_LOOPBACK` so MCP server only listens on localhost
- [x] **Pipe deadlock** — `ProcessRunner.swift:55-57`: Read stdout/stderr pipes on background threads before waiting for process termination, not inside `terminationHandler`
- [x] **Command injection** — `IDBProtocol.swift:123-127`: Replace manual quote escaping in `inputText()` with proper JSON serialization of the text argument
- [x] **Key permissions** — `BuildPipelineService.swift:162-176`: Set `0o600` permissions on generated private keys (`dist.key`, `dist.p12`) after writing
- [x] **IDB fallback path** — `IDBProtocol.swift:19`: Change relative `"idb"` fallback to check common absolute paths (`/opt/homebrew/bin/idb`, `/usr/local/bin/idb`)

## Phase 3: Concurrency correctness

- [x] Add `@MainActor` to `AppState` class in `AppState.swift`
- [x] Add `@MainActor` to `ProjectManager` class in `AppState.swift`
- [x] Add `@MainActor` to `SimulatorManager` class in `AppState.swift`
- [x] Add `@MainActor` to `SimulatorStreamManager` class in `AppState.swift`
- [x] Add `@MainActor` to `RecordingManager` class in `AppState.swift`
- [x] Add `@MainActor` to `IssueStore` class in `AppState.swift`
- [x] Add `@MainActor` to `MacroStore` class in `AppState.swift`
- [x] Add `@MainActor` to `ProjectSetupManager` class in `AppState.swift`
- [x] Add `@MainActor` to `DatabaseManager` class in `AppState.swift`
- [x] Add `@MainActor` to `SettingsService` in `SettingsService.swift`
- [x] Add `@MainActor` to `MacroService` in `MacroService.swift`
- [x] Add `@MainActor` to `IssueService` in `IssueService.swift`
- [x] Add `@MainActor` to `PermissionService` in `PermissionService.swift`
- [x] Remove now-redundant `await MainActor.run { }` blocks inside `DatabaseManager.startAndConnect()` (lines 483, 519)
- [x] Mark `MCPBootstrap` as `@MainActor` in `BlitzApp.swift`
- [x] `MCPServerService.swift:75-92` — Replace `Task.detached` + blocking `accept()` with `DispatchSource.makeReadSource` on the server socket
- [x] `UnixSocketHTTP.swift:47-93` — Wrap blocking POSIX socket ops in `withCheckedThrowingContinuation` + `DispatchQueue.global()`
- [x] `ContentView.swift:102-126` — Store tab-switch `Task` in `@State`, cancel previous on each new tab switch to prevent pause/resume races

## Phase 4: Fragile logic fixes

- [x] `SimulatorService.swift:26` — Change `error.localizedDescription.contains("Booted")` to check `processError.stderr.contains("current state: Booted")` (simctl stderr is not localized)
- [x] `ProjectStorage.swift:87-94` — On name collision, resolve existing symlink target and compare; if different path, append disambiguator (`-2`, `-3`, etc.)
- [x] `SimulatorConfig.swift:68-71` — Sort keys by length descending for fuzzy match so longer (more specific) names match first; remove reverse `key.contains(name)` direction
- [x] `AppState.swift:584` — Change `trimmed.hasPrefix(key)` to `trimmed.hasPrefix(key + "=")` in `readDevVar()` to prevent partial key matches
- [x] `MCPToolRegistry.swift:450-453` — Move `device_action` and `device_actions` from `.query` to `.simulatorControl` category
- [x] `MCPToolRegistry.swift:482` — Change default case from `.query` to a new `.unknown` category that requires approval (fail-safe for unregistered tools)
- [x] `MCPServerService.swift:181` — Escape `error.localizedDescription` before interpolating into JSON string (escape `\` and `"`)
- [x] `WDAClient.swift:121,129,140,154` — Strip leading `/` from path arguments in `get()`/`post()` helpers to prevent double-slash URLs
- [x] `TeenybaseClient.swift:78,87` — Replace force-unwrapped `URL(string:)!` with `guard let` + throw
- [x] `WDAClient.swift:9` — Replace force-unwrapped `URL(string:)!` with guard

## Phase 5: Resource and configuration fixes

- [ ] Move `SimulatorConfig` device database from hardcoded dictionary to `Sources/BlitzApp/Resources/simulator-devices.json`; load via `Bundle.module` at startup (deferred — requires JSON schema design and migration)
- [x] `SimulatorCaptureService.swift:102,173` — Replace hardcoded retina `scale = 2.0` with `NSScreen.main?.backingScaleFactor ?? 2.0`
- [x] `SimulatorCaptureService.swift:185` — Store configured FPS as property on service during `startCapture()`; use stored value in `checkForResize()` instead of hardcoded `30`
- [x] `RecordingService.swift:25` — Accept recording format parameter in `startRecording()`; use `SettingsService` format instead of always `.mov`
- [x] `SettingsView.swift:121` — Replace hardcoded `"1.0.0"` with `Bundle.main.infoDictionary?["CFBundleShortVersionString"]`
- [x] `PortAllocator.swift:35-39` — Check `getsockname()` return value; replace `print()` calls with `Logger(subsystem:category:)`
- [x] `ProcessRunner.swift:31` — timeout parameter kept for API compat, marked with TODO (one caller uses it)

## Phase 6: Error handling and coupling fixes

- [x] `ApprovalRequest.swift:28` — Remove `requiresApproval` computed property that accesses `SettingsService.shared`; move approval logic into `MCPToolExecutor` which has proper access to settings
- [x] `ProjectStorage.ensureMCPConfig()` line 136 — Log error on `try?` failure instead of silent swallow
- [x] `SettingsService.save()` line 62 — Log error on `try?` failure instead of silent swallow
- [x] `ProjectStorage.updateLastOpened()` line 108 — Add logging when `try? writeMetadata()` fails
- [x] `SettingsView.swift:10-19` — Use `ApprovalRequest.ToolCategory` enum values directly instead of raw string literals for permission toggle keys
- [x] `NodeSidecarService.swift:13` — Use `FileManager.default.temporaryDirectory` (per-user `~/Library/...`) instead of world-readable `/tmp` for Unix socket

## Phase 7: Minor cleanup

- [x] `AppCommands.swift:89-106` — Wire up Run/Stop menu actions to simulator boot+stream; removed empty Reload Metro item
- [x] `SimctlClient.swift:86-88` — Remove stray `xcrun simctl io enumerate` call before `sendkey home`
- [x] `SimulatorView.swift:9` — Move `DeviceInteractionService()` out of the view struct into `@State`
- [x] `DatabaseView.swift:14-17` — Cache `hasBackend` filesystem check in `@State`, computed in `.onAppear` instead of every render
- [x] `BlitzApp.swift:121` — Removed forced dark mode (`NSAppearance(named: .darkAqua)`), now respects system appearance
