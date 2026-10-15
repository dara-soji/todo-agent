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

    /// A Project and why Now is on it.
    public struct Match: Equatable, Sendable {
        public enum Basis: Equatable, Sendable {
            /// A Matcher fits the window.
            case matcher(Matcher)
            /// A calendar-keyword Matcher fits a meeting under way.
            case meeting(Matcher, CalendarEvent)
            /// Kept on the last Project while Dara is in a Neutral app or site.
            case neutralHold(NeutralKey)
            /// Dara said this window belongs to the Project.
            case correction
        }

        public let project: Project.ID
        public let basis: Basis

        /// The Matcher behind it, if one is.
        public var evidence: Matcher? {
            switch basis {
            case let .matcher(matcher), let .meeting(matcher, _): matcher
            case .neutralHold, .correction: nil
            }
        }

        /// The meeting a calendar-keyword Matcher fitted.
        public var event: CalendarEvent? {
            if case let .meeting(_, event) = basis { return event }
            return nil
        }
    }

    /// Before any Signal has arrived.
    public static let unknown = Now(visit: nil, match: nil, isAway: false, neutral: nil)

    /// Nil before the first Signal.
    public let visit: Visit?
    /// Nil means No Project, or Away.
    public let match: Match?
    /// Dara has been idle long enough to be Away, outside a matching meeting. Away time is not work:
    /// it has no Project.
    public let isAway: Bool
    /// The Neutral app or site the window is in, if it is in one.
    public let neutral: NeutralKey?

    public var window: ActiveWindow? { visit?.window }
    public var since: Date? { visit?.since }
    public var project: Project.ID? { match?.project }
    public var evidence: Matcher? { match?.evidence }
}
