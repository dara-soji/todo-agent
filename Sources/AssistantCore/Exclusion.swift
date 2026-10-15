import Foundation

/// An app, site, email sender or notes folder the assistant must not read or send anywhere.
public enum Exclusion: Hashable, Sendable, Codable {
    /// An app, by bundle id.
    case app(String)
    /// A site: a host, optionally with a path, without the scheme.
    case site(String)
    /// An email address, or every address at a domain written "@domain".
    case sender(String)
    /// An Apple Notes folder, by name.
    case notesFolder(String)

    public enum Invalid: Error, Equatable {
        case empty
        /// A site written with a trailing slash or a scheme: write "bank.example" or "bank.example/acct".
        case malformedSite(String)
        /// A sender needs an "@": "you@bank.example" or "@bank.example".
        case malformedSender(String)
    }

    /// Always Excluded, whatever the list says: system password prompts. Password managers are
    /// Dara's choice, offered at setup.
    static let alwaysExcludedApps: Set<String> = [
        "com.apple.SecurityAgent", "com.apple.LocalAuthentication.UIAgent", "com.apple.loginwindow",
    ]

    /// Private-browsing windows that say so in their title (Firefox).
    static func isPrivateWindowTitle(_ title: String) -> Bool {
        title.hasSuffix("Private Browsing")
    }

    /// The exclusion in its stored form, or why it can't be one.
    func normalised() throws -> Exclusion {
        switch self {
        case let .app(bundleID):
            let bundleID = bundleID.trimmingCharacters(in: .whitespaces)
            guard !bundleID.isEmpty else { throw Invalid.empty }
            return .app(bundleID)
        case let .site(site):
            var site = site.trimmingCharacters(in: .whitespaces).lowercased()
            guard !site.isEmpty else { throw Invalid.empty }
            guard !site.contains("://"), !site.hasSuffix("/") else { throw Invalid.malformedSite(site) }
            if site.hasPrefix("www.") { site.removeFirst(4) }
            return .site(site)
        case let .sender(sender):
            let sender = sender.trimmingCharacters(in: .whitespaces).lowercased()
            guard !sender.isEmpty else { throw Invalid.empty }
            guard sender.contains("@") else { throw Invalid.malformedSender(sender) }
            return .sender(sender)
        case let .notesFolder(folder):
            let folder = folder.trimmingCharacters(in: .whitespaces)
            guard !folder.isEmpty else { throw Invalid.empty }
            return .notesFolder(folder)
        }
    }

    /// How the menu names it.
    public var label: String {
        switch self {
        case let .app(bundleID): bundleID
        case let .site(site): site
        case let .sender(sender): sender
        case let .notesFolder(folder): "Notes folder “\(folder)”"
        }
    }
}

extension ActiveWindow {
    /// What an Excluded window becomes as it enters the core: no app, title or URL.
    public static let excluded = ActiveWindow(app: App(bundleID: "", name: "Excluded"), title: nil, url: nil, isExcluded: true)
}
