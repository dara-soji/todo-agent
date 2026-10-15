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

/// Every kind of Operation the assistant performs on its own data. None of them is Never: money,
/// credentials, system settings and permanent deletion have no Operation at all.
public enum OperationKind: String, Sendable, Codable, CaseIterable {
    case addTask, editTask, bulkEditTasks, commitTask, completeTask, snoozeTask, wakeTask, dropTask, deleteTask
    case restoreTask, skipTask, keepTask
    case declareProject, editProject, archiveProject, restoreProject
    /// Dara marking an app or site as Neutral.
    case markNeutral
    case addExclusion, removeExclusion
    case undo
    /// Dara tightening or loosening a tier.
    case changeGuardrail
}

/// Dara's change to a tier: Ask makes an Operation stricter, Auto loosens an Ask one. Optionally
/// only for one Project.
public struct GuardrailRule: Equatable, Sendable, Codable {
    public let kind: OperationKind
    public let project: Project.ID?
    public let tier: Tier

    public init(kind: OperationKind, project: Project.ID? = nil, tier: Tier) {
        self.kind = kind
        self.project = project
        self.tier = tier
    }
}

/// The rule placing each Operation in one tier. The helper enforces it, whoever starts the Operation.
public struct Guardrail {
    /// A bulk edit of more Tasks than this asks first.
    public static let bulkEditAsksAbove = 5

    var rules: [GuardrailRule] = []

    public static func defaultTier(_ kind: OperationKind) -> Tier {
        [.bulkEditTasks, .removeExclusion].contains(kind) ? .ask : .auto
    }

    /// Dara may tighten anything except changing tiers itself, what the helper does on its own, and
    /// "Treat as Neutral" and "Exclude", which apply straight away.
    public static func canTighten(_ kind: OperationKind) -> Bool {
        ![.changeGuardrail, .wakeTask, .markNeutral, .addExclusion].contains(kind)
    }

    /// Only an Ask Operation can be loosened, and only to Auto. Removing an exclusion always asks:
    /// loosening it would let private data out with a single click.
    public static func canLoosen(_ kind: OperationKind) -> Bool {
        defaultTier(kind) == .ask && kind != .removeExclusion
    }

    /// `projects` holds the Project of each Task or Project the Operation writes (nil for none);
    /// empty when asking about the Operation in general. `size` is how many Tasks it writes.
    func tier(for kind: OperationKind, projects: [Project.ID?] = [], size: Int = .max) -> Tier {
        var tier = Self.defaultTier(kind)
        if kind == .bulkEditTasks, size <= Self.bulkEditAsksAbove { tier = .auto }
        let loosened = rules.contains { rule in
            rule.tier == .auto && rule.kind == kind
                && (rule.project == nil || (!projects.isEmpty && projects.allSatisfy { $0 == rule.project }))
        }
        if tier == .ask, loosened { tier = .auto }
        // Stricter wins.
        let tightened = rules.contains { rule in
            rule.tier == .ask && rule.kind == kind && (rule.project == nil || projects.contains(rule.project))
        }
        if tightened { tier = .ask }
        return tier
    }
}

/// The Tasks, Projects and tier rules an Operation writes, each in its new state.
public struct Change: Equatable, Sendable, Codable {
    public var tasks: [Task]
    public var projects: [Project]
    /// The whole new set of tier rules, or nil if the Operation leaves them alone.
    public var guardrailRules: [GuardrailRule]?
    /// The whole new set of apps and sites Dara made Neutral, or nil if left alone.
    public var neutrals: [NeutralKey]?
    /// The whole new exclude list, or nil if left alone.
    public var exclusions: [Exclusion]?

    public init(
        tasks: [Task] = [], projects: [Project] = [], guardrailRules: [GuardrailRule]? = nil,
        neutrals: [NeutralKey]? = nil, exclusions: [Exclusion]? = nil
    ) {
        self.tasks = tasks
        self.projects = projects
        self.guardrailRules = guardrailRules
        self.neutrals = neutrals
        self.exclusions = exclusions
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
/// A write stores a change and its log entries together, or nothing at all.
public protocol AssistantStore {
    func load() throws -> StoreSnapshot
    func write(_ change: Change, log entries: [LogEntry]) throws
    /// Appends a closed Now history block.
    func record(_ block: NowBlock) throws
}

/// Everything the store holds.
public struct StoreSnapshot: Equatable, Sendable {
    public var projects: [Project]
    public var tasks: [Task]
    public var log: [LogEntry]
    public var guardrailRules: [GuardrailRule]
    public var neutrals: [NeutralKey]
    public var exclusions: [Exclusion]
    public var history: [NowBlock]

    public init(
        projects: [Project] = [], tasks: [Task] = [], log: [LogEntry] = [], guardrailRules: [GuardrailRule] = [],
        neutrals: [NeutralKey] = [], exclusions: [Exclusion] = [], history: [NowBlock] = []
    ) {
        self.history = history
        self.exclusions = exclusions
        self.projects = projects
        self.tasks = tasks
        self.log = log
        self.guardrailRules = guardrailRules
        self.neutrals = neutrals
    }

    /// Writes each changed Task and Project over its old version, and any new rules or Neutrals.
    public mutating func apply(_ change: Change) {
        if let rules = change.guardrailRules { guardrailRules = rules }
        if let neutrals = change.neutrals { self.neutrals = neutrals }
        if let exclusions = change.exclusions { self.exclusions = exclusions }
        for task in change.tasks {
            if let index = tasks.firstIndex(where: { $0.id == task.id }) { tasks[index] = task } else { tasks.append(task) }
        }
        for project in change.projects {
            if let index = projects.firstIndex(where: { $0.id == project.id }) { projects[index] = project } else { projects.append(project) }
        }
    }
}
