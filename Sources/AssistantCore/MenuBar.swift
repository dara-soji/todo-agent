/// What the menu bar shows for the current state. The UI renders this as-is.
public struct MenuBar: Equatable, Sendable {
    public enum Marker: Equatable, Sendable {
        /// No Signal yet.
        case unknown
        /// Now matched a Project: drawn as the square Project dot.
        case project
        /// Now matched no Project.
        case noProject
        /// Dara is idle long enough to be away.
        case away
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

    init(_ now: Now, project: Project?, branch: String?) {
        guard now.window != nil || now.match != nil else {
            title = "—"
            marker = .unknown
            nowDetail = "Waiting for the first Signal"
            evidence = nil
            window = nil
            return
        }
        window = now.window.map { active in
            guard let title = active.title, !title.isEmpty else { return active.app.name }
            return "\(active.app.name) — \(title)"
        }
        if now.isAway {
            title = "AWAY"
            marker = .away
            nowDetail = "Away"
            evidence = nil
        } else if let project, let match = now.match {
            title = Self.shorten(project.shortName.uppercased())
            marker = .project
            nowDetail = project.name
            evidence = Self.evidence(match, branch: branch)
        } else {
            title = "NO PROJECT"
            marker = .noProject
            nowDetail = "No Project"
            evidence = nil
        }
    }

    private static func evidence(_ match: Now.Match, branch: String?) -> String {
        if let event = match.event {
            return "Matched by “\(match.evidence.pattern)” in \(event.title)"
        }
        return "Matched by \(match.evidence.pattern)" + (branch.map { " · \($0)" } ?? "")
    }

    private static func shorten(_ text: String) -> String {
        text.count <= titleLimit ? text : text.prefix(titleLimit - 1) + "…"
    }
}

extension Assistant {
    public var menuBar: MenuBar {
        MenuBar(now, project: now.project.flatMap(project), branch: now.evidence.flatMap(branch(of:)))
    }
}
