import Foundation

/// The assistant's domain. Feed it Signals; read Now.
public final class Assistant {
    public enum Failure: Error, Equatable {
        case unknownProject(Project.ID)
        case emptyName
    }

    private let clock: WallClock
    private let store: ProjectStore
    private let fitting: MatcherFitting
    private var projectsByID: [Project.ID: Project]
    /// When each Project last matched, to break ties between equally specific Matchers.
    private var lastMatched: [Project.ID: Date] = [:]

    public private(set) var now: Now = .unknown

    public init(clock: WallClock, projects: ProjectStore, homeDirectory: String) throws {
        self.clock = clock
        self.store = projects
        self.fitting = MatcherFitting(homeDirectory: homeDirectory)
        self.projectsByID = Dictionary(uniqueKeysWithValues: try projects.loadProjects().map { ($0.id, $0) })
    }

    public func receive(_ signal: Signal) {
        switch signal {
        case let .activeWindow(app, title, url):
            let window = ActiveWindow(app: app, title: title, url: url)
            let since = window == now.window ? now.since ?? clock.now : clock.now
            resolve(Now.Visit(window: window, since: since))
        }
    }

    // MARK: Projects

    /// Every Project, active and archived, by name.
    public var projects: [Project] {
        projectsByID.values.sorted(by: Self.byName)
    }

    public func project(_ id: Project.ID) -> Project? {
        projectsByID[id]
    }

    @discardableResult
    public func declareProject(name: String, shortName: String? = nil, matchers: [Matcher]) throws -> Project {
        let project = Project(
            name: try Self.validName(name), shortName: shortName,
            matchers: try matchers.map(fitting.normalised))
        try commit(project)
        return project
    }

    public func renameProject(_ id: Project.ID, name: String, shortName: String? = nil) throws {
        let name = try Self.validName(name)
        try change(id) {
            $0.name = name
            $0.shortName = shortName ?? name
        }
    }

    public func addMatcher(_ matcher: Matcher, to id: Project.ID) throws {
        try addMatchers([matcher], to: id)
    }

    /// Adds every Matcher, or none if any is invalid.
    public func addMatchers(_ matchers: [Matcher], to id: Project.ID) throws {
        let matchers = try matchers.map(fitting.normalised)
        try change(id) { project in
            for matcher in matchers where !project.matchers.contains(matcher) {
                project.matchers.append(matcher)
            }
        }
    }

    public func removeMatcher(_ matcher: Matcher, from id: Project.ID) throws {
        let matcher = (try? fitting.normalised(matcher)) ?? matcher
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
        try commit(project)
    }

    /// Stores the Project first, so a failed save leaves everything as it was.
    private func commit(_ project: Project) throws {
        try store.save(project)
        projectsByID[project.id] = project
        if let visit = now.visit { resolve(visit) }
    }

    private static func validName(_ name: String) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw Failure.emptyName }
        return name
    }

    private static func byName(_ a: Project, _ b: Project) -> Bool {
        a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }

    // MARK: Resolving Now

    private func resolve(_ visit: Now.Visit) {
        let match = bestMatch(for: visit.window)
        if let match { lastMatched[match.project] = clock.now }
        now = Now(visit: visit, match: match)
    }

    /// The most specific fitting Matcher wins; equally specific ones go to the most recently
    /// matched Project, then to the first by name.
    private func bestMatch(for window: ActiveWindow) -> Now.Match? {
        let candidates = projects
            .filter { $0.status == .active }
            .flatMap { project in
                project.matchers.filter { fitting.fits($0, window) }.map { Now.Match(project: project.id, evidence: $0) }
            }
        // `max` keeps the first of equal elements, and candidates are in name order.
        return candidates.max { a, b in
            if a.evidence.specificity != b.evidence.specificity {
                return a.evidence.specificity < b.evidence.specificity
            }
            return (lastMatched[a.project] ?? .distantPast) < (lastMatched[b.project] ?? .distantPast)
        }
    }
}
