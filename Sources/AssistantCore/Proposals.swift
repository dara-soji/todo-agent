import Foundation

/// A Project the assistant has evidence for: a name, the Matcher that would place the work, and on
/// how many days that work was seen. Never declared until Dara says so.
public struct ProjectProposal: Equatable, Sendable {
    public let name: String
    public let matcher: Matcher
    public let days: Int

    public init(name: String, matcher: Matcher, days: Int) {
        self.name = name
        self.matcher = matcher
        self.days = days
    }
}

/// One unmatched window's Matcher and the days it was seen on. Kept 30 days.
public struct Sighting: Equatable, Sendable, Codable {
    public let matcher: Matcher
    public let days: [Date]

    public init(matcher: Matcher, days: [Date]) {
        self.matcher = matcher
        self.days = days
    }
}

extension Assistant {
    /// Unmatched this long in one stretch, and a day counts as a sighting.
    static let sightingAfter: TimeInterval = 5 * 60
    /// Seen on this many separate days, and a Project is proposed.
    static let proposeAfterDays = 2
    /// Sightings older than this are forgotten.
    static let sightingsKeptFor: TimeInterval = 30 * 24 * 60 * 60
    /// No matched Signal for this long, and archiving is suggested.
    static let staleAfter: TimeInterval = 30 * 24 * 60 * 60

    // MARK: Setup

    /// Projects for setup to offer: a repo under Dara's code folder, or a registered sheet, that no
    /// Project matches yet. Dara unticks what they don't want, once.
    public func setupProposals(repoPaths: [String]) -> [ProjectProposal] {
        let taken = Set(projects.flatMap(\.matchers) + dismissedProposals)
        let repos = repoPaths.compactMap { path -> ProjectProposal? in
            guard let matcher = try? fitting.normalised(.repoPath(path)), !taken.contains(matcher) else { return nil }
            return ProjectProposal(name: (path as NSString).lastPathComponent, matcher: matcher, days: 0)
        }
        let sheets = registeredSheets.compactMap { sheet -> ProjectProposal? in
            let matcher = Matcher.sheetID(sheet.id)
            return taken.contains(matcher) ? nil : ProjectProposal(name: sheet.name, matcher: matcher, days: 0)
        }
        return repos + sheets
    }

    /// Dara's yes to proposals: each becomes a Project, as Dara asked.
    public func addProposedProjects(_ proposals: [ProjectProposal]) throws {
        for proposal in proposals {
            try declareProject(name: proposal.name, matchers: [proposal.matcher], by: .dara)
        }
    }

    /// Setup's checklist, answered once: the ticked become Projects; the unticked are never proposed again.
    public func answerSetupProposals(adding chosen: [ProjectProposal], from offered: [ProjectProposal]) throws {
        let unticked = offered.filter { !chosen.contains($0) }.map(\.matcher).filter { !dismissedProposals.contains($0) }
        if !unticked.isEmpty { try writeUnlogged(Change(dismissedProposals: dismissedProposals + unticked)) }
        try addProposedProjects(chosen)
    }

    // MARK: Seen on two days

    /// The proposal waiting, if any: the work seen on the most days.
    var projectDecisions: [Decision] {
        let taken = Set(projects.flatMap(\.matchers))
        let proposal = sightings
            .mapValues { $0.filter { clock.now.timeIntervalSince($0) < Self.sightingsKeptFor } }
            .filter { $0.value.count >= Self.proposeAfterDays && !taken.contains($0.key) && !dismissedProposals.contains($0.key) }
            .max { a, b in a.value.count != b.value.count ? a.value.count < b.value.count : a.key.pattern > b.key.pattern }
            .map { ProjectProposal(name: proposalName($0.key), matcher: $0.key, days: $0.value.count) }
        let stale = activeProjects.filter { project in
            clock.now.timeIntervalSince(projectsLastSeen[project.id] ?? clock.now) >= Self.staleAfter
        }.first
        return (proposal.map { [.newProject($0)] } ?? []) + (stale.map { [.archiveStale($0.id)] } ?? [])
    }

    /// "Dismiss": never proposed again.
    public func dismissProposal(_ proposal: ProjectProposal) {
        guard !dismissedProposals.contains(proposal.matcher) else { return }
        try? writeUnlogged(Change(dismissedProposals: dismissedProposals + [proposal.matcher]))
    }

