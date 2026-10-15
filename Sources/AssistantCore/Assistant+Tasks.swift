import Foundation

extension Assistant {
    /// Every Task not in the Deleted list, finished or not, oldest first.
    public var tasks: [Task] {
        tasksByID.values.filter { $0.deletedAt == nil }.sorted(by: Self.byCreation)
    }

    /// The Deleted list, most recently deleted first. Restorable until purged.
    public var deletedTasks: [Task] {
        tasksByID.values.filter { $0.deletedAt != nil }.sorted { $0.deletedAt! > $1.deletedAt! }
    }

    public func task(_ id: Task.ID) -> Task? {
        tasksByID[id]
    }

    /// The Task Dara has accepted as what they are doing now.
    public var committedTask: Task? {
        tasks.first { $0.status == .committed }
    }

    // MARK: Adding

    /// Adds a by-hand Task to Now's Project. With `start`, it also becomes the Committed Task,
    /// and the Task it interrupts is marked to resume.
    @discardableResult
    public func quickAdd(_ title: String, start: Bool = false, by startedBy: StartedBy = .dara) throws -> Task {
        let task = try newTask(TaskDraft(title: title, project: now.project))
        guard start else {
            try perform(.addTask, "Added “\(task.title)”", by: startedBy, writing: Change(tasks: [task]))
            return task
        }
        try perform(.addTask, "Added and started “\(task.title)”", by: startedBy,
                    writing: committing(task, interrupting: true))
        return tasksByID[task.id] ?? task
    }

    @discardableResult
    public func addTask(_ draft: TaskDraft, by startedBy: StartedBy = .dara) throws -> Task {
        let task = try newTask(draft)
        try perform(.addTask, "Added “\(task.title)”", by: startedBy, writing: Change(tasks: [task]))
        return task
    }

    private func newTask(_ draft: TaskDraft) throws -> Task {
        Task(
            id: Task.ID(), title: try Self.nonEmpty(draft.title, else: .emptyTitle), source: draft.source,
            backLink: draft.backLink, status: .open, created: clock.now, deadline: draft.deadline,
            project: draft.project, effort: draft.effort, kind: draft.kind)
    }

    // MARK: Changing

    @discardableResult
    public func editTask(_ id: Task.ID, _ changes: TaskChanges, by startedBy: StartedBy = .dara) throws -> Outcome {
        let changes = try validated(changes)
        return try change(id, .editTask, "Edited", by: startedBy) { changes.apply(to: &$0) }
    }

    /// Makes the Task the Committed Task; the previous one goes back to open. As an interruption
    /// (starting a Task just added), the previous one is also marked to resume.
    @discardableResult
    public func commitTask(_ id: Task.ID, asInterruption: Bool = false, by startedBy: StartedBy = .dara) throws -> Outcome {
        let task = try existing(id)
        guard task.deletedAt == nil else { throw Failure.deletedTask(id) }
        return try perform(.commitTask, "Started “\(task.title)”", by: startedBy,
                           writing: committing(task, interrupting: asInterruption))
    }

    /// Dara marks a Task done, directly or by asking in conversation; the helper alone may at most suggest it.
    @discardableResult
    public func completeTask(_ id: Task.ID, by startedBy: StartedBy = .dara) throws -> Outcome {
        guard startedBy != .helper else { throw Failure.onlyDaraMarksDone }
        return try change(id, .completeTask, "Completed", by: startedBy) { $0.status = .done }
    }

    /// Snoozes until `until`, or with no wake time when waiting on someone (say who in `note`).
    @discardableResult
    public func snoozeTask(_ id: Task.ID, until: Date?, note: String? = nil, by startedBy: StartedBy = .dara) throws -> Outcome {
        return try change(id, .snoozeTask, "Snoozed", by: startedBy) {
            $0.status = .snoozed(until: until, note: note)
            $0.clearSkips()
        }
    }

    @discardableResult
    public func snoozeTask(_ id: Task.ID, forHours hours: Double, by startedBy: StartedBy = .dara) throws -> Outcome {
        try snoozeTask(id, until: clock.now + hours * 60 * 60, by: startedBy)
    }

