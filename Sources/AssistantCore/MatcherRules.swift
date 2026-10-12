import Foundation

/// How Matchers are written down and how they fit a window. Paths under the home directory are
/// kept as `~/…` so Matchers read the same however the window shows the path.
struct MatcherRules {
    let homeDirectory: String

    /// The Matcher in its stored form, or why it can't be one.
    func normalised(_ matcher: Matcher) throws -> Matcher {
        switch matcher {
        case let .repoPath(path):
            let path = tilde(trimmingSlash(path))
            guard path == "~" || path.hasPrefix("~/") || path.hasPrefix("/") else {
                throw Matcher.Invalid.relativePath(path)
            }
            return .repoPath(path)
        case let .urlPrefix(prefix):
            let prefix = withoutScheme(prefix)
            let parts = prefix.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[1].isEmpty, !parts[0].isEmpty else {
                throw Matcher.Invalid.bareDomain(prefix)
            }
            return .urlPrefix(parts[0].lowercased() + "/" + parts[1])
        }
    }

    /// Whether a stored Matcher fits the window.
    func fits(_ matcher: Matcher, _ window: ActiveWindow) -> Bool {
        switch matcher {
        case let .repoPath(path):
            guard let title = window.title else { return false }
            return pathsShown(in: title).contains { $0 == path || $0.hasPrefix(path == "/" ? "/" : path + "/") }
        case let .urlPrefix(prefix):
            guard let url = window.url, let host = url.host() else { return false }
            let page = withoutWWW(host.lowercased()) + url.path()
            return urlFits(prefix: withoutWWW(prefix), page: page)
        }
    }

    // MARK: Paths

    /// Path-like tokens in a window title, e.g. VS Code's root path or Terminal's working directory.
    private func pathsShown(in title: String) -> [String] {
        title.split(whereSeparator: { " []()\"'—|".contains($0) })
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: ":,;")) }
            .filter { $0.hasPrefix("/") || $0 == "~" || $0.hasPrefix("~/") }
            .map { tilde(trimmingSlash($0)) }
    }

    private func tilde(_ path: String) -> String {
        if path == homeDirectory { return "~" }
        if path.hasPrefix(homeDirectory + "/") { return "~" + path.dropFirst(homeDirectory.count) }
        return path
    }

    private func trimmingSlash(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    // MARK: URLs

    private func withoutScheme(_ text: String) -> String {
        for scheme in ["https://", "http://"] where text.lowercased().hasPrefix(scheme) {
            return String(text.dropFirst(scheme.count))
        }
        return text
    }

    private func withoutWWW(_ text: String) -> String {
        text.hasPrefix("www.") ? String(text.dropFirst(4)) : text
    }

    /// Segment by segment: `*` takes any one segment, the last segment is a plain prefix,
    /// and a trailing `/` requires the page to go on below it.
    private func urlFits(prefix: String, page: String) -> Bool {
        let wanted = prefix.split(separator: "/", omittingEmptySubsequences: false)
        let actual = page.split(separator: "/", omittingEmptySubsequences: false)
        for (index, segment) in wanted.enumerated() {
            let isLast = index == wanted.count - 1
            if isLast && segment.isEmpty { return actual.count > index }
            guard index < actual.count else { return false }
            if segment == "*" { if actual[index].isEmpty { return false } else { continue } }
            if isLast { return actual[index].hasPrefix(segment) }
            if actual[index] != segment { return false }
        }
        return true
    }
}
