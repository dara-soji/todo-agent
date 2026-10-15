import Foundation
import Security

/// The bearer token Claude Code presents to the helper's MCP server, kept in the Keychain and
/// made once on first run.
enum MCPToken {
    private static let item = KeychainItem(account: "mcp-token")

    enum Failure: Error, CustomStringConvertible {
        case random(OSStatus)

        var description: String {
            switch self {
            case let .random(status): "No randomness (\(status))"
            }
        }
    }

    static func loadOrCreate() throws -> String {
        if let token = try item.read() { return token }
        let token = try make()
        try item.write(token)
        return token
    }

    /// 32 random bytes as hex.
    private static func make() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw Failure.random(status) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// The Claude API key, entered once by Dara and kept in the Keychain.
enum ClaudeAPIKey {
    private static let item = KeychainItem(account: "claude-api-key")

    static func load() -> String? {
        (try? item.read()).flatMap { $0?.isEmpty == false ? $0 : nil }
    }

    static func save(_ key: String) throws {
        try item.write(key)
    }
}
