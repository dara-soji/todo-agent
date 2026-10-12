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
    /// Before any Signal has arrived.
    public static let unknown = Now(window: nil, since: nil, project: nil, evidence: nil)

    /// The window Dara is in; nil before the first Signal.
    public let window: ActiveWindow?
    /// When Dara arrived on this window.
    public let since: Date?
    /// The Project the window matched; nil means No Project.
    public let project: Project.ID?
    /// The Matcher that put Now on `project`.
    public let evidence: Matcher?
}
