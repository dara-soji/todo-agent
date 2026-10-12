import Foundation

extension Assistant {
    /// Tasks in play (not deleted), oldest first.
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
            id: Task.ID(), title: try Self.validTitle(draft.title), source: draft.source, backLink: draft.backLink,
            status: .open, created: clock.now, deadline: draft.deadline, project: draft.project,
            effort: draft.effort, kind: draft.kind, resumeAfterInterruption: false, deletedAt: nil)
    }

    // MARK: Changing

    public func editTask(_ id: Task.ID, _ changes: TaskChanges, by startedBy: StartedBy = .dara) throws {
        let title = try changes.title.map(Self.validTitle)
        try change(id, .editTask, "Edited", by: startedBy) { task in
            if let title { task.title = title }
            if let deadline = changes.deadline { task.deadline = deadline }
            if let project = changes.project { task.project = project }
            if let effort = changes.effort { task.effort = effort }
            if let kind = changes.kind { task.kind = kind }
        }
    }

    /// Makes the Task the Committed Task; the previous one goes back to open.
    public func commitTask(_ id: Task.ID, by startedBy: StartedBy = .dara) throws {
        let task = try existing(id)
        try perform(.commitTask, "Started “\(task.title)”", by: startedBy, writing: committing(task, interrupting: false))
    }

    /// Only Dara marks a Task done; the assistant may at most suggest it.
    public func completeTask(_ id: Task.ID, by startedBy: StartedBy = .dara) throws {
        try change(id, .completeTask, "Completed", by: startedBy) { $0.status = .done }
    }

    /// Snoozes until `until`, or with no wake time when waiting on someone (say who in `note`).
    public func snoozeTask(_ id: Task.ID, until: Date?, note: String? = nil, by startedBy: StartedBy = .dara) throws {
        try change(id, .snoozeTask, "Snoozed", by: startedBy) { $0.status = .snoozed(until: until, note: note) }
    }

    public func dropTask(_ id: Task.ID, by startedBy: StartedBy = .dara) throws {
        try change(id, .dropTask, "Dropped", by: startedBy) { $0.status = .dropped }
    }

    /// Moves the Task to the Deleted list, where it can be restored. A committed Task stops being committed.
    public func deleteTask(_ id: Task.ID, by startedBy: StartedBy = .dara) throws {
        let at = clock.now
        try change(id, .deleteTask, "Deleted", by: startedBy) { $0 = $0.deleted(at: at) }
    }

    public func restoreTask(_ id: Task.ID, by startedBy: StartedBy = .dara) throws {
        try change(id, .restoreTask, "Restored", by: startedBy) { $0.deletedAt = nil }
    }

    /// Snoozed Tasks whose wake time has come go back to open, as Operations the helper starts.
    func wakeSnoozedTasks() {
        for task in tasks {
            guard case let .snoozed(until?, _) = task.status, until <= clock.now else { continue }
            // A failed write leaves it snoozed; the next Signal tries again.
            try? change(task.id, .wakeTask, "Woke", by: .helper) { $0.status = .open }
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

    private func change(_ id: Task.ID, _ kind: OperationKind, _ verb: String, by startedBy: StartedBy, _ edit: (inout Task) -> Void) throws {
        var task = try existing(id)
        edit(&task)
        try perform(kind, "\(verb) “\(task.title)”", by: startedBy, writing: Change(tasks: [task]))
    }

    private func existing(_ id: Task.ID) throws -> Task {
        guard let task = tasksByID[id] else { throw Failure.unknownTask(id) }
        return task
    }

    private static func validTitle(_ title: String) throws -> String {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw Failure.emptyTitle }
        return title
    }

    private static func byCreation(_ a: Task, _ b: Task) -> Bool {
        a.created == b.created ? a.title < b.title : a.created < b.created
    }
}

extension Task {
    /// The Task as it sits in the Deleted list. A committed Task stops being committed.
    func deleted(at time: Date) -> Task {
        var task = self
        task.deletedAt = time
        if task.status == .committed { task.status = .open }
        return task
    }
}
