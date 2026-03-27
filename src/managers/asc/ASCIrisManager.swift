import Foundation
import Security

// MARK: - Iris Session (Apple ID cookie-based auth for internal APIs)

extension ASCManager {
    // MARK: - Iris Session (Apple ID auth for rejection feedback)
    // TODO - move iris session logic to ASCIrisManager.swift if possible
    // TODO - don't do logging in production
    private func irisLog(_ msg: String) {
        let logPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".blitz/iris-debug.log")
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "[\(ts)] \(msg)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logPath.path) {
                if let handle = try? FileHandle(forWritingTo: logPath) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                let dir = logPath.deletingLastPathComponent()
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try? data.write(to: logPath)
            }
        }
    }

    func refreshSubmissionFeedbackIfNeeded() {
        guard let appId = app?.id else { return }

        let rejectedVersion = appStoreVersions.first(where: {
            $0.attributes.appStoreState == "REJECTED"
        })
        let pendingVersion = appStoreVersions.first(where: {
            let state = $0.attributes.appStoreState ?? ""
            return state != "READY_FOR_SALE" && state != "REMOVED_FROM_SALE"
            && state != "DEVELOPER_REMOVED_FROM_SALE" && !state.isEmpty
        })

        guard let version = rejectedVersion ?? pendingVersion else {
            cachedFeedback = nil
            rebuildSubmissionHistory(appId: appId)
            return
        }

        loadCachedFeedback(appId: appId, versionString: version.attributes.versionString)
        loadIrisSession()
        if irisSessionState == .valid {
            Task { await fetchRejectionFeedback() }
        }
    }

    /// Loads cached feedback from disk for the given rejected version. No auth needed.
    func loadCachedFeedback(appId: String, versionString: String) {
        irisLog("ASCManager.loadCachedFeedback: appId=\(appId) version=\(versionString)")
        if let cached = IrisFeedbackCache.load(appId: appId, versionString: versionString) {
            cachedFeedback = cached
            irisLog("ASCManager.loadCachedFeedback: loaded \(cached.reasons.count) reasons, \(cached.messages.count) messages, fetched \(cached.fetchedAt)")
        } else {
            irisLog("ASCManager.loadCachedFeedback: no cache found")
            cachedFeedback = nil
        }
        rebuildSubmissionHistory(appId: appId)
    }

    func fetchRejectionFeedback() async {
        irisLog("ASCManager.fetchRejectionFeedback: irisService=\(irisService != nil), appId=\(app?.id ?? "nil")")
        guard let irisService, let appId = app?.id else {
            irisLog("ASCManager.fetchRejectionFeedback: guard failed, returning")
            return
        }

        // Determine version string for cache
        let rejectedVersion = appStoreVersions.first(where: {
            $0.attributes.appStoreState == "REJECTED"
        })?.attributes.versionString

        isLoadingIrisFeedback = true
        irisFeedbackError = nil

        do {
            let threads = try await irisService.fetchResolutionCenterThreads(appId: appId)
            irisLog("ASCManager.fetchRejectionFeedback: got \(threads.count) threads")
            resolutionCenterThreads = threads

            if let latestThread = threads.first {
                irisLog("ASCManager.fetchRejectionFeedback: fetching messages+rejections for thread \(latestThread.id)")
                let result = try await irisService.fetchMessagesAndRejections(threadId: latestThread.id)
                rejectionMessages = result.messages
                rejectionReasons = result.rejections
                irisLog("ASCManager.fetchRejectionFeedback: got \(rejectionMessages.count) messages, \(rejectionReasons.count) rejections")

                // Write cache
                if let version = rejectedVersion {
                    let cache = buildFeedbackCache(appId: appId, versionString: version)
                    do {
                        try cache.save()
                        cachedFeedback = cache
                        irisLog("ASCManager.fetchRejectionFeedback: cache saved for \(version)")
                    } catch {
                        irisLog("ASCManager.fetchRejectionFeedback: cache save failed: \(error)")
                    }
                }
            } else {
                irisLog("ASCManager.fetchRejectionFeedback: no threads found")
                rejectionMessages = []
                rejectionReasons = []
            }
        } catch let error as IrisError {
            irisLog("ASCManager.fetchRejectionFeedback: IrisError: \(error)")
            if case .sessionExpired = error {
                irisSessionState = .expired
                irisSession = nil
                self.irisService = nil
            } else {
                irisFeedbackError = error.localizedDescription
            }
        } catch {
            irisLog("ASCManager.fetchRejectionFeedback: error: \(error)")
            irisFeedbackError = error.localizedDescription
        }

        isLoadingIrisFeedback = false
        rebuildSubmissionHistory(appId: appId)
        irisLog("ASCManager.fetchRejectionFeedback: done")
    }

    func loadIrisSession() {
        irisLog("ASCManager.loadIrisSession: starting")
        guard let loaded = IrisSession.load() else {
            irisLog("ASCManager.loadIrisSession: no session file found")
            irisSessionState = .noSession
            irisSession = nil
            irisService = nil
            return
        }
        // No time-based expiry — we trust the session until a 401 proves otherwise
        irisLog("ASCManager.loadIrisSession: loaded session with \(loaded.cookies.count) cookies, capturedAt=\(loaded.capturedAt)")
        do {
            try Self.storeWebSessionToKeychain(loaded)
        } catch {
            irisLog("ASCManager.loadIrisSession: asc-web-session backfill FAILED: \(error)")
        }
        irisSession = loaded
        irisService = IrisService(session: loaded)
        irisSessionState = .valid
        irisLog("ASCManager.loadIrisSession: session valid, irisService created")
    }

    func requestWebAuthForMCP() async -> IrisSession? {
        pendingWebAuthContinuation?.resume(returning: nil)
        irisFeedbackError = nil
        showAppleIDLogin = true
        return await withCheckedContinuation { continuation in
            pendingWebAuthContinuation = continuation
        }
    }

    func cancelPendingWebAuth() {
        showAppleIDLogin = false
        pendingWebAuthContinuation?.resume(returning: nil)
        pendingWebAuthContinuation = nil
    }

    func setIrisSession(_ session: IrisSession) {
        irisLog("ASCManager.setIrisSession: \(session.cookies.count) cookies")
        do {
            try session.save()
            irisLog("ASCManager.setIrisSession: saved to native keychain")
        } catch {
            irisLog("ASCManager.setIrisSession: save FAILED: \(error)")
            irisFeedbackError = "Failed to save session: \(error.localizedDescription)"
            showAppleIDLogin = false
            pendingWebAuthContinuation?.resume(returning: nil)
            pendingWebAuthContinuation = nil
            return
        }

        // Also write the shared web session store (keychain + synced session file).
        // If that write fails during an MCP-triggered login, keep the native session
        // but fail the MCP request instead of reporting a false success.
        do {
            try Self.storeWebSessionToKeychain(session)
        } catch {
            irisLog("ASCManager.setIrisSession: asc-web-session save FAILED: \(error)")
            irisFeedbackError = "Failed to save ASC web session: \(error.localizedDescription)"
            if let continuation = pendingWebAuthContinuation {
                pendingWebAuthContinuation = nil
                continuation.resume(returning: nil)
            }
        }

        irisSession = session
        irisService = IrisService(session: session)
        irisSessionState = .valid
        irisLog("ASCManager.setIrisSession: state set to .valid")
        showAppleIDLogin = false

        // Notify MCP tool if it triggered this login
        if let continuation = pendingWebAuthContinuation {
            pendingWebAuthContinuation = nil
            continuation.resume(returning: session)
        }
    }

    func clearIrisSession() {
        irisLog("ASCManager.clearIrisSession")
        let currentSession = irisSession
        IrisSession.delete()
        Self.deleteWebSessionFromKeychain(email: currentSession?.email)
        irisSession = nil
        irisService = nil
        irisSessionState = .noSession
        resolutionCenterThreads = []
        rejectionMessages = []
        rejectionReasons = []
        if let appId = app?.id {
            rebuildSubmissionHistory(appId: appId)
        }
    }
}

