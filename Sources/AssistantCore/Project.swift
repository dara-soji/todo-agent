import Foundation

/// An ongoing body of work that Signals are matched to through its Matchers. Projects are flat.
public struct Project: Identifiable, Equatable, Sendable, Codable {
    public struct ID: Hashable, Sendable, Codable {
        public let rawValue: UUID
        public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
    }

    public enum Status: String, Equatable, Sendable, Codable {
        case active, archived
    }

    public let id: ID
    public var name: String
    /// What the menu bar shows, in caps. Defaults to the name.
    public var shortName: String
    public var status: Status
    public var matchers: [Matcher]

    public init(id: ID = ID(), name: String, shortName: String? = nil, status: Status = .active, matchers: [Matcher]) {
        self.id = id
        self.name = name
        self.shortName = shortName ?? name
        self.status = status
        self.matchers = matchers
    }
}
