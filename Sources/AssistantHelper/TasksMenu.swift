import AppKit
import AssistantCore

/// The Tasks ▸ and Deleted ▸ submenus, and Mark done under Now. Every change goes to the core.
@MainActor
final class TasksMenu: NSObject {
    private let assistant: Assistant
    /// Called after every attempted change, so the menu bar can redraw.
    var onChange: () -> Void = {}

    init(assistant: Assistant) {
        self.assistant = assistant
    }

    func markDoneItem() -> NSMenuItem? {
        guard let committed = assistant.committedTask else { return nil }
        return menuItem("Mark done", #selector(complete(_:)), committed.id)
    }

    func tasksItem() -> NSMenuItem {
        let root = NSMenuItem(title: "Tasks", action: nil, keyEquivalent: "")
        let menu = NSMenu()
        let unfinished = assistant.tasks.filter(\.status.isUnfinished)
        if unfinished.isEmpty {
            menu.addItem(withTitle: "No open Tasks", action: nil, keyEquivalent: "").isEnabled = false
        }
        for task in unfinished {
            menu.addItem(taskItem(task))
        }
        root.submenu = menu
        return root
    }

    func deletedItem() -> NSMenuItem? {
        let deleted = assistant.deletedTasks
        guard !deleted.isEmpty else { return nil }
        let root = NSMenuItem(title: "Deleted", action: nil, keyEquivalent: "")
        let menu = NSMenu()
        menu.addItem(withTitle: "Restore", action: nil, keyEquivalent: "").isEnabled = false
        for task in deleted {
            let item = menuItem(task.title, #selector(restore(_:)), task.id)
            item.indentationLevel = 1
            menu.addItem(item)
        }
        root.submenu = menu
        return root
    }

    private func taskItem(_ task: Task) -> NSMenuItem {
        let item = NSMenuItem(title: Self.label(task), action: nil, keyEquivalent: "")
        let menu = NSMenu()
        if task.status != .committed { menu.addItem(menuItem("Start", #selector(start(_:)), task.id)) }
        menu.addItem(menuItem("Mark done", #selector(complete(_:)), task.id))
        let snooze = NSMenuItem(title: "Snooze", action: nil, keyEquivalent: "")
        snooze.submenu = NSMenu()
        snooze.submenu?.addItem(menuItem("1 hour", #selector(snoozeHour(_:)), task.id))
        snooze.submenu?.addItem(menuItem("Till tomorrow", #selector(snoozeTomorrow(_:)), task.id))
        snooze.submenu?.addItem(menuItem("Waiting on someone…", #selector(snoozeWaiting(_:)), task.id))
        menu.addItem(snooze)
        menu.addItem(menuItem("Drop", #selector(drop(_:)), task.id))
        menu.addItem(.separator())
        menu.addItem(menuItem("Delete", #selector(delete(_:)), task.id))
        item.submenu = menu
        return item
    }

    private static func label(_ task: Task) -> String {
        switch task.status {
        case .committed: "▸ \(task.title)"
        case .snoozed(_, let note?): "\(task.title) — waiting: \(note)"
        case .snoozed: "\(task.title) — snoozed"
        default: task.resumeAfterInterruption ? "\(task.title) — resume" : task.title
        }
    }

    // MARK: Menu handlers

    @objc private func start(_ sender: NSMenuItem) { attempt(sender) { try assistant.commitTask($0) } }
    @objc private func complete(_ sender: NSMenuItem) { attempt(sender) { try assistant.completeTask($0) } }
    @objc private func drop(_ sender: NSMenuItem) { attempt(sender) { try assistant.dropTask($0) } }
    @objc private func delete(_ sender: NSMenuItem) { attempt(sender) { try assistant.deleteTask($0) } }
    @objc private func restore(_ sender: NSMenuItem) { attempt(sender) { try assistant.restoreTask($0) } }

    @objc private func snoozeHour(_ sender: NSMenuItem) {
        attempt(sender) { try assistant.snoozeTask($0, until: Date().addingTimeInterval(60 * 60)) }
    }

    @objc private func snoozeTomorrow(_ sender: NSMenuItem) {
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date()))!
        let nineAM = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow)!
        attempt(sender) { try assistant.snoozeTask($0, until: nineAM) }
    }

    @objc private func snoozeWaiting(_ sender: NSMenuItem) {
        let alert = NSAlert()
        alert.messageText = "Waiting on someone"
        alert.informativeText = "Who, or what for? It leaves Next until you bring it back."
        alert.addButton(withTitle: "Snooze")
        alert.addButton(withTitle: "Cancel")
        let note = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        alert.accessoryView = note
        alert.window.initialFirstResponder = note
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let text = note.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        attempt(sender) { try assistant.snoozeTask($0, until: nil, note: text.isEmpty ? nil : text) }
    }

    private func attempt(_ sender: NSMenuItem, _ change: (Task.ID) throws -> Void) {
        guard let id = sender.representedObject as? Task.ID else { return }
        Attempt.run("Couldn't change the Task", then: onChange) { try change(id) }
    }

    private func menuItem(_ title: String, _ selector: Selector, _ id: Task.ID) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        item.representedObject = id
        return item
    }
}
