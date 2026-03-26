import Foundation
import Security

extension ASCManager {
    private static let webSessionService = ASCWebSessionStore.keychainService
    private static let webSessionAccount = ASCWebSessionStore.keychainAccount

    /// Stored in Keychain for Blitz and synced to ~/.blitz/asc-agent/web-session.json
    /// so CLI skill scripts can reuse the same session.
    static func storeWebSessionToKeychain(_ session: IrisSession) throws {
        let existingData = readKeychainItem(service: webSessionService, account: webSessionAccount)
        let data = try ASCWebSessionStore.mergedData(storing: session, into: existingData)
        removeWebSessionKeychainItem()
        try writeWebSessionToKeychain(data)
        try ASCAuthBridge().syncWebSession(data)
    }

    static func deleteWebSessionFromKeychain(email: String?) {
        let existingData = readKeychainItem(service: webSessionService, account: webSessionAccount)
        let updatedData: Data?
        do {
            updatedData = try ASCWebSessionStore.removingSession(email: email, from: existingData)
        } catch {
            return
        }

        guard let updatedData else {
            removeWebSessionKeychainItem()
            return
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: webSessionService,
            kSecAttrAccount as String: webSessionAccount,
        ]
        let status = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: updatedData] as CFDictionary
        )
        if status == errSecItemNotFound {
            try? writeWebSessionToKeychain(updatedData)
        }

        do {
            try ASCAuthBridge().syncWebSession(updatedData)
        } catch {
            ASCAuthBridge().removeWebSession()
        }
    }

    static func readKeychainItem(service: String, account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    static func syncWebSessionFileFromKeychain() {
        guard let data = readKeychainItem(service: webSessionService, account: webSessionAccount) else {
            return
        }
        try? ASCAuthBridge().syncWebSession(data)
    }

    private static func writeWebSessionToKeychain(_ data: Data) throws {
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: webSessionService,
            kSecAttrAccount as String: webSessionAccount,
            kSecAttrLabel as String: "ASC Web Session Store",
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(
                domain: "ASCWebSessionStore",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "Keychain write failed (status: \(status))"]
            )
        }
    }

    private static func removeWebSessionKeychainItem() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: webSessionService,
            kSecAttrAccount as String: webSessionAccount,
        ]
        SecItemDelete(query as CFDictionary)
        ASCAuthBridge().removeWebSession()
    }
}
