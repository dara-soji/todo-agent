import AssistantCore

/// Persistence fake: keeps Projects in memory so tests can check they survive a new Assistant,
/// and can be told to fail saves.
final class InMemoryProjectStore: ProjectStore {
    struct SaveFailed: Error {}

    private var saved: [Project.ID: Project] = [:]
    var failSaves = false

    func loadProjects() throws -> [Project] {
        Array(saved.values)
    }

    func save(_ project: Project) throws {
        if failSaves { throw SaveFailed() }
        saved[project.id] = project
    }
}
