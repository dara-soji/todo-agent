import Foundation
import Security

/// One secret in the login keychain. Not the data-protection keychain: that needs a team-signed
/// keychain-access-groups entitlement, and this ad-hoc-signed build gets errSecMissingEntitlement (-34018).
/// The item's access is tied to the build's signature, so after a rebuild macOS asks once to allow it.
struct KeychainItem {
    let account: String
    private static let service = "com.dara.todo-agent.helper"

    enum Failure: Error, CustomStringConvertible {
        case keychain(OSStatus)

        var description: String {
            switch self {
            case let .keychain(status): "Keychain error \(status)"
            }
        }
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
    }

    func read() throws -> String? {
        var query = self.query
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw Failure.keychain(status) }
        return String(decoding: data, as: UTF8.self)
    }

    func delete() {
        SecItemDelete(query as CFDictionary)
    }

    /// Replaces any existing value.
    func write(_ value: String) throws {
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecValueData as String] = Data(value.utf8)
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure.keychain(status) }
    }
}