struct IrisSession: Codable, Sendable {
    var cookies: [IrisCookie]
    var email: String?
    var capturedAt: Date

    struct IrisCookie: Codable, Sendable {
        let name: String
        let value: String
        let domain: String
        let path: String
    }

    private static let keychainService = "dev.blitz.iris-session"
    private static let keychainAccount = "iris-cookies"

    static func load() -> IrisSession? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(IrisSession.self, from: data)
    }

    func save() throws {
        let data = try JSONEncoder().encode(self)
        // Delete any existing item first
        Self.delete()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: "IrisSession", code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "Failed to save session to Keychain (status: \(status))"])
        }
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Iris API Response Models

struct IrisResolutionCenterThread: Decodable, Identifiable {
    let id: String
    let attributes: Attributes

    struct Attributes: Decodable {
        let state: String?
        let createdDate: String?
    }
}

struct IrisResolutionCenterMessage: Decodable, Identifiable {
    let id: String
    let attributes: Attributes

    struct Attributes: Decodable {
        let messageBody: String?
        let createdDate: String?
    }
}

struct IrisReviewRejection: Decodable, Identifiable {
    let id: String
    let attributes: Attributes

    struct Attributes: Decodable {
        let reasons: [Reason]?
    }

    struct Reason: Decodable {
        let reasonSection: String?
        let reasonDescription: String?
        let reasonCode: String?
    }
}

// MARK: - Iris Feedback Cache

struct IrisFeedbackCache: Codable {
    let appId: String
    let versionString: String
    let fetchedAt: Date
    let messages: [CachedMessage]
    let reasons: [CachedReason]

    struct CachedMessage: Codable {
        let body: String
        let date: String?
    }

    struct CachedReason: Codable {
        let section: String
        let description: String
        let code: String
    }

    // MARK: - Persistence

    func save() throws {
        let url = Self.cacheURL(appId: appId, versionString: versionString)
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)
    }

    static func load(appId: String, versionString: String) -> IrisFeedbackCache? {
        let url = cacheURL(appId: appId, versionString: versionString)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(IrisFeedbackCache.self, from: data)
    }

    static func loadAll(appId: String) -> [IrisFeedbackCache] {
        let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".blitz/iris-cache/\(appId)")
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return urls
        .filter { $0.pathExtension == "json" }
        .compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(IrisFeedbackCache.self, from: data)
        }
        .sorted { $0.fetchedAt > $1.fetchedAt }
    }

    private static func cacheURL(appId: String, versionString: String) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".blitz/iris-cache/\(appId)/\(versionString).json")
    }
}
