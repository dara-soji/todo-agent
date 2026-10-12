import Foundation

/// Operations waiting for Dara to confirm in the menu bar. Several from one conversation in quick
/// succession wait together as one confirm. An unanswered Ask expires and does not run.
public struct Ask: Identifiable, Equatable, Sendable {
    public struct ID: Hashable, Sendable {
        public let rawValue: UUID
        public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
    }

    /// One Operation inside an Ask, with the change it will write once confirmed.
    public struct Operation: Equatable, Sendable {
        public let kind: OperationKind
        public let summary: String
        /// What it touches, one line each, e.g. the titles of Tasks in a bulk edit.
        public let preview: [String]
        let before: Change
        let after: Change
        let undoes: LogEntry.ID?
    }

    public let id: ID
    public let startedBy: StartedBy
    /// The MCP session (conversation) that started it; nil for Dara's own.
    public let session: String?
    public let created: Date
    public let expires: Date
    public internal(set) var operations: [Operation]

    public var summary: String {
        operations.map(\.summary).joined(separator: "; ")
    }

    public var preview: [String] {
        operations.flatMap(\.preview)
    }

    /// The Task and Project ids its Operations write.
    var touches: Set<UUID> {
        Set(operations.flatMap { $0.after.tasks.map(\.id.rawValue) + $0.after.projects.map(\.id.rawValue) })
    }
}

/// What came of asking for an Operation.
public enum Outcome: Equatable, Sendable {
    /// It ran and was logged.
    case ran(LogEntry.ID)
    /// It waits for Dara to confirm in the menu bar.
    case pending(Ask.ID)
}
