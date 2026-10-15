import Foundation

/// The light prompt shown when Dara drifts: where Now is, against the Committed Task's Project.
public struct Nudge: Equatable, Sendable {
    public let task: Task.ID
    public let committedProject: Project.ID
    /// Nil when Now is on No Project.
    public let nowProject: Project.ID?

    public init(task: Task.ID, committedProject: Project.ID, nowProject: Project.ID?) {
        self.task = task
        self.committedProject = committedProject
        self.nowProject = nowProject
    }
}

/// One Project-level block of Now history: no window titles or URLs.
public struct NowBlock: Equatable, Sendable, Codable {
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

    /// It's related: Now was really on the committed Project, so it is corrected there.
    public func nudgeIsRelated() throws {
        guard let nudge else { return }
        self.nudge = nil
        try correctNow(.project(nudge.committedProject))
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
        newTask.dismissed = true
        return task
    }

    /// It's a quick one: no Task, and no asking again until Now is back on a Project.
    public func dismissNewTask() {
        newTask.dismissed = true
    }

    /// Writes the open Now history block, e.g. when the helper quits.
    public func closeNowHistory() {
        closeBlock()
        history = nil
    }

    // MARK: After each resolve

    /// Brings Drift, "New task?" and Now history up to date with Now.
    func track() {
        trackDrift()
        trackNoProject()
        trackHistory()
    }

    private func trackDrift() {
        guard let task = committedTask, let committedProject = task.project, !now.isAway else {
            drift.since = nil
            nudge = nil
            return
        }
        if now.project == committedProject {
            drift = DriftState(quietUntil: drift.quietUntil)
            nudge = nil
            return
        }
        drift.since = drift.since ?? clock.now
        let quiet = drift.quietUntil.map { clock.now < $0 } ?? false
        if isDrifting, !drift.nudged, !quiet {
            drift.nudged = true
            nudge = Nudge(task: task.id, committedProject: committedProject, nowProject: now.project)
        }
    }

    private func trackNoProject() {
        if now.window != nil, now.project == nil, !now.isAway {
            newTask.since = newTask.since ?? clock.now
        } else {
            newTask = NewTaskState()
        }
    }

    /// "New task: <window title>?" once Now has been on No Project for `newTaskAfter`.
    var newTaskTitle: String? {
        guard let since = newTask.since, !newTask.dismissed,
              clock.now.timeIntervalSince(since) >= Self.newTaskAfter, let window = now.window
        else { return nil }
        return window.title.flatMap { $0.isEmpty ? nil : $0 } ?? window.app.name
    }

    private func trackHistory() {
        let key = now.project.map { (project: $0, task: committedTask?.id) }
        if let open = history, let key, open.project == key.project, open.task == key.task { return }
        closeBlock()
        history = key.map { OpenBlock(project: $0.project, task: $0.task, start: clock.now) }
    }

    private func closeBlock() {
        guard let open = history, clock.now > open.start else { return }
        // A lost block only thins the history; it never blocks Now.
        try? recordHistory(NowBlock(project: open.project, committedTask: open.task, start: open.start, end: clock.now))
    }
}

/// Drift bookkeeping for one episode.
struct DriftState {
    /// When the current stretch off the committed Project began.
    var since: Date?
    /// Whether this episode has had its Nudge.
    var nudged = false
    var quietUntil: Date?
}

/// "New task?" bookkeeping for one stretch on No Project.
struct NewTaskState {
    var since: Date?
    var dismissed = false
}

/// The Now history block being timed.
struct OpenBlock {
    let project: Project.ID
    let task: Task.ID?
    let start: Date
}
