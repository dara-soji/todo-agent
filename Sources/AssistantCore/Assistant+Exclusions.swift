import Foundation

extension Assistant {
    /// The window as the core may keep it: `ActiveWindow.excluded` when it is in an Excluded app or
    /// site, a system password prompt, or a private-browsing window that says so.
    func excluding(_ window: ActiveWindow) -> ActiveWindow {
        if window.isExcluded { return window }
        let excluded = excludesApp(window.app.bundleID)
            || window.title.map(Exclusion.isPrivateWindowTitle) == true
            || exclusions.contains { exclusion in
                if case let .site(site) = exclusion { return fitting.fits(site: site, window) }
                return false
            }
        return excluded ? .excluded : window
    }

    /// Whether the helper should read nothing at all from this app (not even its window title).
    public func excludesApp(_ bundleID: String) -> Bool {
        Exclusion.alwaysExcludedApps.contains(bundleID) || exclusions.contains(.app(bundleID))
    }

    /// Whether any site is Excluded. A browser window whose page can't be read might be one, so
    /// the helper then keeps none of its title either.
    public var excludesAnySite: Bool {
        exclusions.contains { if case .site = $0 { true } else { false } }
    }

    /// Whether mail from this sender is Excluded: "Name <address>" or a bare address, matched
    /// exactly or by domain ("@bank.example" also covers "@mail.bank.example").
    public func isExcluded(sender: String) -> Bool {
        let address = Self.address(in: sender)
        return exclusions.contains { exclusion in
            guard case let .sender(excluded) = exclusion else { return false }
            return Self.address(address, matches: excluded)
        }
    }

    /// An address against "you@x.example", or "@x.example" for x.example and its subdomains.
    static func address(_ address: String, matches pattern: String) -> Bool {
        guard pattern.hasPrefix("@") else { return address == pattern }
        return address.hasSuffix(pattern) || address.hasSuffix("." + pattern.dropFirst())
    }

    /// A notes folder by name, ignoring case as Notes does; a folder inside an Excluded one is Excluded too.
    public func isExcluded(notesFolder: String, within parents: [String] = []) -> Bool {
        let names = Set((parents + [notesFolder]).map { $0.lowercased() })
        return exclusions.contains { exclusion in
            if case let .notesFolder(folder) = exclusion { return names.contains(folder.lowercased()) }
            return false
        }
    }

    /// "Exclude <app/site>" for the window in front: the site in a browser, else the app.
    public var exclusionToOffer: Exclusion? {
        guard let window = now.window, !window.isExcluded else { return nil }
        return fitting.proposedSite(for: window).map(Exclusion.site) ?? .app(window.app.bundleID)
    }

    /// Adds to the exclude list. Auto: it only ever keeps more out of reach. The log says that the
    /// list changed, never what is on it.
    @discardableResult
    public func exclude(_ exclusion: Exclusion, by startedBy: StartedBy = .dara) throws -> Outcome {
        let exclusion = try exclusion.normalised()
        guard !exclusions.contains(exclusion) else { throw Failure.alreadyExcluded(exclusion) }
        var change = changingSettings { $0.exclusions.append(exclusion) }
        // Lines already in the Digest from that sender go too, and Suggestions from that notes folder.
        change.digest = clearingExcluded(by: [exclusion])
        change.suggestions = suggestionsInExcluded(exclusion)
        return try perform(.addExclusion, "Added an exclusion", by: startedBy, writing: change)
    }

    /// Takes something off the exclude list. Ask: Dara confirms in the menu bar.
    @discardableResult
    public func removeExclusion(_ exclusion: Exclusion, by startedBy: StartedBy = .dara) throws -> Outcome {
        let exclusion = (try? exclusion.normalised()) ?? exclusion
        guard exclusions.contains(exclusion) else { throw Failure.notExcluded(exclusion) }
        return try perform(.removeExclusion, "Removed an exclusion", by: startedBy,
                           writing: changingSettings { $0.exclusions.removeAll { $0 == exclusion } })
    }

    /// The bare, lowercased address in "Name <address>" or "address".
    static func address(in sender: String) -> String {
        let lowered = sender.lowercased()
        if let open = lowered.lastIndex(of: "<"), let close = lowered.lastIndex(of: ">"), open < close {
            return String(lowered[lowered.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
        }
        return lowered.trimmingCharacters(in: .whitespaces)
    }
}
