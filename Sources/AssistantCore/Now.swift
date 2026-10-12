import Foundation

/// The single piece of work Dara is doing at this moment, as far as the assistant can tell.
public enum Now: Equatable, Sendable {
    /// No Signal has arrived yet.
    case unknown
    /// The focused window, and when Dara arrived on it.
    case window(app: App, title: String?, since: Date)
}
