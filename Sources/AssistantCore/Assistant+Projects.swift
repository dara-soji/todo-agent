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

    @discardableResult
    public func declareProject(
        name: String, shortName: String? = nil, matchers: [Matcher], by startedBy: StartedBy = .dara
    ) throws -> Project {
        let project = Project(
            name: try Self.nonEmpty(name, else: .emptyName), shortName: shortName,
            matchers: try matchers.map(fitting.normalised))
        try perform(.declareProject, "Declared Project “\(project.name)”", by: startedBy, writing: Change(projects: [project]))
        return project
    }

    public func renameProject(_ id: Project.ID, name: String, shortName: String? = nil, by startedBy: StartedBy = .dara) throws {
        let name = try Self.nonEmpty(name, else: .emptyName)
        try change(id, .editProject, "Renamed", by: startedBy) {
            $0.name = name
            $0.shortName = shortName ?? name
        }
    }

    public func addMatcher(_ matcher: Matcher, to id: Project.ID, by startedBy: StartedBy = .dara) throws {
        try addMatchers([matcher], to: id, by: startedBy)
    }

    /// Adds every Matcher, or none if any is invalid.
    public func addMatchers(_ matchers: [Matcher], to id: Project.ID, by startedBy: StartedBy = .dara) throws {
        let matchers = try matchers.map(fitting.normalised)
        try change(id, .editProject, "Added Matchers to", by: startedBy) { project in
            for matcher in matchers where !project.matchers.contains(matcher) {
                project.matchers.append(matcher)
            }
        }
    }

    public func removeMatcher(_ matcher: Matcher, from id: Project.ID, by startedBy: StartedBy = .dara) throws {
        let matcher = (try? fitting.normalised(matcher)) ?? matcher
        try change(id, .editProject, "Removed a Matcher from", by: startedBy) { $0.matchers.removeAll { $0 == matcher } }
    }

    /// An archived Project matches nothing until it is restored.
    public func archiveProject(_ id: Project.ID, by startedBy: StartedBy = .dara) throws {
        try change(id, .archiveProject, "Archived", by: startedBy) { $0.status = .archived }
    }

    public func restoreProject(_ id: Project.ID, by startedBy: StartedBy = .dara) throws {
        try change(id, .restoreProject, "Restored", by: startedBy) { $0.status = .active }
    }

    private func change(
        _ id: Project.ID, _ kind: OperationKind, _ verb: String, by startedBy: StartedBy, _ edit: (inout Project) -> Void
    ) throws {
        guard var project = projectsByID[id] else { throw Failure.unknownProject(id) }
        edit(&project)
        try perform(kind, "\(verb) Project “\(project.name)”", by: startedBy, writing: Change(projects: [project]))
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
