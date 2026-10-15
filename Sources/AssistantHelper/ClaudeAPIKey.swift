import Foundation

/// The Claude API key, entered once by Dara and kept in the Keychain. Read from the Keychain once,
/// then held in memory.
@MainActor
enum ClaudeAPIKey {
    private static let item = KeychainItem(account: "claude-api-key")
    private static var cached: String??

    static func load() -> String? {
        if let cached { return cached }
        let key = (try? item.read()).flatMap { $0?.isEmpty == false ? $0 : nil }
        cached = .some(key)
        return key
    }

    static func save(_ key: String) throws {
        try item.write(key)
        cached = .some(key)
    }
}
