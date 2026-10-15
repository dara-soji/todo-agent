import Foundation

extension Assistant {
    /// The window as the core may keep it: `ActiveWindow.excluded` when it is in an Excluded app or
    /// site, a system password prompt, or a private-browsing window that says so.
    func excluding(_ window: ActiveWindow) -> ActiveWindow {
        if window.isExcluded { return window }
        let excluded = Exclusion.alwaysExcludedApps.contains(window.app.bundleID)
            || window.title.map(Exclusion.isPrivateWindowTitle) == true
            || exclusions.contains { exclusion in
                switch exclusion {
                case let .app(bundleID): window.app.bundleID == bundleID
                case let .site(site): fitting.fits(site: site, window)
                case .sender, .notesFolder: false
                }
            }
        return excluded ? .excluded : window
    }

    /// Whether the helper should read nothing at all from this app (not even its window title).
    public func excludesApp(_ bundleID: String) -> Bool {
        Exclusion.alwaysExcludedApps.contains(bundleID) || exclusions.contains(.app(bundleID))
    }

    public func isExcluded(sender: String) -> Bool {
        let sender = sender.lowercased()
        return exclusions.contains { exclusion in
            guard case let .sender(excluded) = exclusion else { return false }
            return excluded.hasPrefix("@") ? sender.hasSuffix(excluded) : sender == excluded
        }
    }

    public func isExcluded(notesFolder: String) -> Bool {
        exclusions.contains(.notesFolder(notesFolder))
    }

    /// "Exclude <app/site>" for the window in front: the site in a browser, else the app.
    public var exclusionToOffer: Exclusion? {
        guard let window = now.window, !window.isExcluded else { return nil }
        if case let .site(site) = fitting.proposedNeutral(for: window) { return .site(site) }
        return .app(window.app.bundleID)
    }

    /// Adds to the exclude list. Auto: it only ever keeps more private.
    @discardableResult
    public func exclude(_ exclusion: Exclusion, by startedBy: StartedBy = .dara) throws -> Outcome {
        let exclusion = try exclusion.normalised()
        guard !exclusions.contains(exclusion) else { throw Failure.alreadyExcluded(exclusion) }
        return try perform(.addExclusion, "Excluded \(exclusion.label)", by: startedBy,
                           writing: Change(exclusions: exclusions + [exclusion]))
    }

    /// Takes something off the exclude list. Ask: Dara confirms in the menu bar.
    @discardableResult
    public func removeExclusion(_ exclusion: Exclusion, by startedBy: StartedBy = .dara) throws -> Outcome {
        guard exclusions.contains(exclusion) else { throw Failure.notExcluded(exclusion) }
        return try perform(.removeExclusion, "Stopped excluding \(exclusion.label)", by: startedBy,
                           writing: Change(exclusions: exclusions.filter { $0 != exclusion }))
    }
}
