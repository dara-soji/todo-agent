import AppKit
import AssistantCore
import AssistantPersistence

/// Wires the OS adapters to the core. Everything the assistant decides happens in AssistantCore.
@MainActor
final class HelperDelegate: NSObject, NSApplicationDelegate {
    private var assistant: Assistant!
    /// Held for the helper's whole run: owning it is what makes the helper the store's only writer.
    private var store: SQLiteStore?
    private var statusItem: StatusItemController?
    private var sensor: ActiveWindowSensor?

    func applicationDidFinishLaunching(_ notification: Notification) {
        var storeProblem: String?
        do {
            store = try SQLiteStore(url: SQLiteStore.defaultURL())
        } catch {
            storeProblem = "\(error)"
        }

        let assistant = Assistant(
            clock: SystemClock(),
            projects: store ?? VolatileProjectStore(),
            homeDirectory: NSHomeDirectory())
        self.assistant = assistant

        var statusItem: StatusItemController!
        let projectsMenu = ProjectsMenu(assistant: assistant) { statusItem.render(assistant.menuBar) }
        statusItem = StatusItemController(showing: assistant.menuBar, projectsMenu: projectsMenu, storeProblem: storeProblem)
        self.statusItem = statusItem
        StatusItemController.registerLoginItemOnFirstLaunch()

        _ = ActiveWindowSensor.requestAccessibility()
        let sensor = ActiveWindowSensor()
        self.sensor = sensor
        sensor.start { signal in
            assistant.receive(signal)
            statusItem.render(assistant.menuBar)
        }
    }
}

let app = NSApplication.shared
let delegate = HelperDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
