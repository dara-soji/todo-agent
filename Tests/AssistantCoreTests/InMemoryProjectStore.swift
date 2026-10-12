import AssistantCore

/// Persistence fake: keeps Projects in memory so tests can check they survive a new Assistant.
final class InMemoryProjectStore: ProjectStore {
    private var saved: [Project.ID: Project] = [:]

    func loadProjects() -> [Project] {
        saved.values.sorted { $0.name < $1.name }
    }

    func save(_ project: Project) {
        saved[project.id] = project
    }
}
