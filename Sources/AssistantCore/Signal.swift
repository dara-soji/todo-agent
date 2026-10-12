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
    case focus(app: App, windowTitle: String?)
}
