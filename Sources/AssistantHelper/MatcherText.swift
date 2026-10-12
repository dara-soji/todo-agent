import AssistantCore

/// How Dara types Matchers in the Projects menu, and how they are shown back:
/// `calendar: standup` is a calendar keyword, `~/…` or `/…` a repo path, anything else a URL prefix.
enum MatcherText {
    private static let calendarPrefix = "calendar:"

    static func parse(_ text: String) -> [Matcher] {
        text.split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { entry in
                if entry.lowercased().hasPrefix(calendarPrefix) {
                    return .calendarKeyword(String(entry.dropFirst(calendarPrefix.count)))
                }
                return entry.hasPrefix("~") || entry.hasPrefix("/") ? .repoPath(entry) : .urlPrefix(entry)
            }
    }

    static func format(_ matcher: Matcher) -> String {
        matcher.kind == .calendarKeyword ? "\(calendarPrefix) \(matcher.pattern)" : matcher.pattern
    }
}
