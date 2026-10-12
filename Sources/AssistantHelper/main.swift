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

    func applicationDidFinishLaunching(_ notification: Notification) {
        let (assistant, storeProblem) = makeAssistant()
        self.assistant = assistant

        let projectsMenu = ProjectsMenu(assistant: assistant)
        let statusItem = StatusItemController(showing: assistant.menuBar, projectsMenu: projectsMenu, storeProblem: storeProblem)
        self.statusItem = statusItem
        StatusItemController.registerLoginItemOnFirstLaunch()

        let receive: (Signal) -> Void = { signal in
            assistant.receive(signal)
            statusItem.render(assistant.menuBar)
        }
        let gitWatcher = GitWatcher(delivering: receive)
        self.gitWatcher = gitWatcher
        gitWatcher.watch(assistant.repoPathsToWatch)
        projectsMenu.onChange = {
            gitWatcher.watch(assistant.repoPathsToWatch)
            statusItem.render(assistant.menuBar)
        }

        _ = ActiveWindowSensor.requestAccessibility()
        let windowSensor = ActiveWindowSensor()
        let calendarSensor = CalendarSensor()
        let idleSensor = IdleSensor()
        (self.windowSensor, self.calendarSensor, self.idleSensor) = (windowSensor, calendarSensor, idleSensor)
        windowSensor.start(delivering: receive)
        calendarSensor.start(delivering: receive)
        idleSensor.start(delivering: receive)
    }

    /// The Assistant over the SQLite store, or, if that can't be opened or read, over a store
    /// that lasts only this run, with the reason shown in the menu.
    private func makeAssistant() -> (Assistant, storeProblem: String?) {
        let clock = SystemClock()
        do {
            let store = try SQLiteStore(url: SQLiteStore.defaultURL())
            let assistant = try Assistant(clock: clock, projects: store, homeDirectory: NSHomeDirectory())
            self.store = store
            return (assistant, nil)
        } catch {
            // An empty in-memory store can't fail to load.
            let assistant = try! Assistant(clock: clock, projects: VolatileProjectStore(), homeDirectory: NSHomeDirectory())
            return (assistant, "\(error)")
        }
    }
}

let app = NSApplication.shared
let delegate = HelperDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
