import AppKit
import AssistantCore

/// The Operation log, newest first: when, what, its tier, who started it and what came of it, with
/// Undo for the selected entry. Kept 90 days.
@MainActor
final class OperationLogWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let assistant: Assistant
    private var panel: NSPanel?
    private let table = NSTableView()
    private var entries: [LogEntry] = []
    var onChange: () -> Void = {}

    private static let columns = [("when", "When", 130.0), ("what", "What", 330.0), ("tier", "Tier", 50.0),
                                  ("who", "Who", 90.0), ("outcome", "Outcome", 90.0)]

    init(assistant: Assistant) {
        self.assistant = assistant
    }

    func show() {
        entries = assistant.operationLog.reversed()
        if panel == nil { build() }
        table.reloadData()
        NSApp.activate()
        panel?.makeKeyAndOrderFront(nil)
    }

    private func build() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 420),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = "Operation log — kept 90 days"
        panel.isReleasedWhenClosed = false
        for (id, title, width) in Self.columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 44, width: 720, height: 376))
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autoresizingMask = [.width, .height]
        let undo = NSButton(title: "Undo selected", target: self, action: #selector(undoSelected))
        undo.frame = NSRect(x: 12, y: 8, width: 140, height: 28)
        panel.contentView?.addSubview(scroll)
        panel.contentView?.addSubview(undo)
        panel.center()
        self.panel = panel
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        entries.count
    }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        let entry = entries[row]
        let text: String = switch column?.identifier.rawValue {
        case "when": entry.at.formatted(date: .abbreviated, time: .shortened)
        case "what": entry.summary
        case "tier": entry.tier.rawValue
        case "who": switch entry.startedBy {
            case .dara: "You"
            case .claudeCode: "Claude Code"
            case .helper: "The assistant"
            }
        default: switch entry.confirmation {
            case .notNeeded: "Ran"
            case .confirmed: "Confirmed"
            case .declined: "Declined"
            case .expired: "Expired"
            }
        }
        let field = NSTextField(labelWithString: text)
        field.lineBreakMode = .byTruncatingTail
        field.toolTip = text
        return field
    }

    @objc private func undoSelected() {
        guard entries.indices.contains(table.selectedRow) else { return }
        let entry = entries[table.selectedRow]
        Attempt.run("Couldn't undo that", then: onChange) { try assistant.undo(entry.id) }
        show()
    }
}
