import AppKit
import AssistantCore
import AssistantPersistence

/// Wires the OS adapters to the core. Everything the assistant decides happens in AssistantCore.
@MainActor
final class HelperDelegate: NSObject, NSApplicationDelegate {
    /// Held for the helper's whole run: owning it is what makes the helper the store's only writer.
    private var store: SQLiteStore?
    private var assistant: Assistant?
    private var statusItem: StatusItemController?
    private var windowSensor: ActiveWindowSensor?
    private var calendarSensor: CalendarSensor?
    private var idleSensor: IdleSensor?
    private var gitWatcher: GitWatcher?
    private var hotKey: HotKey?
    private let quickAdd = QuickAddPanel()
    private let added = AddedPanel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let (assistant, storeProblem) = makeAssistant()
        self.assistant = assistant

        let projectsMenu = ProjectsMenu(assistant: assistant)
        let tasksMenu = TasksMenu(assistant: assistant)
        let statusItem = StatusItemController(
            showing: assistant.menuBar, projectsMenu: projectsMenu, tasksMenu: tasksMenu, storeProblem: storeProblem)
        self.statusItem = statusItem
        StatusItemController.registerLoginItemOnFirstLaunch()

        let receive: (Signal) -> Void = { signal in
            assistant.receive(signal)
            statusItem.render(assistant.menuBar)
        }
        let gitWatcher = GitWatcher(delivering: receive)
        self.gitWatcher = gitWatcher
        gitWatcher.watch(assistant.repoPathsToWatch)
        let changed = {
            gitWatcher.watch(assistant.repoPathsToWatch)
            statusItem.render(assistant.menuBar)
        }
        projectsMenu.onChange = changed
        tasksMenu.onChange = changed
        setUpQuickAdd(assistant, changed: changed)
        statusItem.onAddTask = { [weak self] in self?.openQuickAdd(assistant) }

        _ = ActiveWindowSensor.requestAccessibility()
        let windowSensor = ActiveWindowSensor()
        let calendarSensor = CalendarSensor()
        let idleSensor = IdleSensor()
        (self.windowSensor, self.calendarSensor, self.idleSensor) = (windowSensor, calendarSensor, idleSensor)
        windowSensor.start(delivering: receive)
        calendarSensor.start(delivering: receive)
        idleSensor.start(delivering: receive)
    }

    private func setUpQuickAdd(_ assistant: Assistant, changed: @escaping () -> Void) {
        hotKey = HotKey { [weak self] in self?.openQuickAdd(assistant) }
        quickAdd.onSubmit = { [weak self] title, start in
            guard let self else { return }
            do {
                let task = try assistant.quickAdd(title, start: start)
                let entry = assistant.operationLog.last
                changed()
                let destination = task.project.flatMap(assistant.project)?.shortName.uppercased() ?? "NO PROJECT"
                added.show(
                    start ? "Started “\(task.title)” · \(destination)" : "Added “\(task.title)” · \(destination)",
                    started: start,
                    onStart: { Self.attempt(changed) { try assistant.commitTask(task.id) } },
                    onUndo: { Self.attempt(changed) { if let entry { try assistant.undo(entry.id) } } })
            } catch {
                NSSound.beep()
            }
        }
    }

    /// Runs a change from a panel button; a refusal (e.g. the Task changed since) just beeps.
    private static func attempt(_ changed: () -> Void, _ change: () throws -> Void) {
        do { try change() } catch { NSSound.beep() }
        changed()
    }

    private func openQuickAdd(_ assistant: Assistant) {
        let menuBar = assistant.menuBar
        quickAdd.show(destination: menuBar.marker == .project ? menuBar.title : "NO PROJECT")
    }

    /// The Assistant over the SQLite store, or, if that can't be opened or read, over a store
    /// that lasts only this run, with the reason shown in the menu.
    private func makeAssistant() -> (Assistant, storeProblem: String?) {
        let clock = SystemClock()
        do {
            let store = try SQLiteStore(url: SQLiteStore.defaultURL())
            let assistant = try Assistant(clock: clock, store: store, homeDirectory: NSHomeDirectory())
            self.store = store
            return (assistant, nil)
        } catch {
            // An empty in-memory store can't fail to load.
            let assistant = try! Assistant(clock: clock, store: VolatileStore(), homeDirectory: NSHomeDirectory())
            return (assistant, "\(error)")
        }
    }
}

let app = NSApplication.shared
let delegate = HelperDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