    /// "Keep": not suggested for archiving for another 30 days.
    public func keepProject(_ id: Project.ID) {
        var lastSeen = projectsLastSeen
        lastSeen[id] = clock.now
        try? writeUnlogged(Change(projectsLastSeen: lastSeen))
    }

    /// Times an unmatched window; a stretch long enough counts its day once.
    func trackSighting(placed: Bool) {
        // Neutral and Excluded windows count as placed. Excluded is checked again regardless: nothing
        // about an Excluded window may be kept.
        guard !placed, !now.isAway, let window = now.window, !window.isExcluded,
              let matcher = fitting.proposedMatcher(for: window)
        else { return sightingWatch = nil }
        // Away (asleep, say) ends the stretch above, so it is one unbroken stretch of work.
        guard let watch = sightingWatch, watch.matcher == matcher else { return sightingWatch = (matcher, clock.now) }
        guard clock.now.timeIntervalSince(watch.since) >= Self.sightingAfter else { return }
        let today = calendar.startOfDay(for: clock.now)
        guard !(sightings[matcher] ?? []).contains(today), tryOnce("sighting:\(matcher.pattern)", today) else { return }
        var updated = sightings
        updated[matcher, default: []].append(today)
        try? writeUnlogged(Change(sightings: keptSightings(updated)))
    }

    /// A confident match counts as the Project being seen, written at most once a day.
    func noteSeen(_ project: Project.ID?) {
        guard let project else { return }
        let today = calendar.startOfDay(for: clock.now)
        guard (projectsLastSeen[project] ?? .distantPast) < today, tryOnce("seen:\(project.rawValue)", today) else { return }
        var lastSeen = projectsLastSeen
        lastSeen[project] = clock.now
        try? writeUnlogged(Change(projectsLastSeen: lastSeen))
    }

    /// Whether work a Matcher names is now Excluded or Neutral: its sighting is never shown or kept.
    func isOffLimits(_ matcher: Matcher) -> Bool {
        let window: ActiveWindow
        switch matcher {
        case let .urlPrefix(prefix):
            guard let url = URL(string: "https://" + prefix) else { return false }
            window = ActiveWindow(app: App(bundleID: "", name: ""), title: nil, url: url)
        case let .sheetID(id):
            window = ActiveWindow(app: App(bundleID: "", name: ""), title: nil,
                                  url: URL(string: "https://docs.google.com/spreadsheets/d/\(id)/edit"))
        case let .repoPath(path):
            window = ActiveWindow(app: App(bundleID: "", name: ""), title: path)
        case .calendarKeyword:
            return false
        }
        return excluding(window).isExcluded || isNeutral(window)
    }

    /// Sightings still worth keeping: within 30 days and not now Excluded or Neutral.
    func keptSightings(_ sightings: [Matcher: [Date]]) -> [Sighting] {
        sightings.compactMap { matcher, days in
            let recent = days.filter { clock.now.timeIntervalSince($0) < Self.sightingsKeptFor }
            return recent.isEmpty || isOffLimits(matcher) ? nil : Sighting(matcher: matcher, days: recent.sorted())
        }.sorted { $0.matcher.pattern < $1.matcher.pattern }
    }

    /// True the first time `key` is tried on `day`: a write that failed waits for tomorrow.
    private func tryOnce(_ key: String, _ day: Date) -> Bool {
        guard bookkeepingTried[key] != day else { return false }
        if bookkeepingTried.count > 1_000 { bookkeepingTried.removeAll() }
        bookkeepingTried[key] = day
        return true
    }

    /// A short name: the repo's folder, a page path's last part, or the sheet's name.
    private func proposalName(_ matcher: Matcher) -> String {
        switch matcher {
        case let .repoPath(path): (path as NSString).lastPathComponent
        case let .urlPrefix(prefix): prefix.split(separator: "/").last.map(String.init) ?? prefix
        case let .sheetID(id): registeredSheets.first { $0.id == id }?.name ?? "Sheet \(id.prefix(6))"
        case let .calendarKeyword(keyword): keyword
        }
    }
}
