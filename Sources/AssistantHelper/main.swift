import AppKit
import AssistantCore
import AssistantMCP
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
    private var mcpServer: AssistantMCPServer?
    private let quickAdd = QuickAddPanel()
    private let added = AddedPanel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let (assistant, storeProblem) = makeAssistant()
        self.assistant = assistant

        let projectsMenu = ProjectsMenu(assistant: assistant)
        let tasksMenu = TasksMenu(assistant: assistant)
        let guardrailsMenu = GuardrailsMenu(assistant: assistant)
        let nowMenu = NowMenu(assistant: assistant)
        let statusItem = StatusItemController(
            showing: assistant.menuBar, projectsMenu: projectsMenu, tasksMenu: tasksMenu, guardrailsMenu: guardrailsMenu,
            nowMenu: nowMenu, storeProblem: storeProblem)
        self.statusItem = statusItem
        statusItem.currentMenuBar = {
            assistant.expireDueAsks()
            return assistant.menuBar
        }
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
        guardrailsMenu.onChange = changed
        nowMenu.onChange = changed
        setUpQuickAdd(assistant, changed: changed)
        statusItem.onAddTask = { [weak self] in self?.openQuickAdd(assistant) }
        startMCPServer(assistant, statusItem: statusItem, changed: changed)

        _ = ActiveWindowSensor.requestAccessibility()
        let windowSensor = ActiveWindowSensor()
        let calendarSensor = CalendarSensor()
        let idleSensor = IdleSensor()
        (self.windowSensor, self.calendarSensor, self.idleSensor) = (windowSensor, calendarSensor, idleSensor)
        windowSensor.start(delivering: receive)
        calendarSensor.start(delivering: receive)
        idleSensor.start(delivering: receive)
    }

    /// Quitting ends every conversation, so pending Asks are logged as expired, not run.
    func applicationWillTerminate(_ notification: Notification) {
        assistant?.expireAllAsks()
    }

    /// The local MCP server Claude Code talks to. If it can't start, the menu says why and
    /// everything else keeps working.
    private func startMCPServer(_ assistant: Assistant, statusItem: StatusItemController, changed: @escaping () -> Void) {
        let token: String
        let server: AssistantMCPServer
        do {
            token = try MCPToken.loadOrCreate()
            server = try AssistantMCPServer(assistant: assistant, token: token)
        } catch {
            statusItem.claudeCode = .unavailable("\(error)")
            return
        }
        server.tools.onChange = changed
        mcpServer = server
        _Concurrency.Task {
            do {
                let port = try await server.start()
                statusItem.claudeCode = .ready(command: ClaudeCodeConnection.command(port: port, token: token))
            } catch {
                statusItem.claudeCode = .unavailable("\(error)")
            }
        }
    }

    private func setUpQuickAdd(_ assistant: Assistant, changed: @escaping () -> Void) {
        hotKey = HotKey { [weak self] in self?.openQuickAdd(assistant) }
        quickAdd.onSubmit = { [weak self] title, start in
            guard let self else { return }
            do {
                let task = try assistant.quickAdd(title, start: start)
                let entry = assistant.operationLog.last
                changed()
                let destination = Self.destination(task.project, in: assistant)
                added.show(
                    start ? "Started “\(task.title)” · \(destination)" : "Added “\(task.title)” · \(destination)",
                    started: start,
                    onStart: { Attempt.run("Couldn't start the Task", then: changed) { try assistant.commitTask(task.id, asInterruption: true) } },
                    onUndo: { Attempt.run("Couldn't undo", then: changed) { if let entry { try assistant.undo(entry.id) } } })
            } catch {
                NSSound.beep()
            }
        }
    }

    private func openQuickAdd(_ assistant: Assistant) {
        quickAdd.show(destination: Self.destination(assistant.now.project, in: assistant))
    }

    /// Where a quick-added Task goes, as the palette and the confirmation name it.
    private static func destination(_ project: Project.ID?, in assistant: Assistant) -> String {
        project.flatMap(assistant.project)?.shortName.uppercased() ?? "NO PROJECT"
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
