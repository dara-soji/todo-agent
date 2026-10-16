import AppKit

/// Reads the front tab's URL from a browser over Apple Events, off the main thread and with a
/// short timeout so a slow browser or a first permission prompt never freezes the menu bar.
/// Each browser asks Dara once for Automation permission; if it is denied the URL is unknown.
/// Incognito windows in Chromium browsers are never read. Safari can't say whether a window is
/// private, so its private windows are left to Exclusions (ticket 10).
final class BrowserURLReader: @unchecked Sendable {
    /// What the scripts return for a private-browsing window, which is never read.
    private static let privateWindowMark = "PRIVATE"

    /// Browsers whose page the assistant may not be able to read (Firefox has no script).
    static let browsers: Set<String> = Set(scripts.keys).union(["org.mozilla.firefox"])

    private static func chromium(_ id: String) -> String {
        """
        with timeout of 2 seconds
            tell application id "\(id)"
                if (count of windows) is 0 then return ""
                if mode of front window is "incognito" then return "\(privateWindowMark)"
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
    private let queue = AppleScriptQueue.shared

    func reads(_ bundleID: String) -> Bool {
        Self.scripts[bundleID] != nil
    }

    /// What the front tab is: a page, a private-browsing window (never read), or unknown.
    enum FrontTab: Sendable {
        case page(URL)
        case privateWindow
        case unknown
    }

    /// Calls `completion` on the main thread with what the front tab is.
    func frontTab(in bundleID: String, completion: @escaping @MainActor @Sendable (FrontTab) -> Void) {
        queue.async { [self] in
            let tab = read(bundleID)
            DispatchQueue.main.async { completion(tab) }
        }
    }

    private func read(_ bundleID: String) -> FrontTab {
        guard let source = Self.scripts[bundleID] else { return .unknown }
        if let denied = deniedAt[bundleID], Date().timeIntervalSince(denied) < Self.retryDeniedAfter { return .unknown }
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let code = error?[NSAppleScript.errorNumber] as? Int, code == Self.notPermitted {
            deniedAt[bundleID] = Date()
        }
        guard let text = result?.stringValue, !text.isEmpty else { return .unknown }
        if text == Self.privateWindowMark { return .privateWindow }
        return URL(string: text).map(FrontTab.page) ?? .unknown
    }
}
