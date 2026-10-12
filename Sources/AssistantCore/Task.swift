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
