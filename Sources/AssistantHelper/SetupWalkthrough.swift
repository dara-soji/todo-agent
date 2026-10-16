import AppKit
import AssistantCore
import CoreServices
import EventKit

/// The first-run walkthrough: each permission with why it's needed, the VS Code title tip, the
/// exclusions to consider, the Claude API key, Google, and Projects. Every step can be skipped;
/// what's skipped or denied just stays off, and the menu offers it again.
@MainActor
enum SetupWalkthrough {
    /// The VS Code setting that puts the folder in the window title, so repo Matchers work.
    static let vsCodeTitle = #""window.title": "${rootPath}${separator}${activeEditorShort}""#

    static let browsers = [
        ("com.apple.Safari", "Safari"), ("com.google.Chrome", "Google Chrome"), ("com.brave.Browser", "Brave"),
        ("com.microsoft.edgemac", "Microsoft Edge"), ("company.thebrowser.Browser", "Arc"),
    ]

    /// True once it was gone through; false for "Later", when nothing is read until it is.
    @discardableResult
    static func run(_ assistant: Assistant, askForAPIKey: () -> Void, connectGoogle: @escaping () -> Void) async -> Bool {
        NSApp.activate()
        if step("Welcome to TodoAgent", """
            It shows what you're working on now and what to do next, from your own Tasks, email, \
            Sheets and notes. A few permissions make that work; each one is optional. Nothing is read \
            until you've been through this.
            """, primary: "Start", secondary: "Later") == false { return false }

        if step("Read window titles (Accessibility)", """
            To tell which Project you're in from the front window's title, e.g. a repo path in VS Code. \
            Nothing is read from Excluded apps, password prompts or private windows.
            """) == true {
            _ = ActiveWindowSensor.requestAccessibility()
        }

        if step("Match meetings (Calendar)", "To know when you're in a meeting and keep Now on its Project. Events stay on your Mac.") == true {
            _ = try? await EKEventStore().requestFullAccessToEvents()
        }

        let installed = browsers.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.0) != nil }
        if step("Read the front tab's address and your notes (Automation)", """
            So web work can match your Projects (\(installed.map(\.1).joined(separator: ", "))), and so \
            open actions in Apple Notes become Suggestions. macOS asks once per app: now for the ones that \
            are open, otherwise the first time each is used. Private windows and Excluded folders are never read.
            """) == true {
            // Only apps already running: an Apple Event would open the others.
            let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
            for bundleID in installed.map(\.0) + ["com.apple.Notes"] where running.contains(bundleID) {
                await askAutomation(bundleID)
            }
        }

        if step("Guess unmatched windows (Screen Recording)", """
            Now and then, one screenshot of a window it can't place, sent to Claude to guess its Project. \
            Never stored. Skip this and those windows just show No Project.
            """) == true {
            _ = CGRequestScreenCaptureAccess()
        }

        let tip = NSAlert()
        tip.messageText = "Tip for VS Code"
        tip.informativeText = "Add this to VS Code's settings so its window title shows the folder you're in:\n\n\(vsCodeTitle)"
        tip.addButton(withTitle: "Copy and continue")
        tip.addButton(withTitle: "Continue")
        if tip.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(vsCodeTitle, forType: .string)
        }

        offerExclusions(assistant)

        if step("Claude API key", "Used for screenshot guesses, breaking ties for Next, and sorting email. Kept in your Keychain.",
                primary: "Enter key…", secondary: "Skip") == true {
            askForAPIKey()
        }

        if step("Connect Google", "Read-only access to Gmail and the Sheets you register, through your own Google OAuth client.",
                primary: "Connect…", secondary: "Skip") == true {
            connectGoogle()
        }

        SetupProposals.offer(assistant)
        assistant.finishSetup()
        return true
    }

    /// True for the primary button, false for the secondary.
    @discardableResult
    private static func step(_ title: String, _ why: String, primary: String = "Allow…", secondary: String = "Skip") -> Bool? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = why
        alert.addButton(withTitle: primary)
        alert.addButton(withTitle: secondary)
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Asks macOS for permission to automate the running app now, with the walkthrough's reason
    /// fresh. No event is sent and nothing is read.
    private static func askAutomation(_ bundleID: String) async {
        await withCheckedContinuation { continuation in
            AppleScriptQueue.shared.async {
                let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
                _ = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, true)
                continuation.resume()
            }
        }
    }

    /// Password managers and banking apps found installed, unticked: Dara chooses.
    private static func offerExclusions(_ assistant: Assistant) {
        let offers = assistant.exclusionOffers(installed: installedApps())
        guard !offers.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Exclude any of these?"
        alert.informativeText = "An Excluded app is never read: not its window title, nor a screenshot. Tick the ones to keep private."
        alert.addButton(withTitle: "Exclude ticked")
        alert.addButton(withTitle: "Skip")
        let boxes = offers.map { offer in
            NSButton(checkboxWithTitle: "\(offer.app.name)  ·  \(offer.why == .passwordManager ? "password manager" : "banking")",
                     target: nil, action: nil)
        }
        let stack = NSStackView(views: boxes)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.frame = NSRect(origin: .zero, size: NSSize(width: max(360, stack.fittingSize.width), height: stack.fittingSize.height))
        alert.accessoryView = stack
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        for (offer, box) in zip(offers, boxes) where box.state == .on {
            Attempt.run("Couldn't exclude \(offer.app.name)", then: {}) { try assistant.exclude(.app(offer.app.bundleID)) }
        }
    }

    /// Apps in /Applications, ~/Applications and /System/Applications, one folder deep (Utilities,
    /// Setapp), by bundle id and name.
    static func installedApps() -> [App] {
        let files = FileManager.default
        let roots = ["/Applications", (NSHomeDirectory() as NSString).appendingPathComponent("Applications"), "/System/Applications"]
        func apps(in folder: String, depth: Int) -> [App] {
            ((try? files.contentsOfDirectory(atPath: folder)) ?? []).flatMap { name -> [App] in
                let path = (folder as NSString).appendingPathComponent(name)
                guard name.hasSuffix(".app") else {
                    var isDir: ObjCBool = false
                    let folder = depth > 0 && files.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
                    return folder ? apps(in: path, depth: depth - 1) : []
                }
                guard let id = Bundle(path: path)?.bundleIdentifier else { return [] }
                return [App(bundleID: id, name: (name as NSString).deletingPathExtension)]
            }
        }
        var seen = Set<String>()
        return roots.flatMap { apps(in: $0, depth: 1) }.filter { seen.insert($0.bundleID).inserted }
    }
}
