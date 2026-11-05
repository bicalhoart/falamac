import Foundation
import Security
import CryptoKit

enum Keychain {
    static let service = "art.bicalho.falamac.api"
    private static let queue = DispatchQueue(label: "art.bicalho.falamac.keychain")
    private static let buildFingerprint: String = {
        guard let url = Bundle.main.executableURL, let data = try? Data(contentsOf: url) else { return "unavailable" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }()

    static func loadAtLaunch(_ account: String) -> Loaded {
        // Personal ad-hoc builds have a new keychain identity after every update.
        // Don't even query existing items until this build was explicitly authorized.
        guard UserDefaults.standard.string(forKey: "keychainAuthorizedBuild") == buildFingerprint,
              buildFingerprint != "unavailable" else { return Loaded(value: nil, needsAuthorization: true) }
        return load(account)
    }

    static func rememberAuthorization() {
        if buildFingerprint != "unavailable" { UserDefaults.standard.set(buildFingerprint, forKey: "keychainAuthorizedBuild") }
    }

    struct Loaded: Sendable {
        let value: String?
        let needsAuthorization: Bool
    }

    static func load(_ account: String, allowPrompt: Bool = false) -> Loaded {
        queue.sync { loadOnQueue(account, allowPrompt: allowPrompt) }
    }

    private static func loadOnQueue(_ account: String, allowPrompt: Bool) -> Loaded {
        // kSecUseAuthenticationUIFail alone does not suppress all legacy ACL prompts.
        // Disable interaction for silent reads within this process, then restore it.
        var interactionWasAllowed: DarwinBoolean = true
        SecKeychainGetUserInteractionAllowed(&interactionWasAllowed)
        if !allowPrompt { SecKeychainSetUserInteractionAllowed(false) }
        defer { if !allowPrompt { SecKeychainSetUserInteractionAllowed(interactionWasAllowed.boolValue) } }
        var query = base(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        // Never surprise the user with an authentication dialog at launch.
        // This also covers the legacy macOS login-keychain ACL used by this app.
        query[kSecUseAuthenticationUI as String] = allowPrompt ? kSecUseAuthenticationUIAllow : kSecUseAuthenticationUIFail
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return Loaded(value: nil, needsAuthorization: status != errSecItemNotFound)
        }
        return Loaded(value: String(data: data, encoding: .utf8), needsAuthorization: false)
    }

    static func save(_ value: String, account: String) throws {
        try queue.sync { try saveOnQueue(value, account: account) }
    }

    private static func saveOnQueue(_ value: String, account: String) throws {
        let data = Data(value.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        guard !data.isEmpty else { return }
        let query = base(account)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let result = SecItemAdd(insert as CFDictionary, nil)
            guard result == errSecSuccess else { throw KeyError.status(result) }
        } else if status != errSecSuccess { throw KeyError.status(status) }
    }

    private static func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    enum KeyError: LocalizedError {
        case status(OSStatus)
        var errorDescription: String? { "Could not save the key in macOS Keychain." }
    }
}
