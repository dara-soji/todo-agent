import Foundation

/// An app setup offers to Exclude, unticked: Dara decides.
public struct ExclusionOffer: Equatable, Sendable {
    public enum Why: String, Sendable {
        case passwordManager, banking
    }

    public let app: App
    public let why: Why
    public var ticked: Bool

    public init(app: App, why: Why, ticked: Bool) {
        self.app = app
        self.why = why
        self.ticked = ticked
    }
}

extension Assistant {
    /// Known password managers, by bundle id.
    static let passwordManagers: Set<String> = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.agilebits.onepassword-osx",
        "com.bitwarden.desktop", "com.dashlane.dashlanephonefinal", "com.dashlane.Dashlane", "com.lastpass.LastPass",
        "org.keepassxc.keepassxc", "com.apple.Passwords", "com.apple.keychainaccess", "com.nordpass.macos.NordPass",
        "com.enpass.Enpass-Desktop", "me.proton.pass.electron",
    ]

    /// Words in an app's name that suggest banking or payments.
    static let bankingWords = [
        "bank", "banking", "monzo", "revolut", "starling", "paypal", "wise", "barclays", "lloyds", "natwest",
        "halifax", "santander", "hsbc", "chase", "nationwide", "venmo", "cash app",
    ]

    /// First-run setup hasn't been finished.
    public var needsSetup: Bool { !setupDone }

    public func finishSetup() {
        try? writeUnlogged(Change(setupDone: true))
    }

    /// Installed password managers and banking apps not already Excluded, offered unticked.
    public func exclusionOffers(installed: [App]) -> [ExclusionOffer] {
        installed.compactMap { app in
            guard !excludesApp(app.bundleID) else { return nil }
            if Self.passwordManagers.contains(app.bundleID) { return ExclusionOffer(app: app, why: .passwordManager, ticked: false) }
            let name = app.name.lowercased()
            let words = Set(name.split(whereSeparator: { !$0.isLetter }).map(String.init))
            let banking = Self.bankingWords.contains { $0.contains(" ") ? name.contains($0) : words.contains($0) }
            return banking ? ExclusionOffer(app: app, why: .banking, ticked: false) : nil
        }
    }

    /// A log summary with any quoted title taken out: "Added “X”" becomes "Added a Task since purged".
    static func withoutTitles(_ summary: String) -> String {
        guard let open = summary.firstIndex(of: "“") else { return summary }
        return summary[..<open].trimmingCharacters(in: .whitespaces) + " a Task since purged"
    }

    /// Retention: the Operation log and Now history keep 90 days, the API audit 30, and the Deleted
    /// list 30. A Task purged from it is gone for good: also taken out of the log entries that
    /// remain, which can then no longer be undone. Runs once a day by itself.
    public func pruneLogs() {
        let cutoffs = Retention.Cutoffs(
            log: clock.now - Retention.operationLog, audit: clock.now - Retention.audit,
            history: clock.now - Retention.nowHistory)
        // Tried once a day: a store that fails isn't retried on every Signal.
        prunedOn = calendar.startOfDay(for: clock.now)
        let purged = deletedTasks.filter { clock.now.timeIntervalSince($0.deletedAt!) >= Retention.deletedTasks }.map(\.id)
        let gone = Set(purged)
        let rewritten = operationLog.filter { entry in
            entry.at >= cutoffs.log && (entry.before.tasks + entry.after.tasks).contains { gone.contains($0.id) }
        }.map { entry in
            var before = entry.before, after = entry.after
            before.tasks.removeAll { gone.contains($0.id) }
            after.tasks.removeAll { gone.contains($0.id) }
            return LogEntry(
                id: entry.id, at: entry.at, kind: entry.kind, summary: Self.withoutTitles(entry.summary), tier: entry.tier,
                startedBy: entry.startedBy, confirmation: entry.confirmation, before: before, after: after,
                undoes: entry.undoes, purged: true)
        }
        do {
            try store.prune(cutoffs, purging: purged, rewriting: rewritten)
        } catch {
            return NSLog("TodoAgent: pruning logs failed: \(type(of: error))")
        }
        forget(tasks: purged, logBefore: cutoffs.log, rewritten: rewritten)
    }
}
