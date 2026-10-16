import AssistantCore

/// How Dara types Matchers in the Projects menu, and how they are shown back:
/// `calendar: standup` is a calendar keyword, `sheet: <id or URL>` or a Google Sheet's URL a Sheet,
/// `~/…` or `/…` a repo path, anything else a URL prefix.
enum MatcherText {
    private static let calendarPrefix = "calendar:"
    private static let sheetPrefix = "sheet:"

    static func parse(_ text: String) -> [Matcher] {
        text.split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { entry in
                if entry.lowercased().hasPrefix(calendarPrefix) {
                    return .calendarKeyword(String(entry.dropFirst(calendarPrefix.count)))
                }
                if entry.lowercased().hasPrefix(sheetPrefix) { return .sheetID(String(entry.dropFirst(sheetPrefix.count))) }
                if entry.contains("docs.google.com/spreadsheets/d/") { return .sheetID(entry) }
                return entry.hasPrefix("~") || entry.hasPrefix("/") ? .repoPath(entry) : .urlPrefix(entry)
            }
    }

    /// The sheet's title from Google, or its id if that can't be read.
    @MainActor
    static func sheetName(_ text: String, using api: SheetsAPI) async -> String {
        guard let id = Matcher.sheetID(in: text) else { return text }
        return (try? await api.title(of: id)) ?? id
    }

    static func format(_ matcher: Matcher) -> String {
        switch matcher.kind {
        case .calendarKeyword: "\(calendarPrefix) \(matcher.pattern)"
        case .sheetID: "\(sheetPrefix) \(matcher.pattern)"
        case .repoPath, .urlPrefix: matcher.pattern
        }
    }
}
