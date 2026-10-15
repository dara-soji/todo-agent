import Foundation

/// The assistant's domain. Feed it Signals; read Now; change Tasks and Projects through Operations.
public final class Assistant {
    public enum Failure: Error, Equatable {
        case unknownProject(Project.ID)
        case unknownTask(Task.ID)
        case unknownLogEntry(LogEntry.ID)
        case emptyName
        case emptyTitle
        /// The helper may at most suggest "done?"; Dara marks a Task done, directly or in conversation.
        case onlyDaraMarksDone
        case deletedTask(Task.ID)
        /// Only an open Task can be skipped.
        case notOpen(Task.ID)
        /// At most one Task is committed; this Operation would leave two.
        case secondCommittedTask
        /// The Tasks or Projects an entry wrote have changed since, so undoing it would lose that change.
        case changedSince(LogEntry.ID)
        /// The Guardrail placed the Operation in a tier that can't run.
        case notAllowed(OperationKind, Tier)
        case unknownAsk(Ask.ID)
        /// Something the Ask would write has changed since it was made; decline it instead.
        case askChangedSince(Ask.ID)
        case cannotTighten(OperationKind)
        case cannotLoosen(OperationKind)
        /// Start Next with nothing to start.
        case nothingNext
        /// A declined or expired entry ran nothing, so there is nothing to undo.
        case notUndoable(LogEntry.ID)
        /// "Not this" needs a window to correct.
        case noWindow
        /// No "Always" is waiting.
        case noOffer
        case alreadyNeutral(NeutralKey)
        case alreadyExcluded(Exclusion)
        /// Not on the exclude list (always-Excluded windows never are).
        case notExcluded(Exclusion)
        /// An Excluded window can't be corrected: nothing about it is known.
        case windowExcluded
    }

    /// Idle this long, outside a matching meeting, and Dara is Away.
    static let awayAfter: TimeInterval = 5 * 60

    let clock: WallClock
    let store: AssistantStore
    /// For time of day and dates as Dara reads them.
    let calendar: Calendar
    /// Dara's tier rules, Neutrals and exclude list.
    public private(set) var settings: Settings
    private var guardrail: Guardrail { Guardrail(rules: settings.guardrailRules) }
    /// Operations waiting for Dara to confirm, oldest first.
    public private(set) var asks: [Ask] = []
    /// The conversation the current call comes from; see `inSession`.
    private var session: String?

    /// How long an Ask waits before it expires.
    static let askExpiresAfter: TimeInterval = 30 * 60
    /// Asks from one conversation this close together are one confirm.
    static let askGroupWindow: TimeInterval = 2 * 60
    let fitting: MatcherFitting
    // Readable across the module, written only here, by `apply`, so nothing skips the Guardrail and the log.
    private(set) var projectsByID: [Project.ID: Project]
    private(set) var tasksByID: [Task.ID: Task]
    /// The Operation log, oldest first.
    public private(set) var operationLog: [LogEntry]
    /// When each Project last matched, to break ties between equally specific Matchers.
    private var lastMatched: [Project.ID: Date] = [:]
    private(set) var calendarEvents: [CalendarEvent] = []
    /// No input for `awayAfter`. Away unless a matching meeting is under way.
    private var isIdle = false
    /// Checked-out branch by full repo path.
    private var branches: [String: String] = [:]
    /// Apps and sites Dara made Neutral, on top of the defaults.
    public var neutrals: [NeutralKey] { settings.neutrals }
    /// Dara's exclude list, on top of the windows that are always Excluded.
    public var exclusions: [Exclusion] { settings.exclusions }
    /// Dara's "Not this" for one window; it lasts while that window does.
    var correction: (window: ActiveWindow, to: Correction)?
    /// The "Always …?" waiting after a correction.
    var offer: CorrectionOffer?
    /// The Project Now was last on, cleared by any stretch of No Project or Away: what a Neutral
    /// window holds.
    private var lastConfident: Project.ID?
    /// `lastConfident` as it was before the current window, for "Not this → Neutral" on a window
    /// that had matched the wrong Project.
    private var confidentBeforeWindow: Project.ID?
    /// When the current run of Neutral windows began.
    private var neutralSince: Date?

