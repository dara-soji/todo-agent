import Foundation

/// An app or site used across all work. While Dara is in one, Now stays on the last Project for a
/// while instead of counting as no Project.
public enum NeutralKey: Hashable, Sendable, Codable {
    /// An app, by bundle id.
    case app(String)
    /// A site: a host, optionally with a path prefix, without the scheme.
    case site(String)

    /// The short default list. Terminal is Neutral only outside a repo, because a repo-path Matcher
    /// fits first.
    public static let defaults: [NeutralKey] = [
        .app("com.apple.Terminal"), .app("com.googlecode.iterm2"), .app("com.tinyspeck.slackmacgap"),
        .app("com.anthropic.claudefordesktop"), .app("us.zoom.xos"), .app("com.microsoft.teams2"),
        .site("google.com/search"), .site("duckduckgo.com"), .site("stackoverflow.com"),
        .site("developer.apple.com"), .site("learn.microsoft.com"), .site("docs.swift.org"),
        .site("claude.ai"),
    ]

    /// How the menu names it: the app's name when that app is in front, else its bundle id or site.
    public func label(in window: ActiveWindow?) -> String {
        switch self {
        case let .app(bundleID): window?.app.bundleID == bundleID ? window?.app.name ?? bundleID : bundleID
        case let .site(site): site
        }
    }
}

/// Dara's "Not this" for the current window.
public enum Correction: Equatable, Sendable {
    case project(Project.ID)
    case neutral
    /// No Project at all.
    case none
}

/// After a correction, the one-click way to make it stick, waiting as a Decision.
public enum CorrectionOffer: Equatable, Sendable {
    /// "Always match <key> to X?"
    case alwaysMatch(Matcher, Project.ID)
    /// "Always treat <key> as Neutral?"
    case alwaysNeutral(NeutralKey)
}
