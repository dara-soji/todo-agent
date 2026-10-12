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
    /// The frontmost app and its focused window title. The title is nil when it can't be read
    /// (no Accessibility permission, or the app has no focused window).
    case activeWindow(app: App, windowTitle: String?)
}

/// Port through which Signals reach the assistant. The helper's OS sensors conform to it.
@MainActor
public protocol SignalSource {
    /// Begins reporting Signals to `deliver`, on the main thread.
    func start(delivering deliver: @escaping (Signal) -> Void)
}
