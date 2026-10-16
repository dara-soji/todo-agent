import Foundation

/// How Matchers are written down and how they fit a window. Paths under the home directory are
/// kept as `~/…` so Matchers read the same however the window shows the path.
struct MatcherFitting {
    let homeDirectory: String

    /// The Matcher in its stored form, or why it can't be one.
    func normalised(_ matcher: Matcher) throws -> Matcher {
        switch matcher {
        case let .repoPath(path):
            let path = tilde(trimmingSlash(path.trimmingCharacters(in: .whitespaces)))
            guard path == "~" || path.hasPrefix("~/") || path.hasPrefix("/") else {
                throw Matcher.Invalid.relativePath(path)
            }
            return .repoPath(path)
        case let .urlPrefix(prefix):
            let prefix = withoutScheme(prefix.trimmingCharacters(in: .whitespaces))
            let parts = prefix.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            let literalPath = parts.count == 2 && parts[1].split(separator: "/").contains { $0 != "*" }
            guard !parts[0].isEmpty, literalPath else {
                throw Matcher.Invalid.bareDomain(prefix)
            }
            return .urlPrefix(withoutWWW(parts[0].lowercased()) + "/" + parts[1])
        case let .calendarKeyword(keyword):
            let keyword = keyword.trimmingCharacters(in: .whitespaces)
            guard keyword.count >= 2 else { throw Matcher.Invalid.shortKeyword(keyword) }
            return .calendarKeyword(keyword)
        case let .sheetID(text):
            guard let id = Self.sheetID(in: text) else { throw Matcher.Invalid.malformedSheetID(text) }
            return .sheetID(id)
        }
    }

    /// Whether a stored Matcher fits the window.
    func fits(_ matcher: Matcher, _ window: ActiveWindow) -> Bool {
        switch matcher {
        case let .repoPath(path):
            guard let title = window.title else { return false }
            return [path, absolute(path)].contains { title.showsPath($0) }
        case let .urlPrefix(prefix):
            guard let page = page(of: window) else { return false }
            return urlFits(prefix: prefix, page: page)
        case .calendarKeyword:
            return false
        case let .sheetID(id):
            guard let page = page(of: window), page.hasPrefix("docs.google.com/") else { return false }
            return Self.sheetID(in: page) == id
        }
    }

    /// Google Sheet ids are long; anything much shorter is a typo or a word.
    static let shortestSheetID = 20

    /// The id in a Google Sheet's id or URL (`/spreadsheets/d/<id>`, or `/spreadsheets/u/1/d/<id>`
    /// with more than one account), or nil if it isn't one. A published-to-web link (`/d/e/…`) isn't.
    static func sheetID(in text: String) -> String? {
        var id = text.trimmingCharacters(in: .whitespaces)
        if id.contains("/spreadsheets/") {
            let pattern = #"/spreadsheets/(?:u/\d+/)?d/([A-Za-z0-9_-]+)"#
            guard let match = id.range(of: pattern, options: .regularExpression) else { return nil }
            let path = id[match]
            id = String(path[path.range(of: "/d/")!.upperBound...])
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard id.count >= shortestSheetID, id.unicodeScalars.allSatisfy({ allowed.contains($0) && $0.isASCII })
        else { return nil }
        return id
    }

    /// Whether a stored calendar-keyword Matcher fits an event's title.
    func fits(_ matcher: Matcher, _ event: CalendarEvent) -> Bool {
        guard case let .calendarKeyword(keyword) = matcher else { return false }
        let pattern = "\\b" + NSRegularExpression.escapedPattern(for: keyword) + "\\b"
        return event.title.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Whether the window is in this Neutral app or site.
    func fits(_ neutral: NeutralKey, _ window: ActiveWindow) -> Bool {
        switch neutral {
        case let .app(bundleID):
            return window.app.bundleID == bundleID
        case let .site(prefix):
            return fits(site: prefix, window)
        case .excluded:
            return window.isExcluded
        }
    }

    /// Whether the window's page is on this site (a host, optionally with a path).
    func fits(site: String, _ window: ActiveWindow) -> Bool {
        guard let page = page(of: window) else { return false }
        return urlFits(prefix: withoutWWW(site.lowercased()), page: page)
    }

    /// The Matcher "Always match" would add for this window: its URL down to two path segments
    /// (e.g. github.com/you/repo), or else the deepest folder its title shows.
    func proposedMatcher(for window: ActiveWindow) -> Matcher? {
        if let page = page(of: window) {
            let segments = page.split(separator: "/").prefix(3)
            return segments.count > 1 ? .urlPrefix(segments.joined(separator: "/")) : nil
        }
        let paths = (window.title ?? "").split(whereSeparator: { " []()\"'—|".contains($0) })
            .map(String.init)
            .filter { $0.hasPrefix("/") || $0.hasPrefix("~/") }
        return paths.max(by: { $0.count < $1.count }).flatMap { try? normalised(.repoPath($0)) }
    }

    /// The Neutral key "Treat as Neutral" would add: the site (with its port) in a browser, else the app.
    func proposedNeutral(for window: ActiveWindow) -> NeutralKey {
        proposedSite(for: window).map(NeutralKey.site) ?? .app(window.app.bundleID)
    }

    /// The window's site: its host (without www) and port, if it shows a page.
    func proposedSite(for window: ActiveWindow) -> String? {
        guard let url = window.url, let host = url.host(percentEncoded: false) else { return nil }
        return withoutWWW(host.lowercased()) + (url.port.map { ":\($0)" } ?? "")
    }

    /// Host (with port) and decoded path, as URL prefixes are written.
    private func page(of window: ActiveWindow) -> String? {
        guard let url = window.url, let host = url.host(percentEncoded: false) else { return nil }
        let port = url.port.map { ":\($0)" } ?? ""
        return withoutWWW(host.lowercased()) + port + url.path(percentEncoded: false)
    }

    /// A repo path as the file system knows it.
    func absolute(_ path: String) -> String {
        path == "~" || path.hasPrefix("~/") ? homeDirectory + path.dropFirst() : path
    }

    // MARK: Paths

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

    /// Segment by segment: `*` takes any one segment, and a trailing `/` requires the page to go on below it.
    private func urlFits(prefix: String, page: String) -> Bool {
        let wanted = prefix.split(separator: "/", omittingEmptySubsequences: false)
        let actual = page.split(separator: "/", omittingEmptySubsequences: false)
        for (index, segment) in wanted.enumerated() {
            if index == wanted.count - 1 && segment.isEmpty { return actual.count > index && !actual[index].isEmpty }
            guard index < actual.count, !actual[index].isEmpty else { return false }
            if segment != "*" && actual[index] != segment { return false }
        }
        return true
    }
}

private extension String {
    /// Whether this window title shows `path` or something under it, as a whole path:
    /// `~/code/todo` is not shown by `~/code/todo-agent`. Paths may contain spaces.
    func showsPath(_ path: String) -> Bool {
        let before = Set(" \t[(\"'—|:")
        let after = Set("/ \t])\"'—|:,;")
        var searchFrom = startIndex
        while let found = range(of: path, range: searchFrom..<endIndex) {
            let startsCleanly = found.lowerBound == startIndex || before.contains(self[index(before: found.lowerBound)])
            let endsCleanly = found.upperBound == endIndex || after.contains(self[found.upperBound])
            if startsCleanly && endsCleanly { return true }
            searchFrom = index(after: found.lowerBound)
        }
        return false
    }
}
