import Foundation

/// What the menu bar shows for the current state. The UI renders this as-is.
public struct MenuBar: Equatable, Sendable {
    public enum Marker: Equatable, Sendable {
        /// No Signal yet.
        case unknown
        /// Now matched a Project: drawn as the square Project dot.
        case project
        /// Now matched no Project.
        case noProject
        /// Dara is idle long enough to be away.
        case away
        /// A Haiku guess: drawn as a hollow dashed dot with "?".
        case guess
    }

    /// The menu-bar item's text.
    public let title: String
    public let marker: Marker
    /// The Now line in the dropdown: the Project's full name, or "No Project".
    public let nowDetail: String
    /// Why Now is on that Project, e.g. "Matched by ~/code/todo-agent".
    public let evidence: String?
    /// The app and full window title, never shortened.
    public let window: String?
    /// The Committed Task's title, shown under Now.
    public let committedTaskTitle: String?
    /// Next's title, shown in amber.
    public let nextTitle: String
    /// Why it is Next, in one line.
    public let nextReason: String?
    /// Decisions are waiting in the dropdown: the menu-bar item shows an amber ●.
    public let decisionsWaiting: Bool
    /// Drifting off the Committed Task's Project: the menu-bar item shows an amber ▲.
    public let drifting: Bool

    /// Longest menu-bar title, ellipsis included.
    static let titleLimit = 15

    init(_ now: Now, project: Project?, branch: String?, committedTask: Task?, next: NextLine, decisionsWaiting: Bool, drifting: Bool) {
        self.decisionsWaiting = decisionsWaiting
        self.drifting = drifting
        self.committedTaskTitle = committedTask?.title
        self.nextTitle = next.title
        self.nextReason = next.reason
        guard now.window != nil || now.match != nil else {
            title = "—"
            marker = .unknown
            nowDetail = "Waiting for the first Signal"
            evidence = nil
            window = nil
            return
        }
        window = now.window.map { active in
            guard let title = active.title, !title.isEmpty else { return active.app.name }
            return "\(active.app.name) — \(title)"
        }
        if now.isAway {
            title = "AWAY"
            marker = .away
            nowDetail = "Away"
            evidence = nil
        } else if let project, let match = now.match, match.isGuess {
            title = Self.shorten(project.shortName.uppercased()) + "?"
            marker = .guess
            nowDetail = "\(project.name) · guess"
            evidence = "A guess from a screenshot"
        } else if let project, let match = now.match {
            title = Self.shorten(project.shortName.uppercased())
            marker = .project
            nowDetail = project.name
            evidence = Self.evidence(match, window: now.window, branch: branch)
        } else {
            title = "NO PROJECT"
            marker = .noProject
            nowDetail = "No Project"
            evidence = nil
        }
    }

    private static func evidence(_ match: Now.Match, window: ActiveWindow?, branch: String?) -> String {
        switch match.basis {
        case let .matcher(.sheetID(id)):
            return "Matched by sheet \(id)"
        case let .matcher(matcher):
            return "Matched by \(matcher.pattern)" + (branch.map { " · \($0)" } ?? "")
        case let .meeting(matcher, event):
            return "Matched by “\(matcher.pattern)” in \(event.title)"
        case .neutralHold(.excluded):
            return "Kept while Excluded"
        case let .neutralHold(key):
            return "Kept while \(key.label(in: window)) is Neutral"
        case .correction:
            return "You said so"
        case .guess:
            return "A guess from a screenshot"
        }
    }

    private static func shorten(_ text: String) -> String {
        text.count <= titleLimit ? text : text.prefix(titleLimit - 1) + "…"
    }
}

/// Next as the dropdown words it.
struct NextLine {
    let title: String
    let reason: String?

    init(_ next: Next, task: Task?, project: (Project.ID) -> Project?, now: Date, calendar: Calendar) {
        if case let .reviewSuggestions(count) = next {
            title = "Review Suggestions (\(count))"
            reason = nil
            return
        }
        guard case let .task(_, reason, wontFitBefore) = next, let task else {
            title = "Plan tomorrow"
            reason = nil
            return
        }
        title = task.title
        let why = switch reason {
        case .resume: "Back to what you were doing before the interruption"
        case let .due(deadline): Self.due(deadline, now: now, calendar: calendar)
        case let .continues(id): "Continues \(project(id)?.shortName.uppercased() ?? "this Project")"
        case .deepInTheMorning: "Deep work while it's morning"
        case .shallowInTheAfternoon: "A shallow one for the afternoon"
        case .oldest: "Oldest open Task"
        case let .chosen(text): text
        }
        self.reason = wontFitBefore.map { "\(why) · won't fit before \(Self.format($0, "HH:mm", calendar))" } ?? why
    }

    private static func due(_ deadline: Date, now: Date, calendar: Calendar) -> String {
        if deadline < now { return "Overdue" }
        if calendar.isDate(deadline, inSameDayAs: now) { return "Due today" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(deadline, inSameDayAs: tomorrow) {
            return "Due tomorrow"
        }
        return "Due \(format(deadline, "EEE", calendar))"
    }

    private static func format(_ date: Date, _ pattern: String, _ calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}

extension Assistant {
    public var menuBar: MenuBar {
        let next = self.next
        return MenuBar(
            now, project: now.project.flatMap(project), branch: now.evidence.flatMap(branch(of:)),
            committedTask: committedTask,
            next: NextLine(next, task: next.task.flatMap(task), project: project, now: clock.now, calendar: calendar),
            decisionsWaiting: !decisions.isEmpty, drifting: isDrifting)
    }
}
