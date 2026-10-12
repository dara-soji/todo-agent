import Foundation

/// The window Dara is in, as the latest Signal reported it.
public struct ActiveWindow: Equatable, Sendable {
    public let app: App
    public let title: String?
    public let url: URL?

    public init(app: App, title: String?, url: URL? = nil) {
        self.app = app
        self.title = title
        self.url = url
    }
}

/// The single piece of work Dara is doing at this moment, resolved to a Project where a Matcher fits.
public struct Now: Equatable, Sendable {
    /// A window and when Dara arrived on it.
    public struct Visit: Equatable, Sendable {
        public let window: ActiveWindow
        public let since: Date
    }

    /// A Project and the Matcher that put Now on it.
    public struct Match: Equatable, Sendable {
        public let project: Project.ID
        public let evidence: Matcher
        /// The calendar event a calendar-keyword Matcher fitted.
        public var event: CalendarEvent?
    }

    /// Before any Signal has arrived.
    public static let unknown = Now(visit: nil, match: nil, isAway: false)

    /// Nil before the first Signal.
    public let visit: Visit?
    /// Nil means No Project, or Away.
    public let match: Match?
    /// Dara has been idle long enough to be away. Away time is not work: it has no Project.
    public let isAway: Bool

    public var window: ActiveWindow? { visit?.window }
    public var since: Date? { visit?.since }
    public var project: Project.ID? { match?.project }
    public var evidence: Matcher? { match?.evidence }
}
