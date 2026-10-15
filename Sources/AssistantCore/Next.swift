import Foundation

/// The one Task the assistant recommends after Now. There is always exactly one Next.
public enum Next: Equatable, Sendable {
    /// `wontFitBefore` is set when no open Task fits the next free calendar block, so this is
    /// the best one anyway, and it won't be finished before that time.
    case task(Task.ID, reason: Reason, wontFitBefore: Date?)
    /// Nothing is open. Once Suggestions exist (ticket 13), "Review Suggestions (n)" comes before this.
    case planTomorrow

    /// The deciding factor, as shown under Next.
    public enum Reason: Equatable, Sendable {
        case resume
        case due(Date)
        case continues(Project.ID)
        case deepInTheMorning
        case shallowInTheAfternoon
        case oldest
    }

    public var task: Task.ID? {
        if case let .task(id, _, _) = self { return id }
        return nil
    }

    public var wontFitBefore: Date? {
        if case let .task(_, _, date) = self { return date }
        return nil
    }
}

/// Something waiting for Dara's choice in the menu. Decisions never pop up on their own.
public enum Decision: Equatable, Sendable {
    /// Operations waiting for Dara to confirm or decline.
    case confirm(Ask.ID)
    /// After "Not this": make the window always match the Project? Always / Just this once.
    case alwaysMatch(Matcher, Project.ID)
    /// After "Not this → Neutral": always treat the app or site as Neutral? Always / Just this once.
    case alwaysNeutral(NeutralKey)
    /// Skipped three times: Snooze till tomorrow, Drop it, or Keep it.
    case skippedThreeTimes(Task.ID)
}

/// How Next is chosen: an interrupted Task comes back first; otherwise candidates that fit the next
/// free block, ranked by deadline urgency, then continuing Now's Project, then deep-in-the-morning /
/// shallow-in-the-afternoon, then age. Deadlines come first: a Task due within a day is never
/// filtered out for not fitting; it is flagged instead.
struct NextRule {
    /// Effort as time, for fitting the free block. Unknown effort is assumed to fit.
    static let minutes: [Task.Effort: Double] = [.small: 30, .medium: 90, .large: 180]
    /// Deep work before this hour, shallow after.
    static let afternoonStartsAt = 12

    let now: Date
    let calendar: Calendar
    let currentProject: Project.ID?
    let events: [CalendarEvent]

    func choose(from open: [Task]) -> Next {
        // A skipped Task sits out its two hours, unless nothing else is open.
        let notSkipped = open.filter { ($0.skippedUntil ?? .distantPast) <= now }
        let candidates = notSkipped.isEmpty ? open : notSkipped
        guard !candidates.isEmpty else { return .planTomorrow }
        if let resume = candidates.filter(\.resumeAfterInterruption).min(by: { $0.created < $1.created }) {
            return .task(resume.id, reason: .resume, wontFitBefore: nil)
        }

        let block = freeBlock()
        let best = candidates.min(by: ranksAbove)!
        if urgency(best) == Self.dueWithinADay {
            return .task(best.id, reason: reason(for: best), wontFitBefore: fits(best, block) ? nil : block.end)
        }
        let fitting = candidates.filter { fits($0, block) }
        let pool = fitting.isEmpty ? candidates : fitting
        let chosen = pool.min(by: ranksAbove)!
        return .task(chosen.id, reason: reason(for: chosen), wontFitBefore: fitting.isEmpty ? block.end : nil)
    }

    // MARK: Free block

    /// From now, or the end of any meetings under way, to the start of the next meeting today
    /// (nil: no more meetings today).
    private func freeBlock() -> (start: Date, end: Date?) {
        var start = now
        while let ends = events.filter({ $0.isUnderWay(at: start) }).map(\.end).max() {
            start = ends
        }
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: start))!
        return (start, events.map(\.start).filter { $0 >= start && $0 < endOfDay }.min())
    }

    private func fits(_ task: Task, _ block: (start: Date, end: Date?)) -> Bool {
        guard let end = block.end, let effort = task.effort, let minutes = Self.minutes[effort] else { return true }
        return block.start + minutes * 60 <= end
    }

    // MARK: Ranking

    private func ranksAbove(_ a: Task, _ b: Task) -> Bool {
        let (ua, ub) = (urgency(a), urgency(b))
        if ua != ub { return ua > ub }
        if ua > 0, a.deadline != b.deadline { return a.deadline! < b.deadline! }
        let (ca, cb) = (continues(a), continues(b))
        if ca != cb { return ca }
        let (ka, kb) = (suitsTimeOfDay(a), suitsTimeOfDay(b))
        if ka != kb { return ka }
        if a.created != b.created { return a.created < b.created }
        return a.title < b.title
    }

    private static let dueWithinADay = 2
    private static let dueWithinAWeek = 1

    /// Overdue or due within a day, due within a week, or later / no deadline (0). Deadlines further
    /// out don't outrank anything yet.
    private func urgency(_ task: Task) -> Int {
        guard let deadline = task.deadline else { return 0 }
        let left = deadline.timeIntervalSince(now)
        if left <= 24 * 60 * 60 { return Self.dueWithinADay }
        if left <= 7 * 24 * 60 * 60 { return Self.dueWithinAWeek }
        return 0
    }

    private func continues(_ task: Task) -> Bool {
        task.project != nil && task.project == currentProject
    }

    private var isMorning: Bool {
        calendar.component(.hour, from: now) < Self.afternoonStartsAt
    }

    private func suitsTimeOfDay(_ task: Task) -> Bool {
        task.kind == (isMorning ? .deep : .shallow)
    }

    private func reason(for task: Task) -> Next.Reason {
        if urgency(task) > 0, let deadline = task.deadline { return .due(deadline) }
        if continues(task), let project = task.project { return .continues(project) }
        if suitsTimeOfDay(task) { return isMorning ? .deepInTheMorning : .shallowInTheAfternoon }
        return .oldest
    }
}
