import Foundation
import Security

/// The bearer token Claude Code presents to the helper's MCP server, kept in the Keychain and
/// made once on first run.
enum MCPToken {
    private static let service = "com.dara.todo-agent.helper"
    private static let account = "mcp-token"

    enum Failure: Error, CustomStringConvertible {
        case keychain(OSStatus)
        case random(OSStatus)

        var description: String {
            switch self {
            case let .keychain(status): "Keychain error \(status)"
            case let .random(status): "No randomness (\(status))"
            }
        }
    }

    static func loadOrCreate() throws -> String {
        if let token = try load() { return token }
        let token = try make()
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: Data(token.utf8),
        ]
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure.keychain(status) }
        return token
    }

    private static func load() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw Failure.keychain(status) }
        return String(decoding: data, as: UTF8.self)
    }

    /// 32 random bytes as hex.
    private static func make() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw Failure.random(status) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
