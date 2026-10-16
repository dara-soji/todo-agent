import Foundation

extension Assistant {
    /// Every Project, active and archived, by name.
    public var projects: [Project] {
        projectsByID.values.sorted(by: Self.byName)
    }

    public func project(_ id: Project.ID) -> Project? {
        projectsByID[id]
    }

    var activeProjects: [Project] {
        projects.filter { $0.status == .active }
    }

    /// Declares a Project Dara asked for.
    @discardableResult
    public func declareProject(
        name: String, shortName: String? = nil, matchers: [Matcher], by startedBy: StartedBy = .dara
    ) throws -> Project {
        try declare(name: name, shortName: shortName, matchers: matchers, by: startedBy, proposed: false).project
    }

    /// Declares a Project the assistant proposes: it asks Dara first.
    @discardableResult
    public func declareProjectProposed(
        name: String, shortName: String? = nil, matchers: [Matcher], by startedBy: StartedBy
    ) throws -> (project: Project, outcome: Outcome) {
        try declare(name: name, shortName: shortName, matchers: matchers, by: startedBy, proposed: true)
    }

    /// Declares a Project, proposed or asked for, and says what came of it: it may wait in an Ask.
    @discardableResult
    public func declare(
        name: String, shortName: String?, matchers: [Matcher], by startedBy: StartedBy, proposed: Bool
    ) throws -> (project: Project, outcome: Outcome) {
        let project = Project(
            name: try Self.nonEmpty(name, else: .emptyName), shortName: shortName,
            matchers: try matchers.map(fitting.normalised))
        let outcome = try perform(.declareProject, "Declared Project “\(project.name)”" + Self.claim(startedBy, proposed),
                                  by: startedBy, writing: Change(projects: [project]), proposed: proposed)
        return (project, outcome)
    }

    @discardableResult
    public func renameProject(
        _ id: Project.ID, name: String, shortName: String? = nil, by startedBy: StartedBy = .dara, proposed: Bool = false
    ) throws -> Outcome {
        let name = try Self.nonEmpty(name, else: .emptyName)
        return try change(id, .editProject, "Renamed", by: startedBy, proposed: proposed) {
            $0.name = name
            $0.shortName = shortName ?? name
        }
    }

    @discardableResult
    public func addMatcher(_ matcher: Matcher, to id: Project.ID, by startedBy: StartedBy = .dara) throws -> Outcome {
        try addMatchers([matcher], to: id, by: startedBy)
    }

    /// The Operations below take `proposed`: true when the assistant proposes the change rather than
    /// Dara asking for it, which makes it ask first.

    /// Adds every Matcher, or none if any is invalid.
    @discardableResult
    public func addMatchers(
        _ matchers: [Matcher], to id: Project.ID, by startedBy: StartedBy = .dara, proposed: Bool = false
    ) throws -> Outcome {
        let matchers = try matchers.map(fitting.normalised)
        return try change(id, .editProject, "Added Matchers to", by: startedBy, proposed: proposed) { project in
            for matcher in matchers where !project.matchers.contains(matcher) {
                project.matchers.append(matcher)
            }
        }
    }

    @discardableResult
    public func removeMatcher(
        _ matcher: Matcher, from id: Project.ID, by startedBy: StartedBy = .dara, proposed: Bool = false
    ) throws -> Outcome {
        let matcher = (try? fitting.normalised(matcher)) ?? matcher
        return try change(id, .editProject, "Removed a Matcher from", by: startedBy, proposed: proposed) {
            $0.matchers.removeAll { $0 == matcher }
        }
    }

    /// An archived Project matches nothing until it is restored.
    @discardableResult
    public func archiveProject(_ id: Project.ID, by startedBy: StartedBy = .dara, proposed: Bool = false) throws -> Outcome {
        return try change(id, .archiveProject, "Archived", by: startedBy, proposed: proposed) { $0.status = .archived }
    }

    @discardableResult
    public func restoreProject(_ id: Project.ID, by startedBy: StartedBy = .dara, proposed: Bool = false) throws -> Outcome {
        return try change(id, .restoreProject, "Restored", by: startedBy, proposed: proposed) { $0.status = .active }
    }

    private func change(
        _ id: Project.ID, _ kind: OperationKind, _ verb: String, by startedBy: StartedBy, proposed: Bool = false,
        _ edit: (inout Project) -> Void
    ) throws -> Outcome {
        guard var project = projectsByID[id] else { throw Failure.unknownProject(id) }
        edit(&project)
        return try perform(kind, "\(verb) Project “\(project.name)”" + Self.claim(startedBy, proposed), by: startedBy,
                           writing: Change(projects: [project]), proposed: proposed)
    }

    /// Claude Code says Dara asked for it, which the helper can't check: the log says whose word it is.
    private static func claim(_ startedBy: StartedBy, _ proposed: Bool) -> String {
        startedBy == .claudeCode && !proposed ? " (Dara asked, per Claude Code)" : ""
    }

    private static func byName(_ a: Project, _ b: Project) -> Bool {
        a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }
}

extension Project {
    func archived() -> Project {
        var project = self
        project.status = .archived
        return project
    }
}
