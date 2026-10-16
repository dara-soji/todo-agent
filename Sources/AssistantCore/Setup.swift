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

    /// Retention: the Operation log and Now history keep 90 days, the API audit 30, and the Deleted
    /// list 30 (Tasks older are purged for good). Runs once a day by itself.
    public func pruneLogs() {
        let cutoffs = Retention.Cutoffs(
            log: clock.now - Retention.operationLog, audit: clock.now - Retention.audit,
            history: clock.now - Retention.nowHistory)
        let purged = deletedTasks.filter { clock.now.timeIntervalSince($0.deletedAt!) >= Retention.deletedTasks }.map(\.id)
        do {
            try store.prune(cutoffs, purging: purged)
        } catch {
            return NSLog("TodoAgent: pruning logs failed: \(type(of: error))")
        }
        prunedOn = calendar.startOfDay(for: clock.now)
        forget(tasks: purged, logBefore: cutoffs.log)
    }
}
