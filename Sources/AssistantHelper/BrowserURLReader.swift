import AppKit

/// Reads the front tab's URL from a browser over Apple Events. Each browser asks Dara once for
/// Automation permission; if it is denied the URL is simply unknown.
@MainActor
final class BrowserURLReader {
    private static let scripts: [String: String] = [
        "com.apple.Safari": #"tell application id "com.apple.Safari" to return URL of front document"#,
        "com.google.Chrome": #"tell application id "com.google.Chrome" to return URL of active tab of front window"#,
        "com.brave.Browser": #"tell application id "com.brave.Browser" to return URL of active tab of front window"#,
        "com.microsoft.edgemac": #"tell application id "com.microsoft.edgemac" to return URL of active tab of front window"#,
        "company.thebrowser.Browser": #"tell application id "company.thebrowser.Browser" to return URL of active tab of front window"#,
    ]
    /// errAEEventNotPermitted: Dara declined Automation for that browser.
    private static let notPermitted = -1743

    private var denied: Set<String> = []

    func url(ofFrontTabIn bundleID: String) -> URL? {
        guard let source = Self.scripts[bundleID], !denied.contains(bundleID) else { return nil }
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let code = error?[NSAppleScript.errorNumber] as? Int, code == Self.notPermitted {
            denied.insert(bundleID)
        }
        return result?.stringValue.flatMap(URL.init(string:))
    }
}
