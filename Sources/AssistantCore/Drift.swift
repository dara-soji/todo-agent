import Foundation

/// The light prompt shown when Dara drifts: where Now is, against the Committed Task's Project.
public struct Nudge: Equatable, Sendable {
    public let task: Task.ID
    /// Nil when the Committed Task has no Project.
    public let committedProject: Project.ID?
    /// Nil when Now is on No Project.
    public let nowProject: Project.ID?

    public init(task: Task.ID, committedProject: Project.ID?, nowProject: Project.ID?) {
        self.task = task
        self.committedProject = committedProject
        self.nowProject = nowProject
    }
}

/// One Project-level block of Now history, with the Committed Task during it: no window titles or URLs.
public struct NowBlock: Equatable, Sendable {
    public let project: Project.ID
    public let committedTask: Task.ID?
    public let start: Date
    public let end: Date

    public init(project: Project.ID, committedTask: Task.ID?, start: Date, end: Date) {
        self.project = project
        self.committedTask = committedTask
        self.start = start
        self.end = end
    }
}

extension Assistant {
    /// Off the Committed Task's Project this long, confidently, is Drift.
    static let driftAfter: TimeInterval = 5 * 60
    /// On No Project this long and "New task?" is offered.
    static let newTaskAfter: TimeInterval = 10 * 60
    /// How long Quiet keeps Nudges back.
    static let quietFor: TimeInterval = 30 * 60

    /// Off the Committed Task's Project, on another Project or none, for `driftAfter`.
    /// Away time doesn't count.
    public var isDrifting: Bool {
        drift.since.map { clock.now.timeIntervalSince($0) >= Self.driftAfter } ?? false
    }

    /// Back to it, or Switch task: the Nudge goes, and doesn't come back this episode.
    public func dismissNudge() {
        nudge = nil
    }

    /// It's related: Now was really on the committed Project (or on none, for a Task with no
    /// Project), so it is corrected there. If that fails, the Nudge stays.
    public func nudgeIsRelated() throws {
        guard let nudge else { return }
        try correctNow(nudge.committedProject.map(Correction.project) ?? .none)
        self.nudge = nil
    }

    /// Quiet 30m: no Nudges for half an hour.
    public func quietNudges() {
        nudge = nil
        drift.quietUntil = clock.now + Self.quietFor
    }

    /// Adds the unplanned work as a Task and commits it, remembering the interrupted Task.
    @discardableResult
    public func addNewTask() throws -> Task {
        guard let title = newTaskTitle else { throw Failure.noOffer }
        let task = try quickAdd(title, start: true)
        newTaskOffer.dismissed = true
        return task
    }

    /// It's a quick one: no Task, and no asking again until Now is back on a Project.
    public func dismissNewTask() {
        newTaskOffer.dismissed = true
    }

    /// Writes the open Now history block, e.g. when the helper quits.
    public func closeNowHistory() {
        closeHistoryBlock(at: clock.now)
        openHistoryBlock = nil
    }

    // MARK: After each resolve

    /// Brings Drift, "New task?" and Now history up to date with Now.
    func trackAfterResolve() {
        trackDrift()
        trackNoProject()
        trackHistory()
    }

    /// An episode belongs to one Committed Task; no Committed Task, a different one, or Away starts
    /// afresh. Being on the Task's Project (or, for a Task with none, on No Project) ends the episode.
    private func trackDrift() {
        // Away, Excluded and guessed time don't count.
        let counts = !now.isAway && now.window?.isExcluded != true && now.match?.basis != .guess
        guard let task = committedTask, counts, drift.task == task.id else {
            drift = DriftState(task: committedTask?.id, quietUntil: drift.quietUntil)
            nudge = nil
            if committedTask != nil, counts { trackDrift() }
            return
        }
        if now.project == task.project {
            drift = DriftState(task: task.id, quietUntil: drift.quietUntil)
            nudge = nil
            return
        }
        drift.since = drift.since ?? clock.now
        let quiet = drift.quietUntil.map { clock.now < $0 } ?? false
        if isDrifting, !drift.nudged, !quiet {
            drift.nudged = true
            nudge = Nudge(task: task.id, committedProject: task.project, nowProject: now.project)
        }
    }

    /// Away doesn't count toward the stretch, but doesn't undo "It's a quick one" either.
    private func trackNoProject() {
        if now.isAway || now.window?.isExcluded == true {
            newTaskOffer.since = nil
        } else if now.window != nil, now.project == nil {
            newTaskOffer.since = newTaskOffer.since ?? clock.now
        } else {
            newTaskOffer = NewTaskOffer()
        }
    }

    /// "New task: <window title>?" once Now has been on No Project for `newTaskAfter`.
    var newTaskTitle: String? {
        guard let since = newTaskOffer.since, !newTaskOffer.dismissed,
              clock.now.timeIntervalSince(since) >= Self.newTaskAfter, let window = now.window
        else { return nil }
        return window.title.flatMap { $0.isEmpty ? nil : $0 } ?? window.app.name
    }

    private func trackHistory() {
        // Only confident time goes into Now history; a guess is not.
        let confident = now.match?.basis == .guess ? nil : now.project
        let key = confident.map { (project: $0, task: committedTask?.id) }
        if let open = openHistoryBlock, let key, open.project == key.project, open.task == key.task { return }
        // Going Away, the block ended when input stopped, not when Away was noticed.
        closeHistoryBlock(at: now.isAway ? clock.now - idleSeconds : clock.now)
        openHistoryBlock = key.map { OpenBlock(project: $0.project, task: $0.task, start: clock.now) }
    }

    private func closeHistoryBlock(at end: Date) {
        guard let open = openHistoryBlock, end > open.start else { return }
        // A lost block only thins the history; it never blocks Now.
        try? recordHistory(NowBlock(project: open.project, committedTask: open.task, start: open.start, end: end))
    }
}

/// Drift bookkeeping for one episode of one Committed Task.
struct DriftState {
    var task: Task.ID?
    /// When the current stretch off the committed Project began.
    var since: Date?
    /// Whether this episode has had its Nudge.
    var nudged = false
    var quietUntil: Date?

    init(task: Task.ID? = nil, quietUntil: Date? = nil) {
        self.task = task
        self.quietUntil = quietUntil
    }
}

/// "New task?" bookkeeping for one stretch on No Project.
struct NewTaskOffer {
    var since: Date?
    var dismissed = false
}

/// The Now history block being timed.
struct OpenBlock {
    let project: Project.ID
    let task: Task.ID?
    let start: Date
}
