import Foundation

/// A unit of work in the assistant's own list, with the Source it came from.
public struct Task: Identifiable, Equatable, Sendable, Codable {
    public struct ID: Hashable, Sendable, Codable {
        public let rawValue: UUID
        public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
    }

    /// Where a Task originated.
    public enum Source: String, Sendable, Codable {
        case byHand, code, email, sheet, notes
    }

    public enum Status: Equatable, Sendable, Codable {
        case open
        /// The Committed Task. At most one Task is committed.
        case committed
        case done
        case dropped
        /// Out of play until `until`, or, with no wake time, until Dara brings it back
        /// ("waiting on someone", with the note saying who).
        case snoozed(until: Date?, note: String?)
    }

    public enum Effort: String, Sendable, Codable, CaseIterable {
        case small, medium, large
    }

    public enum Kind: String, Sendable, Codable, CaseIterable {
        case deep, shallow
    }

    public let id: ID
    public var title: String
    public let source: Source
    /// Where to find the Task in its Source (a path, thread, row or note).
    public var backLink: String?
    public var status: Status
    public let created: Date
    public var deadline: Date?
    public var project: Project.ID?
    /// Guessed by the assistant and corrected by Dara; nil until guessed.
    public var effort: Effort?
    public var kind: Kind?
    /// Set when an interruption took over as the Committed Task, so Next can offer to come back to it.
    public var resumeAfterInterruption: Bool
    /// When it was moved to the Deleted list; nil for a Task in play.
    public var deletedAt: Date?
    /// Skipped as Next: it sits out until then.
    public var skippedUntil: Date?
    /// Skips since Dara last decided about it. The third asks what to do.
    public var skipCount: Int
    /// Dara (or Claude Code for Dara) set the title: a Source update never overwrites it.
    public var titleSetByDara: Bool
    /// A new message arrived on its email thread since Dara last replied.
    public var hasNewReply: Bool

    init(
        id: ID, title: String, source: Source, backLink: String?, status: Status, created: Date, deadline: Date?,
        project: Project.ID?, effort: Effort?, kind: Kind?, resumeAfterInterruption: Bool = false,
        deletedAt: Date? = nil, skippedUntil: Date? = nil, skipCount: Int = 0, titleSetByDara: Bool = false,
        hasNewReply: Bool = false
    ) {
        self.titleSetByDara = titleSetByDara
        self.hasNewReply = hasNewReply
        self.id = id
        self.title = title
        self.source = source
        self.backLink = backLink
        self.status = status
        self.created = created
        self.deadline = deadline
        self.project = project
        self.effort = effort
        self.kind = kind
        self.resumeAfterInterruption = resumeAfterInterruption
        self.deletedAt = deletedAt
        self.skippedUntil = skippedUntil
        self.skipCount = skipCount
    }

    /// Tasks stored before a field existed still load, with that field's default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(ID.self, forKey: .id),
            title: try c.decode(String.self, forKey: .title),
            source: try c.decode(Source.self, forKey: .source),
            backLink: try c.decodeIfPresent(String.self, forKey: .backLink),
            status: try c.decode(Status.self, forKey: .status),
            created: try c.decode(Date.self, forKey: .created),
            deadline: try c.decodeIfPresent(Date.self, forKey: .deadline),
            project: try c.decodeIfPresent(Project.ID.self, forKey: .project),
            effort: try c.decodeIfPresent(Effort.self, forKey: .effort),
            kind: try c.decodeIfPresent(Kind.self, forKey: .kind),
            resumeAfterInterruption: try c.decodeIfPresent(Bool.self, forKey: .resumeAfterInterruption) ?? false,
            deletedAt: try c.decodeIfPresent(Date.self, forKey: .deletedAt),
            skippedUntil: try c.decodeIfPresent(Date.self, forKey: .skippedUntil),
            skipCount: try c.decodeIfPresent(Int.self, forKey: .skipCount) ?? 0,
            titleSetByDara: try c.decodeIfPresent(Bool.self, forKey: .titleSetByDara) ?? false,
            hasNewReply: try c.decodeIfPresent(Bool.self, forKey: .hasNewReply) ?? false)
    }
}

/// What Dara or a Source provides for a new Task.
public struct TaskDraft: Sendable {
    public var title: String
    public var source: Task.Source
    public var backLink: String?
    public var deadline: Date?
    public var project: Project.ID?
    public var effort: Task.Effort?
    public var kind: Task.Kind?

    public init(
        title: String, source: Task.Source = .byHand, backLink: String? = nil, deadline: Date? = nil,
        project: Project.ID? = nil, effort: Task.Effort? = nil, kind: Task.Kind? = nil
    ) {
        self.title = title
        self.source = source
        self.backLink = backLink
        self.deadline = deadline
        self.project = project
        self.effort = effort
        self.kind = kind
    }
}

/// An edit to a Task's fields. A nil field is left alone; `.some(nil)` clears an optional one.
public struct TaskChanges: Sendable {
    func apply(to task: inout Task) {
        if let title {
            task.title = title
            task.titleSetByDara = true
        }
        if let deadline { task.deadline = deadline }
        if let project { task.project = project }
        if let effort { task.effort = effort }
        if let kind { task.kind = kind }
    }

    /// The fields it sets or clears, in order.
    var fieldNames: [String] {
        [("title", title != nil), ("deadline", deadline != nil), ("project", project != nil),
         ("effort", effort != nil), ("kind", kind != nil)].filter(\.1).map(\.0)
    }

    public var title: String?
    public var deadline: Date??
    public var project: Project.ID??
    public var effort: Task.Effort??
    public var kind: Task.Kind??

    public init(
        title: String? = nil, deadline: Date?? = nil, project: Project.ID?? = nil,
        effort: Task.Effort?? = nil, kind: Task.Kind?? = nil
    ) {
        self.title = title
        self.deadline = deadline
        self.project = project
        self.effort = effort
        self.kind = kind
    }
}