    /// Snoozes until 9:00 tomorrow.
    @discardableResult
    public func snoozeTillTomorrow(_ id: Task.ID, by startedBy: StartedBy = .dara) throws -> Outcome {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: clock.now))!
        return try snoozeTask(id, until: calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow)!, by: startedBy)
    }

    @discardableResult
    public func dropTask(_ id: Task.ID, by startedBy: StartedBy = .dara) throws -> Outcome {
        return try change(id, .dropTask, "Dropped", by: startedBy) {
            $0.status = .dropped
            $0.clearSkips()
        }
    }

    // MARK: Next

    /// The one Task to do after Now, chosen by rule. Suggestions never feed it.
    public var next: Next {
        let open = tasks.filter { $0.status == .open }
        return NextRule(now: clock.now, calendar: calendar, currentProject: now.project, events: calendarEvents)
            .choose(from: open)
    }

    /// Accepts Next: it becomes the Committed Task.
    @discardableResult
    public func startNext(by startedBy: StartedBy = .dara) throws -> Outcome {
        guard let id = next.task else { throw Failure.nothingNext }
        return try commitTask(id, by: startedBy)
    }

    /// Takes the Task out of Next for two hours. The third skip asks Dara what to do with it.
    @discardableResult
    public func skipTask(_ id: Task.ID, by startedBy: StartedBy = .dara) throws -> Outcome {
        guard try existing(id).status == .open else { throw Failure.notOpen(id) }
        let until = clock.now + Self.skipFor
        return try change(id, .skipTask, "Skipped", by: startedBy) {
            $0.skippedUntil = until
            $0.skipCount += 1
        }
    }

    /// Dara's "Keep it" for a Task skipped three times: its skips start over, though it still sits
    /// out the skip just made.
    @discardableResult
    public func keepTask(_ id: Task.ID, by startedBy: StartedBy = .dara) throws -> Outcome {
        return try change(id, .keepTask, "Kept", by: startedBy) { $0.skipCount = 0 }
    }

    /// How long Skip keeps a Task out of Next.
    static let skipFor: TimeInterval = 2 * 60 * 60
    /// The skip that asks what to do.
    static let skipsBeforeAsking = 3

    /// Choices waiting for Dara in the menu: Asks to confirm first, then Tasks skipped three times.
    public var decisions: [Decision] {
        asks.filter { $0.expires > clock.now }.map { .confirm($0.id) } + offerDecision + tasks.filter { $0.status == .open && $0.skipCount >= Self.skipsBeforeAsking }.map { .skippedThreeTimes($0.id) }
    }

    /// Moves the Task to the Deleted list, where it can be restored. A committed Task stops being committed.
    @discardableResult
    public func deleteTask(_ id: Task.ID, by startedBy: StartedBy = .dara) throws -> Outcome {
        let at = clock.now
        return try change(id, .deleteTask, "Deleted", by: startedBy) { $0 = $0.deleted(at: at) }
    }

    @discardableResult
    public func restoreTask(_ id: Task.ID, by startedBy: StartedBy = .dara) throws -> Outcome {
        return try change(id, .restoreTask, "Restored", by: startedBy) { $0.deletedAt = nil }
    }

    /// Edits several Tasks at once. More than a few asks Dara first, with their titles as the preview.
    @discardableResult
    public func editTasks(_ ids: [Task.ID], _ changes: TaskChanges, by startedBy: StartedBy = .dara) throws -> Outcome {
        let changes = try validated(changes)
        let current = try ids.map(existing)
        let edited = current.map { task in
            var task = task
            changes.apply(to: &task)
            return task
        }
        // The preview names the Tasks as they are now, so a bulk rename still shows which ones.
        return try perform(.bulkEditTasks, "Edited \(ids.count) Tasks: \(changes.fieldNames.joined(separator: ", "))",
                           by: startedBy, writing: Change(tasks: edited), preview: current.map(\.title))
    }

    /// Snoozed Tasks whose wake time has come go back to open, as Operations the helper starts.
    func wakeSnoozedTasks() {
        for task in tasks {
            guard case let .snoozed(until?, _) = task.status, until <= clock.now else { continue }
            // A failed write leaves it snoozed; the next Signal tries again.
            _ = try? change(task.id, .wakeTask, "Woke", by: .helper) { $0.status = .open }
        }
    }

    // MARK: Helpers

    /// The writes that make `task` the Committed Task. An interruption marks the Task it replaces
    /// to resume; an ordinary switch doesn't.
    private func committing(_ task: Task, interrupting: Bool) -> Change {
        var tasks: [Task] = []
        if let current = committedTask, current.id != task.id {
            var previous = current
            previous.status = .open
            previous.resumeAfterInterruption = interrupting
            tasks.append(previous)
        }
        var committed = task
        committed.status = .committed
        committed.resumeAfterInterruption = false
        tasks.append(committed)
        return Change(tasks: tasks)
    }

    private func change(_ id: Task.ID, _ kind: OperationKind, _ verb: String, by startedBy: StartedBy, _ edit: (inout Task) -> Void) throws -> Outcome {
        var task = try existing(id)
        edit(&task)
        return try perform(kind, "\(verb) “\(task.title)”", by: startedBy, writing: Change(tasks: [task]))
    }

    /// The changes with a trimmed, non-empty title and a Project that exists.
    private func validated(_ changes: TaskChanges) throws -> TaskChanges {
        var changes = changes
        changes.title = try changes.title.map { try Self.nonEmpty($0, else: .emptyTitle) }
        if case let .some(project?) = changes.project, projectsByID[project] == nil { throw Failure.unknownProject(project) }
        return changes
    }

    private func existing(_ id: Task.ID) throws -> Task {
        guard let task = tasksByID[id] else { throw Failure.unknownTask(id) }
        return task
    }

    private static func byCreation(_ a: Task, _ b: Task) -> Bool {
        a.created == b.created ? a.title < b.title : a.created < b.created
    }
}

extension Task.Status {
    /// Open, committed or snoozed: work still to do.
    public var isUnfinished: Bool {
        switch self {
        case .open, .committed, .snoozed: true
        case .done, .dropped: false
        }
    }
}

extension Task {
    mutating func clearSkips() {
        skippedUntil = nil
        skipCount = 0
    }

    /// The Task as it sits in the Deleted list. A committed Task stops being committed.
    func deleted(at time: Date) -> Task {
        var task = self
        task.deletedAt = time
        if task.status == .committed { task.status = .open }
        return task
    }
}
