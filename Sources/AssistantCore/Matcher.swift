import Foundation

/// A rule saying that a Signal belongs to a Project.
public enum Matcher: Hashable, Sendable, Codable {
    /// A repo or folder, written `~/…` or absolute. Matches a window whose title shows that path or
    /// anything under it, which covers VS Code (title set to show the path) and Terminal's working directory.
    case repoPath(String)
    /// A URL prefix without the scheme, e.g. `learn.microsoft.com/*/training/`. `*` stands for one
    /// path segment. Matches whole segments, and is never a bare domain.
    case urlPrefix(String)
    /// A word or phrase in the title of a calendar event under way, matched as whole words,
    /// ignoring case. Sets Now only when the foreground window matches no Project.
    case calendarKeyword(String)

    public enum Kind: String, Sendable {
        case repoPath, urlPrefix, calendarKeyword
    }

    public enum Invalid: Error, Equatable {
        /// A URL prefix with no literal path, which would swallow unrelated work.
        case bareDomain(String)
        /// A repo path that is neither absolute nor under `~`.
        case relativePath(String)
        /// A calendar keyword too short to mean anything.
        case shortKeyword(String)
    }

    public init(kind: Kind, pattern: String) {
        switch kind {
        case .repoPath: self = .repoPath(pattern)
        case .urlPrefix: self = .urlPrefix(pattern)
        case .calendarKeyword: self = .calendarKeyword(pattern)
        }
    }

    public var kind: Kind {
        switch self {
        case .repoPath: .repoPath
        case .urlPrefix: .urlPrefix
        case .calendarKeyword: .calendarKeyword
        }
    }

    /// The Matcher's path or prefix, in the form it is stored and shown as evidence.
    public var pattern: String {
        switch self {
        case let .repoPath(path): path
        case let .urlPrefix(prefix): prefix
        case let .calendarKeyword(keyword): keyword
        }
    }

    /// How specific this Matcher is. When several fit one window, the most specific wins:
    /// more literal segments first, then more segments overall (a `*` counts only there).
    var specificity: Specificity {
        let segments = pattern.split(separator: "/")
        return Specificity(literal: segments.filter { $0 != "*" }.count, total: segments.count)
    }

    struct Specificity: Comparable {
        let literal: Int
        let total: Int

        static func < (a: Self, b: Self) -> Bool {
            (a.literal, a.total) < (b.literal, b.total)
        }
    }
}
