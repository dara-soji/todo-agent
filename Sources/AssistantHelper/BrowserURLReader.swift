import AppKit

/// Reads the front tab's URL from a browser over Apple Events, off the main thread and with a
/// short timeout so a slow browser or a first permission prompt never freezes the menu bar.
/// Each browser asks Dara once for Automation permission; if it is denied the URL is unknown.
/// Incognito windows in Chromium browsers are never read. Safari can't say whether a window is
/// private, so its private windows are left to Exclusions (ticket 10).
final class BrowserURLReader: @unchecked Sendable {
    private static func chromium(_ id: String) -> String {
        """
        with timeout of 2 seconds
            tell application id "\(id)"
                if (count of windows) is 0 then return ""
                if mode of front window is "incognito" then return ""
                return URL of active tab of front window
            end tell
        end timeout
        """
    }

    private static let scripts: [String: String] = [
        "com.apple.Safari": """
            with timeout of 2 seconds
                tell application id "com.apple.Safari" to return URL of front document
            end timeout
            """,
        "com.google.Chrome": chromium("com.google.Chrome"),
        "com.brave.Browser": chromium("com.brave.Browser"),
        "com.microsoft.edgemac": chromium("com.microsoft.edgemac"),
        "company.thebrowser.Browser": chromium("company.thebrowser.Browser"),
    ]
    /// errAEEventNotPermitted: Dara declined Automation for that browser.
    private static let notPermitted = -1743
    /// After a denial, ask again only this rarely, in case Dara grants it in System Settings.
    private static let retryDeniedAfter: TimeInterval = 10 * 60

    /// Only touched on `queue`.
    private var deniedAt: [String: Date] = [:]
    private let queue = DispatchQueue(label: "TodoAgent.BrowserURLReader")

    func reads(_ bundleID: String) -> Bool {
        Self.scripts[bundleID] != nil
    }

    /// Calls `completion` on the main thread with the front tab's URL, or nil.
    func url(ofFrontTabIn bundleID: String, completion: @escaping @MainActor @Sendable (URL?) -> Void) {
        queue.async { [self] in
            let url = read(bundleID)
            DispatchQueue.main.async { completion(url) }
        }
    }

    private func read(_ bundleID: String) -> URL? {
        guard let source = Self.scripts[bundleID] else { return nil }
        if let denied = deniedAt[bundleID], Date().timeIntervalSince(denied) < Self.retryDeniedAfter { return nil }
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let code = error?[NSAppleScript.errorNumber] as? Int, code == Self.notPermitted {
            deniedAt[bundleID] = Date()
        }
        guard let text = result?.stringValue, !text.isEmpty else { return nil }
        return URL(string: text)
    }
}
