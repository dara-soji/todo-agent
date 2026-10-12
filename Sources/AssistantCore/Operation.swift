import Foundation

/// Who started an Operation.
public enum StartedBy: String, Sendable, Codable {
    case helper, claudeCode, dara
}

/// The Guardrail tier an Operation falls in.
public enum Tier: String, Sendable, Codable {
    /// Runs without asking: private to Dara, undoable and invisible to anyone else.
    case auto
    /// Waits for Dara to confirm in the menu bar.
    case ask
    /// Not performed at all.
    case never
}

public enum Confirmation: String, Sendable, Codable {
    case notNeeded, confirmed, declined, expired
}

/// Every kind of Operation the assistant performs on its own data.
public enum OperationKind: String, Sendable, Codable {
    case addTask, editTask, commitTask, completeTask, snoozeTask, wakeTask, dropTask, deleteTask, restoreTask
    case declareProject, editProject, archiveProject, restoreProject
    case undo
}

/// The rule placing each Operation in one tier. The helper enforces it, whoever starts the Operation.
/// Every v1 Operation on the assistant's own data is Auto; Ask arrives with the confirm flow.
struct Guardrail {
    func tier(for kind: OperationKind) -> Tier {
        .auto
    }
}

/// The Tasks and Projects an Operation writes, each in its new state.
public struct Change: Equatable, Sendable, Codable {
    public var tasks: [Task]
    public var projects: [Project]

    public init(tasks: [Task] = [], projects: [Project] = []) {
        self.tasks = tasks
        self.projects = projects
    }
}

/// One line of the Operation log: what ran, its tier, who started it, whether it was confirmed,
/// and how to undo it.
public struct LogEntry: Identifiable, Equatable, Sendable, Codable {
    public struct ID: Hashable, Sendable, Codable {
        public let rawValue: UUID
        public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
    }

    public let id: ID
    public let at: Date
    public let kind: OperationKind
    /// A short human description, e.g. "Added “Write tests”".
    public let summary: String
    public let tier: Tier
    public let startedBy: StartedBy
    public let confirmation: Confirmation
    /// The undo data: everything the Operation wrote, as it was before.
    public let before: Change
    public let after: Change
    /// For an undo, the entry it reversed.
    public let undoes: ID?
}

/// Persistence port. The helper's SQLite store conforms; tests use an in-memory fake.
/// A commit writes an Operation's change and its log entry together, or nothing at all.
public protocol AssistantStore {
    func load() throws -> StoreSnapshot
    func commit(_ change: Change, log entry: LogEntry) throws
}

/// Everything the store holds.
public struct StoreSnapshot: Equatable, Sendable {
    public var projects: [Project]
    public var tasks: [Task]
    public var log: [LogEntry]

    public init(projects: [Project] = [], tasks: [Task] = [], log: [LogEntry] = []) {
        self.projects = projects
        self.tasks = tasks
        self.log = log
    }

    /// Writes each changed Task and Project over its old version.
    public mutating func apply(_ change: Change) {
        for task in change.tasks {
            if let index = tasks.firstIndex(where: { $0.id == task.id }) { tasks[index] = task } else { tasks.append(task) }
        }
        for project in change.projects {
            if let index = projects.firstIndex(where: { $0.id == project.id }) { projects[index] = project } else { projects.append(project) }
        }
    }
}
