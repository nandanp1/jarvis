import Foundation
import Security

/// Stable Keychain account names used by Jarvis. The values identify records;
/// credentials themselves are never written to preferences or logs.
enum JarvisCredential: String, CaseIterable {
    case geminiAPIKey = "gemini-api-key"
    case homeAssistantAccessToken = "home-assistant-access-token"
    case googleOAuthToken = "google-oauth-token"
}

enum KeychainError: LocalizedError {
    case invalidStringData
    case unexpectedResult
    case operationFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidStringData:
            return "The credential could not be encoded or decoded."
        case .unexpectedResult:
            return "The Keychain returned an unexpected result."
        case .operationFailed(let status):
            let systemMessage = SecCopyErrorMessageString(status, nil) as String?
            return systemMessage ?? "The Keychain operation failed (OSStatus \(status))."
        }
    }
}

/// A reusable generic-password store. Jarvis keeps only opaque credential data
/// here; callers remain responsible for deciding which account name to use.
final class KeychainService {
    static let shared = KeychainService()

    let service: String
    private let accessGroup: String?

    init(
        service: String = Bundle.main.bundleIdentifier ?? "com.nandan.jarvis",
        accessGroup: String? = nil
    ) {
        self.service = service
        self.accessGroup = accessGroup
    }

    func set(_ value: String, for account: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.invalidStringData
        }
        try set(data, for: account)
    }

    func set(_ value: String, for credential: JarvisCredential) throws {
        try set(value, for: credential.rawValue)
    }

    func set(_ data: Data, for account: String) throws {
        let account = try validated(account: account)
        let query = baseQuery(account: account)
        let attributes: [CFString: Any] = [kSecValueData: data]

        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData] = data
            item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(item as CFDictionary, nil)

            // Another writer can create the same record between update and add.
            if status == errSecDuplicateItem {
                status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            }
        }

        guard status == errSecSuccess else {
            throw KeychainError.operationFailed(status)
        }
    }

    func string(for account: String) throws -> String? {
        guard let data = try data(for: account) else { return nil }
        guard let value = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidStringData
        }
        return value
    }

    func string(for credential: JarvisCredential) throws -> String? {
        try string(for: credential.rawValue)
    }

    func data(for account: String) throws -> Data? {
        let account = try validated(account: account)
        var query = baseQuery(account: account)
        query[kSecReturnData] = kCFBooleanTrue
        query[kSecMatchLimit] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw KeychainError.operationFailed(status)
        }
        guard let data = result as? Data else {
            throw KeychainError.unexpectedResult
        }
        return data
    }

    func contains(_ account: String) throws -> Bool {
        let account = try validated(account: account)
        var query = baseQuery(account: account)
        query[kSecMatchLimit] = kSecMatchLimitOne

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else {
            throw KeychainError.operationFailed(status)
        }
        return true
    }

    func remove(_ account: String) throws {
        let account = try validated(account: account)
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.operationFailed(status)
        }
    }

    func remove(_ credential: JarvisCredential) throws {
        try remove(credential.rawValue)
    }

    /// Removes every generic-password record owned by this service. This is
    /// intended for the explicit "Clear Credentials" privacy action.
    func removeAll() throws {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service
        ]
        if let accessGroup = accessGroup {
            query[kSecAttrAccessGroup] = accessGroup
        }

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.operationFailed(status)
        }
    }

    // Convenience names for call sites that read more naturally as a secret
    // store, while keeping one implementation of each operation.
    func save(_ value: String, account: String) throws {
        try set(value, for: account)
    }

    func retrieve(account: String) throws -> String? {
        try string(for: account)
    }

    func delete(account: String) throws {
        try remove(account)
    }

    private func baseQuery(account: String) -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        if let accessGroup = accessGroup {
            query[kSecAttrAccessGroup] = accessGroup
        }
        return query
    }

    private func validated(account: String) throws -> String {
        let trimmed = account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw KeychainError.unexpectedResult }
        return trimmed
    }
}
