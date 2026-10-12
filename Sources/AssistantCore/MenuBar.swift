/// What the menu bar shows for the current state. The UI renders this as-is.
public struct MenuBar: Equatable, Sendable {
    /// The menu-bar item's text.
    public let title: String
    /// The Now line in the dropdown, never shortened.
    public let nowDetail: String

    /// Longest window title, ellipsis included, that fits in the menu-bar item.
    static let titleLimit = 34

    init(_ now: Now) {
        switch now {
        case .unknown:
            title = "—"
            nowDetail = "Waiting for the first Signal"
        case let .window(app, windowTitle, _):
            let label = app.name.uppercased()
            if let windowTitle, !windowTitle.isEmpty {
                title = "\(label) · \(Self.shorten(windowTitle))"
                nowDetail = "\(app.name) — \(windowTitle)"
            } else {
                title = label
                nowDetail = app.name
            }
        }
    }

    private static func shorten(_ text: String) -> String {
        text.count <= titleLimit ? text : text.prefix(titleLimit - 1) + "…"
    }
}

extension Assistant {
    public var menuBar: MenuBar { MenuBar(now) }
}
