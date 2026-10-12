import Foundation

/// The assistant's domain. Feed it Signals; read Now; change Tasks and Projects through Operations.
public final class Assistant {
    public enum Failure: Error, Equatable {
        case unknownProject(Project.ID)
        case unknownTask(Task.ID)
        case unknownLogEntry(LogEntry.ID)
        case emptyName
        case emptyTitle
        /// The Tasks or Projects an entry wrote have changed since, so undoing it would lose that change.
        case changedSince(LogEntry.ID)
        /// The Guardrail placed the Operation in a tier this build can't run yet.
        case notAllowed(OperationKind, Tier)
    }

    /// Idle this long, outside a matching meeting, and Dara is Away.
    static let awayAfter: TimeInterval = 5 * 60

    let clock: WallClock
    private let store: AssistantStore
    private let guardrail = Guardrail()
    let fitting: MatcherFitting
    var projectsByID: [Project.ID: Project]
    var tasksByID: [Task.ID: Task]
    /// The Operation log, oldest first.
    public private(set) var operationLog: [LogEntry]
    /// When each Project last matched, to break ties between equally specific Matchers.
    private var lastMatched: [Project.ID: Date] = [:]
    private var calendarEvents: [CalendarEvent] = []
    /// No input for `awayAfter`. Away unless a matching meeting is under way.
    private var isIdle = false
    /// Checked-out branch by full repo path.
    private var branches: [String: String] = [:]

    public private(set) var now: Now = .unknown

    public init(clock: WallClock, store: AssistantStore, homeDirectory: String) throws {
        let snapshot = try store.load()
        self.clock = clock
        self.store = store
        self.fitting = MatcherFitting(homeDirectory: homeDirectory)
        self.projectsByID = Dictionary(snapshot.projects.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        self.tasksByID = Dictionary(snapshot.tasks.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        self.operationLog = snapshot.log
    }

    public func receive(_ signal: Signal) {
        switch signal {
        case let .activeWindow(app, title, url):
            let window = ActiveWindow(app: app, title: title, url: url)
            let since = window == now.window ? now.since ?? clock.now : clock.now
            resolve(Now.Visit(window: window, since: since))
        case let .calendar(events):
            calendarEvents = events
            resolve(now.visit)
        case let .userIdle(seconds):
            let wasIdle = isIdle
            isIdle = seconds >= Self.awayAfter
            // Coming back starts a fresh stretch on the window.
            let visit = wasIdle && !isIdle ? now.visit.map { Now.Visit(window: $0.window, since: clock.now) } : now.visit
            resolve(visit)
        case let .git(repo, branch):
            branches[repo] = branch
        }
        wakeSnoozedTasks()
    }

    /// The checked-out branch of the repo a repo-path Matcher names, if it is watched.
    public func branch(of matcher: Matcher) -> String? {
        guard case let .repoPath(path) = matcher else { return nil }
        return branches[fitting.absolute(path)]
    }

    /// Full paths of every active Project's repo-path Matchers, for the git watcher.
    public var repoPathsToWatch: [String] {
        let paths = activeProjects
            .flatMap(\.matchers)
            .compactMap { matcher -> String? in
                guard case let .repoPath(path) = matcher else { return nil }
                return fitting.absolute(path)
            }
        return Array(Set(paths)).sorted()
    }

    // MARK: Operations

    /// Runs an Operation through the Guardrail: stores what it writes together with its log entry,
    /// then applies it. A failed store write changes nothing.
    @discardableResult
    func perform(
        _ kind: OperationKind, _ summary: String, by startedBy: StartedBy, writing after: Change,
        undoes: LogEntry.ID? = nil
    ) throws -> LogEntry {
        let tier = guardrail.tier(for: kind)
        guard tier == .auto else { throw Failure.notAllowed(kind, tier) }
        let entry = LogEntry(
            id: LogEntry.ID(), at: clock.now, kind: kind, summary: summary, tier: tier, startedBy: startedBy,
            confirmation: .notNeeded, before: currentVersions(of: after), after: after, undoes: undoes)
        try store.commit(after, log: entry)
        apply(after)
        operationLog.append(entry)
        resolve(now.visit)
        return entry
    }

    /// Reverses a logged Operation, as long as nothing it wrote has changed since.
    @discardableResult
    public func undo(_ id: LogEntry.ID, by startedBy: StartedBy = .dara) throws -> LogEntry {
        guard let entry = operationLog.first(where: { $0.id == id }) else { throw Failure.unknownLogEntry(id) }
        let unchanged = entry.after.tasks.allSatisfy { tasksByID[$0.id] == $0 }
            && entry.after.projects.allSatisfy { projectsByID[$0.id] == $0 }
        guard unchanged else { throw Failure.changedSince(id) }
        return try perform(.undo, "Undid: \(entry.summary)", by: startedBy, writing: entry.before, undoes: id)
    }

    /// What `change` will overwrite. Something new is recorded as it would be after an undo:
    /// a Task in the Deleted list, a Project archived.
    private func currentVersions(of change: Change) -> Change {
        Change(
            tasks: change.tasks.map { tasksByID[$0.id] ?? $0.deleted(at: clock.now) },
            projects: change.projects.map { projectsByID[$0.id] ?? $0.archived() })
    }

    private func apply(_ change: Change) {
        for task in change.tasks { tasksByID[task.id] = task }
        for project in change.projects { projectsByID[project.id] = project }
    }

    // MARK: Resolving Now

    /// The foreground window beats the calendar: a meeting under way decides only when the window
    /// matches no Project, or while Dara sits still in it (no input in a meeting is not Away).
    /// The Neutral hold (ticket 08) belongs after the meeting, so a Neutral call app defers to it.
    private func resolve(_ visit: Now.Visit?) {
        let meeting = meetingMatch()
        let isAway = isIdle && meeting == nil
        let match: Now.Match? = if isAway {
            nil
        } else if isIdle {
            meeting
        } else {
            visit.flatMap { foregroundMatch(for: $0.window) } ?? meeting
        }
        if let match { lastMatched[match.project] = clock.now }
        now = Now(visit: visit, match: match, isAway: isAway)
    }

    private func foregroundMatch(for window: ActiveWindow) -> Now.Match? {
        mostSpecific(activeProjects.flatMap { project in
            project.matchers.filter { fitting.fits($0, window) }.map { Now.Match(project: project.id, evidence: $0) }
        })
    }

    private func meetingMatch() -> Now.Match? {
        let underWay = calendarEvents.filter { $0.isUnderWay(at: clock.now) }
        return mostSpecific(activeProjects.flatMap { project in
            project.matchers.flatMap { matcher in
                underWay.filter { fitting.fits(matcher, $0) }
                    .map { Now.Match(project: project.id, evidence: matcher, event: $0) }
            }
        })
    }

    /// The most specific Matcher wins; equally specific ones go to the most recently matched
    /// Project, then to the first by name (candidates arrive in name order and `max` keeps the first).
    private func mostSpecific(_ candidates: [Now.Match]) -> Now.Match? {
        candidates.max { a, b in
            if a.evidence.specificity != b.evidence.specificity {
                return a.evidence.specificity < b.evidence.specificity
            }
            return (lastMatched[a.project] ?? .distantPast) < (lastMatched[b.project] ?? .distantPast)
        }
    }
}
