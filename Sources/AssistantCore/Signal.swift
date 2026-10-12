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
    case activeWindow(app: App, windowTitle: String?, url: URL? = nil)
}

/// Port through which Signals reach the assistant. The helper's OS sensors conform to it.
@MainActor
public protocol SignalSource {
    /// Begins reporting Signals to `deliver`, on the main thread.
    func start(delivering deliver: @escaping (Signal) -> Void)
}
