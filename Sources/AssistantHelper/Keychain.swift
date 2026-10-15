import Foundation
import Security

/// One secret in the data-protection keychain, which honours the accessibility class and doesn't tie
/// the item to this build's ad-hoc signature (so rebuilding the helper keeps it).
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
            kSecUseDataProtectionKeychain as String: true,
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
