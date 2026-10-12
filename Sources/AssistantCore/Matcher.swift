import Foundation

/// A rule saying that a Signal belongs to a Project.
public enum Matcher: Hashable, Sendable {
    /// A repo or folder, written `~/…` or absolute. Matches a window whose title shows that path or
    /// anything under it, which covers VS Code (title set to show the path) and Terminal's working directory.
    case repoPath(String)
    /// A URL prefix without the scheme, e.g. `learn.microsoft.com/*/training/`. `*` stands for one
    /// path segment. Never a bare domain.
    case urlPrefix(String)

    public enum Invalid: Error, Equatable {
        /// A URL prefix that is only a domain, which would swallow unrelated work.
        case bareDomain(String)
        /// A repo path that is neither absolute nor under `~`.
        case relativePath(String)
    }

    /// How specific this Matcher is. When several fit one window, the most specific wins.
    var specificity: Int {
        switch self {
        case let .repoPath(path): path.count
        case let .urlPrefix(prefix): prefix.count
        }
    }
}
