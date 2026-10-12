/// What the menu bar shows for the current state. The UI renders this as-is.
public struct MenuBar: Equatable, Sendable {
    public enum Marker: Equatable, Sendable {
        /// No Signal yet.
        case unknown
        /// Now matched a Project: drawn as the square Project dot.
        case project
        /// Now matched no Project.
        case noProject
    }

    /// The menu-bar item's text.
    public let title: String
    public let marker: Marker
    /// The Now line in the dropdown: the Project's full name, or "No Project".
    public let nowDetail: String
    /// Why Now is on that Project, e.g. "Matched by ~/code/todo-agent".
    public let evidence: String?
    /// The app and full window title, never shortened.
    public let window: String?

    /// Longest menu-bar title, ellipsis included.
    static let titleLimit = 15

    init(_ now: Now, project: Project?) {
        guard let active = now.window else {
            title = "—"
            marker = .unknown
            nowDetail = "Waiting for the first Signal"
            evidence = nil
            window = nil
            return
        }
        if let title = active.title, !title.isEmpty {
            window = "\(active.app.name) — \(title)"
        } else {
            window = active.app.name
        }
        if let project, let matcher = now.evidence {
            title = Self.shorten(project.shortName.uppercased())
            marker = .project
            nowDetail = project.name
            evidence = "Matched by \(matcher.pattern)"
        } else {
            title = "NO PROJECT"
            marker = .noProject
            nowDetail = "No Project"
            evidence = nil
        }
    }

    private static func shorten(_ text: String) -> String {
        text.count <= titleLimit ? text : text.prefix(titleLimit - 1) + "…"
    }
}

extension Matcher {
    /// The Matcher as Dara wrote it, for showing as evidence.
    public var pattern: String {
        switch self {
        case let .repoPath(path): path
        case let .urlPrefix(prefix): prefix
        }
    }
}

extension Assistant {
    public var menuBar: MenuBar { MenuBar(now, project: now.project.flatMap(project)) }
}
