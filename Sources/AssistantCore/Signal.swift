import Foundation

/// An app as the OS reports it.
public struct App: Hashable, Sendable {
    public let bundleID: String
    public let name: String

    public init(bundleID: String, name: String) {
        self.bundleID = bundleID
        self.name = name
    }
}

/// One observable piece of evidence about what Dara is doing.
public enum Signal: Equatable, Sendable {
    /// The frontmost app, its focused window title, and the page URL when it is a browser.
    /// The title is nil when it can't be read (no Accessibility permission, or no focused window).
    /// `excluded` marks a window the sensor already knows is Excluded (a private-browsing window,
    /// a password being typed, an Excluded app); it arrives with nothing read.
    case activeWindow(app: App, windowTitle: String?, url: URL? = nil, excluded: Bool = false)
    /// Today's calendar events still to come or under way. Each report replaces the last.
    case calendar(events: [CalendarEvent])
    /// Seconds since Dara last used the keyboard or mouse. Reported every few seconds,
    /// so it is also how the assistant notices time passing.
    case userIdle(seconds: TimeInterval)
    /// The branch checked out in a watched repo, given by its full path.
    case git(repo: String, branch: String)
}

/// A calendar event as the calendar reports it.
public struct CalendarEvent: Equatable, Sendable {
    public let title: String
    public let start: Date
    public let end: Date

    public init(title: String, start: Date, end: Date) {
        self.title = title
        self.start = start
        self.end = end
    }

    func isUnderWay(at time: Date) -> Bool {
        start <= time && time < end
    }
}

/// Port through which Signals reach the assistant. The helper's OS sensors conform to it.
@MainActor
public protocol SignalSource {
    /// Begins reporting Signals to `deliver`, on the main thread.
    func start(delivering deliver: @escaping (Signal) -> Void)
}