    /// The Nudge showing for the current Drift, if any.
    public internal(set) var nudge: Nudge?
    var drift = DriftState()
    var newTaskOffer = NewTaskOffer()
    /// The Now history block being timed.
    var openHistoryBlock: OpenBlock?
    /// Seconds since the last input, from the latest idle Signal.
    var idleSeconds: TimeInterval = 0
    /// Haiku's answers per window: a Project, or nil for none. Kept in memory only.
    var guessCache: [GuessKey: Project.ID?] = [:]
    var guessInFlight: (key: GuessKey, since: Date)?
    /// Guess keys, oldest first, to keep the cache bounded.
    var guessOrder: [GuessKey] = []
    /// When a window whose guess failed may be tried again.
    var guessRetryAt: [GuessKey: Date] = [:]
    /// Sonnet's picks per tied set of Tasks, with the reason to show.
    var tieBreaks: [Set<Task.ID>: (task: Task.ID, reason: String)] = [:]
    var tieInFlight: (key: Set<Task.ID>, since: Date)?
    var tieRetryAt: [Set<Task.ID>: Date] = [:]
    /// The unplaced window being timed for a guess.
    var guessWatch: (key: GuessKey, since: Date)?
    /// Today's API spend, read from the audit log once a day and added to as calls are made.
    var apiSpend: (day: Date, today: Double) = (.distantPast, 0)

    /// How long a Neutral app or site keeps Now on the last Project.
    static let neutralHoldsFor: TimeInterval = 15 * 60

    public private(set) var now: Now = .unknown

