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
    /// Dara answering a Suggestion: accepting makes it a Task; dismissing drops it.
    case acceptSuggestion, dismissSuggestion
    /// Dara turning a Digest line into a Suggestion.
    case promoteDigestLine
    case addVIP, removeVIP
    /// The helper bringing a Task up to date with its Source (a new reply, a changed row); never
    /// over a title Dara set.
    case sourceUpdate
    /// Dara taking a sender off "Never from this sender".
    case forgetNoiseSender
    /// Dara choosing which Google Sheets are read.
    case registerSheet, unregisterSheet
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
        ![.changeGuardrail, .wakeTask, .markNeutral, .addExclusion, .sourceUpdate].contains(kind)
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

/// Dara's settings, stored whole: tier rules, Neutral apps and sites, the exclude list and VIPs.
public struct Settings: Equatable, Sendable, Codable {
    public var guardrailRules: [GuardrailRule]
    public var neutrals: [NeutralKey]
    public var exclusions: [Exclusion]
    /// Senders whose mail skips the bulk rules: addresses, or "@domain".
    public var vips: [String]
    /// "Never from this sender": their mail is Noise, without asking the model.
    public var noiseSenders: [String]
    /// The Google Sheets Dara registered as Sources; no other sheet is read.
    public var sheets: [RegisteredSheet]

    public init(
        guardrailRules: [GuardrailRule] = [], neutrals: [NeutralKey] = [], exclusions: [Exclusion] = [], vips: [String] = [],
        noiseSenders: [String] = [], sheets: [RegisteredSheet] = []
    ) {
        self.sheets = sheets
        self.noiseSenders = noiseSenders
        self.guardrailRules = guardrailRules
        self.neutrals = neutrals
        self.exclusions = exclusions
        self.vips = vips
    }

    /// Settings logged before VIPs existed still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            guardrailRules: try c.decode([GuardrailRule].self, forKey: .guardrailRules),
            neutrals: try c.decode([NeutralKey].self, forKey: .neutrals),
            exclusions: try c.decode([Exclusion].self, forKey: .exclusions),
            vips: try c.decodeIfPresent([String].self, forKey: .vips) ?? [],
            noiseSenders: try c.decodeIfPresent([String].self, forKey: .noiseSenders) ?? [],
            sheets: try c.decodeIfPresent([RegisteredSheet].self, forKey: .sheets) ?? [])
    }
}

/// The Tasks, Projects and Suggestions an Operation writes, each in its new state, and Dara's
/// settings if it changes them. Triage also writes Suggestions and the mail cursor this way, unlogged.
public struct Change: Equatable, Sendable, Codable {
    public var tasks: [Task]
    public var projects: [Project]
    /// The whole new settings, or nil if the Operation leaves them alone.
    public var settings: Settings?
    public var suggestions: [Suggestion]
    /// Where Triage has read the mailbox up to, or nil to leave it alone.
    public var mailCursor: String?
    /// Digest lines, new or cleared.
    public var digest: [DigestLine]
    /// Everyone Dara emailed in the last 90 days, whole, or nil to leave it alone.
    public var recipients: [String: Date]?
    /// Threads whose Digest lines are past their day: removed from the store.
    public var droppedDigest: [String]

    public init(
        tasks: [Task] = [], projects: [Project] = [], settings: Settings? = nil, suggestions: [Suggestion] = [],
        mailCursor: String? = nil, digest: [DigestLine] = [], recipients: [String: Date]? = nil,
        droppedDigest: [String] = []
    ) {
        self.droppedDigest = droppedDigest
        self.tasks = tasks
        self.projects = projects
        self.settings = settings
        self.suggestions = suggestions
        self.mailCursor = mailCursor
        self.digest = digest
        self.recipients = recipients
    }

    /// Log entries stored before Suggestions existed still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            tasks: try c.decode([Task].self, forKey: .tasks),
            projects: try c.decode([Project].self, forKey: .projects),
            settings: try c.decodeIfPresent(Settings.self, forKey: .settings),
            suggestions: try c.decodeIfPresent([Suggestion].self, forKey: .suggestions) ?? [],
            mailCursor: try c.decodeIfPresent(String.self, forKey: .mailCursor),
            digest: try c.decodeIfPresent([DigestLine].self, forKey: .digest) ?? [],
            recipients: try c.decodeIfPresent([String: Date].self, forKey: .recipients),
            droppedDigest: try c.decodeIfPresent([String].self, forKey: .droppedDigest) ?? [])
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
    /// Appends a line to the API audit log.
    func audit(_ call: APICall) throws
    /// What the API calls in the audit log since `since` cost.
    func apiSpend(since: Date) throws -> Double
}

/// Everything the store holds.
public struct StoreSnapshot: Equatable, Sendable {
    public var projects: [Project]
    public var tasks: [Task]
    public var log: [LogEntry]
    public var settings: Settings
    public var history: [NowBlock]
    public var audit: [APICall]
    /// Every Suggestion, answered or not, so a thread is never suggested twice.
    public var suggestions: [Suggestion]
    public var mailCursor: String?
    /// Digest lines, cleared ones included until their day is up.
    public var digest: [DigestLine]
    public var recipients: [String: Date]

    public init(
        projects: [Project] = [], tasks: [Task] = [], log: [LogEntry] = [], settings: Settings = Settings(),
        history: [NowBlock] = [], audit: [APICall] = [], suggestions: [Suggestion] = [], mailCursor: String? = nil,
        digest: [DigestLine] = [], recipients: [String: Date] = [:]
    ) {
        self.digest = digest
        self.recipients = recipients
        self.suggestions = suggestions
        self.mailCursor = mailCursor
        self.history = history
        self.audit = audit
        self.settings = settings
        self.projects = projects
        self.tasks = tasks
        self.log = log
    }

    /// Writes each changed Task, Project and Suggestion over its old version, and any new settings
    /// and cursor.
    public mutating func apply(_ change: Change) {
        if let settings = change.settings { self.settings = settings }
        if let cursor = change.mailCursor { mailCursor = cursor }
        if let recipients = change.recipients { self.recipients = recipients }
        for line in change.digest {
            digest.removeAll { $0.threadID == line.threadID }
            digest.append(line)
        }
        digest.removeAll { change.droppedDigest.contains($0.threadID) }
        for suggestion in change.suggestions {
            if let index = suggestions.firstIndex(where: { $0.threadID == suggestion.threadID }) {
                suggestions[index] = suggestion
            } else {
                suggestions.append(suggestion)
            }
        }
        for task in change.tasks {
            if let index = tasks.firstIndex(where: { $0.id == task.id }) { tasks[index] = task } else { tasks.append(task) }
        }
        for project in change.projects {
            if let index = projects.firstIndex(where: { $0.id == project.id }) { projects[index] = project } else { projects.append(project) }
        }
    }
}
