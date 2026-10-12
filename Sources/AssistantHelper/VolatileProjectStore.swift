import AssistantCore

/// Used only when the SQLite store can't be opened: Projects work for this run but aren't kept.
final class VolatileProjectStore: ProjectStore {
    private var saved: [Project.ID: Project] = [:]
    func loadProjects() -> [Project] { Array(saved.values) }
    func save(_ project: Project) { saved[project.id] = project }
}
