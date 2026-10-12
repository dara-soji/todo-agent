import Foundation

/// The assistant's domain. Feed it Signals; read Now.
public final class Assistant {
    public enum Failure: Error, Equatable {
        case unknownProject(Project.ID)
    }

    private let clock: WallClock
    private let store: ProjectStore
    private let rules: MatcherRules
    private var projectsByID: [Project.ID: Project]
    /// When each Project last matched, to break ties between equally specific Matchers.
    private var lastMatched: [Project.ID: Date] = [:]

    public private(set) var now: Now = .unknown

    public init(clock: WallClock, projects: ProjectStore, homeDirectory: String) {
        self.clock = clock
        self.store = projects
        self.rules = MatcherRules(homeDirectory: homeDirectory)
        self.projectsByID = Dictionary(uniqueKeysWithValues: projects.loadProjects().map { ($0.id, $0) })
    }

    public func receive(_ signal: Signal) {
        switch signal {
        case let .activeWindow(app, title, url):
            let window = ActiveWindow(app: app, title: title, url: url)
            let since = window == now.window ? now.since : clock.now
            resolve(window, since: since)
        }
    }

    // MARK: Projects

    /// Every Project, active and archived, by name.
    public var projects: [Project] {
        projectsByID.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func project(_ id: Project.ID) -> Project? {
        projectsByID[id]
    }

    @discardableResult
    public func declareProject(name: String, shortName: String? = nil, matchers: [Matcher]) throws -> Project {
        let project = Project(name: name, shortName: shortName, matchers: try matchers.map(rules.normalised))
        commit(project)
        return project
    }

    public func renameProject(_ id: Project.ID, name: String, shortName: String? = nil) throws {
        try change(id) {
            $0.name = name
            $0.shortName = shortName ?? name
        }
    }

    public func addMatcher(_ matcher: Matcher, to id: Project.ID) throws {
        let matcher = try rules.normalised(matcher)
        try change(id) { if !$0.matchers.contains(matcher) { $0.matchers.append(matcher) } }
    }

    public func removeMatcher(_ matcher: Matcher, from id: Project.ID) throws {
        let matcher = (try? rules.normalised(matcher)) ?? matcher
        try change(id) { $0.matchers.removeAll { $0 == matcher } }
    }

    /// An archived Project matches nothing until it is restored.
    public func archiveProject(_ id: Project.ID) throws {
        try change(id) { $0.status = .archived }
    }

    public func restoreProject(_ id: Project.ID) throws {
        try change(id) { $0.status = .active }
    }

    private func change(_ id: Project.ID, _ edit: (inout Project) -> Void) throws {
        guard var project = projectsByID[id] else { throw Failure.unknownProject(id) }
        edit(&project)
        commit(project)
    }

    private func commit(_ project: Project) {
        projectsByID[project.id] = project
        store.save(project)
        if let window = now.window { resolve(window, since: now.since) }
    }

    // MARK: Resolving Now

    private func resolve(_ window: ActiveWindow, since: Date?) {
        let match = bestMatch(for: window)
        if let match { lastMatched[match.project] = clock.now }
        now = Now(window: window, since: since, project: match?.project, evidence: match?.matcher)
    }

    /// The most specific fitting Matcher wins; equally specific ones go to the most recently matched Project.
    private func bestMatch(for window: ActiveWindow) -> (project: Project.ID, matcher: Matcher)? {
        let candidates = projectsByID.values
            .filter { $0.status == .active }
            .flatMap { project in
                project.matchers.filter { rules.fits($0, window) }.map { (project: project.id, matcher: $0) }
            }
        return candidates.max { a, b in
            if a.matcher.specificity != b.matcher.specificity {
                return a.matcher.specificity < b.matcher.specificity
            }
            return (lastMatched[a.project] ?? .distantPast) < (lastMatched[b.project] ?? .distantPast)
        }
    }
}
