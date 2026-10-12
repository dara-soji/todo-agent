import AppKit
import AssistantCore
import AssistantPersistence

/// Wires the OS adapters to the core. Everything the assistant decides happens in AssistantCore.
@MainActor
final class HelperDelegate: NSObject, NSApplicationDelegate {
    private let assistant = Assistant(clock: SystemClock())
    private var store: SQLiteStore?
    private var statusItem: StatusItemController?
    private var sensor: FocusSensor?

    func applicationDidFinishLaunching(_ notification: Notification) {
        var storeProblem: String?
        do {
            store = try SQLiteStore(url: SQLiteStore.defaultURL())
        } catch {
            storeProblem = "\(error)"
        }

        let statusItem = StatusItemController(storeProblem: storeProblem)
        self.statusItem = statusItem
        statusItem.render(assistant.menuBar)

        _ = FocusSensor.requestAccessibility()
        let sensor = FocusSensor { [weak self] signal in
            guard let self else { return }
            assistant.receive(signal)
            statusItem.render(assistant.menuBar)
        }
        self.sensor = sensor
        sensor.start()
    }
}

let app = NSApplication.shared
let delegate = HelperDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