    public init(clock: WallClock, store: AssistantStore, homeDirectory: String, calendar: Calendar = .current) throws {
        let snapshot = try store.load()
        self.clock = clock
        self.calendar = calendar
        self.store = store
        self.fitting = MatcherFitting(homeDirectory: homeDirectory)
        self.projectsByID = Dictionary(snapshot.projects.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        self.tasksByID = Dictionary(snapshot.tasks.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        self.operationLog = snapshot.log
        self.settings = snapshot.settings
    }

    public func receive(_ signal: Signal) {
        switch signal {
        case let .activeWindow(app, title, url, excluded):
            // Exclusions are applied here, as the Signal enters, before anything else sees it.
            let window = excluded ? .excluded : excluding(ActiveWindow(app: app, title: title, url: url))
            let since = window == now.window ? now.since ?? clock.now : clock.now
            resolve(Now.Visit(window: window, since: since))
        case let .calendar(events):
            calendarEvents = events
            resolve(now.visit)
        case let .userIdle(seconds):
            let wasIdle = isIdle
            idleSeconds = seconds
            isIdle = seconds >= Self.awayAfter
            // Coming back starts a fresh stretch on the window.
            let visit = wasIdle && !isIdle ? now.visit.map { Now.Visit(window: $0.window, since: clock.now) } : now.visit
            resolve(visit)
        case let .git(repo, branch):
            branches[repo] = branch
        }
        wakeSnoozedTasks()
        expireDueAsks()
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

    /// The Assistant's current time, for adapters turning "in two hours" into a date.
    public var clockNow: Date { clock.now }

    /// Today's calendar events still to come or under way, in start order.
    public var calendarToday: [CalendarEvent] {
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: clock.now))!
        return calendarEvents.filter { $0.end > clock.now && $0.start < endOfDay }.sorted { $0.start < $1.start }
    }

    // MARK: Operations

    /// The Guardrail tier an Operation of this kind runs in, in general, whoever starts it.
    public func tier(for kind: OperationKind) -> Tier {
        guardrail.tier(for: kind)
    }

    public var guardrailRules: [GuardrailRule] {
        settings.guardrailRules
    }

    /// A Change writing Dara's settings with `edit` applied.
    func changingSettings(_ edit: (inout Settings) -> Void) -> Change {
        var settings = self.settings
        edit(&settings)
        return Change(settings: settings)
    }

    /// Runs `body` as part of a conversation, so Asks it makes group and expire with that conversation.
    @discardableResult
    public func inSession<T>(_ id: String?, _ body: () throws -> T) rethrows -> T {
        let previous = session
        session = id
        defer { session = previous }
        return try body()
    }

    /// Runs an Operation through the Guardrail. Auto: stores what it writes together with its log
    /// entry, then applies it; a failed store write changes nothing. Ask: holds it for Dara to
    /// confirm in the menu bar. Never: refuses.
    @discardableResult
    func perform(
        _ kind: OperationKind, _ summary: String, by startedBy: StartedBy, writing after: Change,
        undoes: LogEntry.ID? = nil, preview: [String] = []
    ) throws -> Outcome {
        let before = currentVersions(of: after)
        // Scope covers where things are and where they would go, so moving a Task out of a
        // tightened Project, or into a loosened one, can't slip past the Guardrail.
        let projects = Set((before.tasks + after.tasks).map(\.project) + after.projects.map { Optional($0.id) })
        var tier = guardrail.tier(for: kind, projects: Array(projects), size: after.tasks.count)
        // Whatever takes something off the exclude list (an undo, say) asks like removing it does.
        if let new = after.settings, !Set(exclusions).isSubset(of: Set(new.exclusions)),
           guardrail.tier(for: .removeExclusion) == .ask, tier == .auto {
            tier = .ask
        }
        guard committedCount(after: after) <= 1 else { throw Failure.secondCommittedTask }
        let creates = Set(after.tasks.filter { tasksByID[$0.id] == nil }.map(\.id.rawValue)
            + after.projects.filter { projectsByID[$0.id] == nil }.map(\.id.rawValue))
        let operation = Ask.Operation(
            kind: kind, summary: summary, preview: preview, before: before, after: after, undoes: undoes,
            creates: creates)
        let outcome: Outcome
        switch tier {
        case .never:
            throw Failure.notAllowed(kind, tier)
        case .ask:
            outcome = .pending(hold(operation, startedBy: startedBy))
        case .auto:
            let entry = logEntry(for: operation, tier: .auto, startedBy: startedBy, confirmation: .notNeeded)
            try write(after, entries: [entry])
            outcome = .ran(entry.id)
        }
        return outcome
    }

    /// Reverses a logged Operation, as long as nothing it wrote has changed since.
    @discardableResult
    public func undo(_ id: LogEntry.ID, by startedBy: StartedBy = .dara) throws -> Outcome {
        guard let entry = operationLog.first(where: { $0.id == id }) else { throw Failure.unknownLogEntry(id) }
        guard entry.confirmation != .declined, entry.confirmation != .expired else { throw Failure.notUndoable(id) }
        guard isCurrent(entry.after) else { throw Failure.changedSince(id) }
        return try perform(.undo, "Undid: \(entry.summary)", by: startedBy, writing: entry.before, undoes: id)
    }

    // MARK: Asks

    /// Runs every Operation in the Ask, as long as nothing it would write has changed since.
    @discardableResult
    public func confirmAsk(_ id: Ask.ID) throws -> Outcome {
        expireDueAsks()
        guard let ask = asks.first(where: { $0.id == id }) else { throw Failure.unknownAsk(id) }
        guard ask.operations.allSatisfy(isStillAsHeld) else { throw Failure.askChangedSince(id) }
        var change = Change()
        for operation in ask.operations {
            change.tasks += operation.after.tasks
            change.projects += operation.after.projects
            if let settings = operation.after.settings { change.settings = settings }
        }
        guard committedCount(after: change) <= 1 else { throw Failure.secondCommittedTask }
        let entries = ask.operations.map {
            logEntry(for: $0, tier: .ask, startedBy: ask.startedBy, confirmation: .confirmed)
        }
        try write(change, entries: entries)
        asks.removeAll { $0.id == id }
        return .ran(entries.last!.id)
    }

    /// Drops the Ask; nothing runs, and the log says so.
    public func declineAsk(_ id: Ask.ID) throws {
        expireDueAsks()
        guard let ask = asks.first(where: { $0.id == id }) else { throw Failure.unknownAsk(id) }
        try close(ask, as: .declined, saying: "Not run")
    }

    /// The conversation ended: its Asks expire.
    public func endSession(_ id: String) {
        for ask in asks where ask.session == id {
            try? close(ask, as: .expired, saying: "Expired, not run")
        }
    }

    /// Asks past their time expire, unrun, logged at the moment they expired.
    public func expireDueAsks() {
        for ask in asks where ask.expires <= clock.now {
            try? close(ask, as: .expired, saying: "Expired, not run", at: ask.expires)
        }
    }

    /// The helper is quitting: every conversation ends, so every Ask expires.
    public func expireAllAsks() {
        for ask in asks {
            try? close(ask, as: .expired, saying: "Expired, not run")
        }
    }

    /// Holds an Operation for confirmation, joining a recent Ask from the same conversation when
    /// it touches nothing that Ask already will.
    private func hold(_ operation: Ask.Operation, startedBy: StartedBy) -> Ask.ID {
        if let session, let index = asks.lastIndex(where: { ask in
            ask.session == session && ask.startedBy == startedBy
                && clock.now.timeIntervalSince(ask.created) <= Self.askGroupWindow
                && ask.touches.isDisjoint(with: operation.touches) && operation.after.settings == nil
        }) {
            asks[index].operations.append(operation)
            return asks[index].id
        }
        let ask = Ask(
            id: Ask.ID(), startedBy: startedBy, session: session, created: clock.now,
            expires: clock.now + Self.askExpiresAfter, operations: [operation])
        asks.append(ask)
        return ask.id
    }

    /// Logs every Operation in the Ask as not run, then forgets it. A failed log write keeps it waiting.
    private func close(_ ask: Ask, as confirmation: Confirmation, saying reason: String, at time: Date? = nil) throws {
        let entries = ask.operations.map { operation in
            LogEntry(
                id: LogEntry.ID(), at: time ?? clock.now, kind: operation.kind, summary: "\(reason): \(operation.summary)",
                tier: .ask, startedBy: ask.startedBy, confirmation: confirmation, before: Change(), after: Change(),
                undoes: nil)
        }
        try write(Change(), entries: entries)
        asks.removeAll { $0.id == ask.id }
    }

    private func logEntry(
        for operation: Ask.Operation, tier: Tier, startedBy: StartedBy, confirmation: Confirmation
    ) -> LogEntry {
        LogEntry(
            id: LogEntry.ID(), at: clock.now, kind: operation.kind, summary: operation.summary, tier: tier,
            startedBy: startedBy, confirmation: confirmation, before: operation.before, after: operation.after,
            undoes: operation.undoes)
    }

    /// Stores the change and its log entries, then applies them. A failed store write changes nothing.
    private func write(_ change: Change, entries: [LogEntry]) throws {
        try store.write(change, log: entries)
        apply(change)
        if !change.projects.isEmpty { forgetStaleGuesses() }
        operationLog += entries
        resolve(now.visit)
    }

    /// Whether what the Operation will overwrite is as it was when held: unchanged where it existed,
    /// still absent where the Operation creates it.
    private func isStillAsHeld(_ operation: Ask.Operation) -> Bool {
        operation.before.tasks.allSatisfy { task in
            operation.creates.contains(task.id.rawValue) ? tasksByID[task.id] == nil : tasksByID[task.id] == task
        }
            && operation.before.projects.allSatisfy { project in
                operation.creates.contains(project.id.rawValue) ? projectsByID[project.id] == nil : projectsByID[project.id] == project
            }
            && (operation.before.settings.map { $0 == settings } ?? true)
    }

    /// Whether everything in `change` is still exactly as it says.
    private func isCurrent(_ change: Change) -> Bool {
        change.tasks.allSatisfy { tasksByID[$0.id] == $0 }
            && change.projects.allSatisfy { projectsByID[$0.id] == $0 }
            && (change.settings.map { $0 == settings } ?? true)
    }

    // MARK: Tiers

    /// Makes an Operation ask first, everywhere or only for one Project.
    @discardableResult
    public func tighten(_ kind: OperationKind, in project: Project.ID? = nil) throws -> Outcome {
        guard Guardrail.canTighten(kind) else { throw Failure.cannotTighten(kind) }
        return try setRule(GuardrailRule(kind: kind, project: project, tier: .ask), "Ask first for \(kind.rawValue)")
    }

    /// Lets an Ask Operation run without asking, for that Operation only and optionally one Project.
    @discardableResult
    public func loosen(_ kind: OperationKind, in project: Project.ID? = nil) throws -> Outcome {
        guard Guardrail.canLoosen(kind) else { throw Failure.cannotLoosen(kind) }
        return try setRule(GuardrailRule(kind: kind, project: project, tier: .auto), "Run \(kind.rawValue) without asking")
    }

    /// Back to the default tier for that Operation and scope.
    @discardableResult
    public func resetTier(_ kind: OperationKind, in project: Project.ID? = nil) throws -> Outcome {
        return try perform(.changeGuardrail, "Default tier for \(kind.rawValue)", by: .dara,
                           writing: changingSettings { $0.guardrailRules.removeAll { $0.kind == kind && $0.project == project } })
    }

    private func setRule(_ rule: GuardrailRule, _ summary: String) throws -> Outcome {
        let scope = rule.project.flatMap(project).map { " in \($0.name)" } ?? ""
        return try perform(.changeGuardrail, summary + scope, by: .dara, writing: changingSettings { settings in
            settings.guardrailRules.removeAll { $0.kind == rule.kind && $0.project == rule.project }
            settings.guardrailRules.append(rule)
        })
    }

    /// What `change` will overwrite. Something new is recorded as it would be after an undo:
    /// a Task in the Deleted list, a Project archived.
    private func currentVersions(of change: Change) -> Change {
        Change(
            tasks: change.tasks.map { tasksByID[$0.id] ?? $0.deleted(at: clock.now) },
            projects: change.projects.map { projectsByID[$0.id] ?? $0.archived() },
            settings: change.settings.map { _ in settings })
    }

    /// How many Tasks in play would be committed once `change` is written.
    private func committedCount(after change: Change) -> Int {
        var tasks = tasksByID
        for task in change.tasks { tasks[task.id] = task }
        return tasks.values.filter { $0.deletedAt == nil && $0.status == .committed }.count
    }

    /// Trimmed text, or `failure` if nothing is left.
    static func nonEmpty(_ text: String, else failure: Failure) throws -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw failure }
        return text
    }

    private func apply(_ change: Change) {
        if let settings = change.settings { self.settings = settings }
        for task in change.tasks { tasksByID[task.id] = task }
        for project in change.projects { projectsByID[project.id] = project }
    }

    // MARK: Resolving Now

    /// Settles Now. In order: Away has no Project; a meeting decides while Dara sits still; Dara's
    /// correction for this window; a Matcher on the foreground window; a meeting under way; and,
    /// in a Neutral app or site, the last Project for up to `neutralHoldsFor` of Neutral.
    func resolve(_ visit: Now.Visit?) {
        // Re-applied so a new exclusion scrubs the window already in front.
        let visit = visit.map { Now.Visit(window: excluding($0.window), since: $0.since) }
        let window = visit?.window
        if window != now.window { confidentBeforeWindow = lastConfident }
        // A correction, and its offer, are for the window they were made on; any other window ends them.
        if let correction, correction.window != window {
            self.correction = nil
            offer = nil
        }
        let corrected = correction?.to
        let meeting = meetingMatch()
        let isAway = isIdle && meeting == nil
        let foreground = corrected == nil ? window.flatMap(foregroundMatch) : nil
        let neutral: NeutralKey? = window.flatMap { window in
            if corrected == .neutral { return fitting.proposedNeutral(for: window) }
            return corrected == nil && foreground == nil ? neutralKey(for: window) : nil
        }

        let confident: Now.Match? = if isAway {
            nil
        } else if isIdle {
            meeting
        } else if case let .project(project)? = corrected {
            Now.Match(project: project, basis: .correction)
        } else if corrected == Correction.none {
            nil
        } else {
            foreground ?? meeting
        }
        var match = confident
        // The hold's clock runs only while the hold is what decides Now.
        if confident == nil, !isAway, !isIdle, corrected != Correction.none, let neutral {
            neutralSince = neutralSince ?? clock.now
            // A window corrected to Neutral had matched the wrong Project, so it holds the one from
            // before it; a window just made Neutral holds that too until it has held anything.
            let from = corrected == .neutral ? confidentBeforeWindow : lastConfident ?? confidentBeforeWindow
            match = from.flatMap { hold(neutral, keeping: $0) }
        } else {
            neutralSince = nil
        }

        // Nothing else places the window: show Haiku's cached guess for it, if any.
        let placed = match != nil || neutral != nil || corrected != nil || isAway
        if !placed, let window { match = guessMatch(for: window) }

        if let match, !match.isGuess { lastMatched[match.project] = clock.now }
        // A guess is never confident, so it is never what a Neutral window holds.
        lastConfident = match?.isGuess == true ? nil : match?.project
        now = Now(visit: visit, match: match, isAway: isAway, neutral: neutral)
        trackGuessWatch(placed: placed)
        trackAfterResolve()
    }

    /// Writes a closed Now history block.
    func recordHistory(_ block: NowBlock) throws {
        try store.record(block)
    }

    /// `project`, while the run of Neutral is young enough and the Project still active.
    private func hold(_ neutral: NeutralKey, keeping project: Project.ID) -> Now.Match? {
        guard let since = neutralSince, clock.now.timeIntervalSince(since) < Self.neutralHoldsFor,
              projectsByID[project]?.status == .active
        else { return nil }
        return Now.Match(project: project, basis: .neutralHold(neutral))
    }

    /// Whether the window is in any Neutral app or site, Matcher or not.
    func isNeutral(_ window: ActiveWindow) -> Bool {
        neutralKey(for: window) != nil
    }

    /// The Neutral app or site the window is in, from the defaults and Dara's own. Excluded time
    /// counts as Neutral.
    private func neutralKey(for window: ActiveWindow) -> NeutralKey? {
        if window.isExcluded { return .excluded }
        return (NeutralKey.defaults + neutrals).first { fitting.fits($0, window) }
    }

    private func foregroundMatch(for window: ActiveWindow) -> Now.Match? {
        mostSpecific(activeProjects.flatMap { project in
            project.matchers.filter { fitting.fits($0, window) }.map { Now.Match(project: project.id, basis: .matcher($0)) }
        })
    }

    private func meetingMatch() -> Now.Match? {
        let underWay = calendarEvents.filter { $0.isUnderWay(at: clock.now) }
        return mostSpecific(activeProjects.flatMap { project in
            project.matchers.flatMap { matcher in
                underWay.filter { fitting.fits(matcher, $0) }
                    .map { Now.Match(project: project.id, basis: .meeting(matcher, $0)) }
            }
        })
    }

    /// The most specific Matcher wins; equally specific ones go to the most recently matched
    /// Project, then to the first by name (candidates arrive in name order and `max` keeps the first).
    private func mostSpecific(_ candidates: [Now.Match]) -> Now.Match? {
        candidates.max { a, b in
            if let sa = a.evidence?.specificity, let sb = b.evidence?.specificity, sa != sb {
                return sa < sb
            }
            return (lastMatched[a.project] ?? .distantPast) < (lastMatched[b.project] ?? .distantPast)
        }
    }
}
