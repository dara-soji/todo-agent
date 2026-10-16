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
    private var nudgePanel: NudgePanel?
    private var modelCalls: ModelCalls?
    private var mailTriage: MailTriage?
    private var sheetsPolling: SheetsPolling?
    private var notesPolling: NotesPolling?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let (assistant, storeProblem) = makeAssistant()
        self.assistant = assistant

        let projectsMenu = ProjectsMenu(assistant: assistant)
        let tasksMenu = TasksMenu(assistant: assistant)
        let guardrailsMenu = GuardrailsMenu(assistant: assistant)
        let nowMenu = NowMenu(assistant: assistant)
        let exclusionsMenu = ExclusionsMenu(assistant: assistant)
        let google = GoogleAuth()
        let mailTriage = MailTriage(assistant: assistant, auth: google)
        self.mailTriage = mailTriage
        let sheetsPolling = SheetsPolling(assistant: assistant, auth: google)
        self.sheetsPolling = sheetsPolling
        let notesPolling = NotesPolling(assistant: assistant)
        self.notesPolling = notesPolling
        let suggestionsMenu = SuggestionsMenu(assistant: assistant, mail: mailTriage, sheets: sheetsPolling, notes: notesPolling)
        let statusItem = StatusItemController(
            showing: assistant.menuBar, projectsMenu: projectsMenu, tasksMenu: tasksMenu, guardrailsMenu: guardrailsMenu,
            nowMenu: nowMenu, exclusionsMenu: exclusionsMenu, suggestionsMenu: suggestionsMenu, storeProblem: storeProblem)
        self.statusItem = statusItem
        statusItem.currentSpend = { assistant.apiSpendToday }
        statusItem.currentMenuBar = {
            assistant.expireDueAsks()
            return assistant.menuBar
        }
        StatusItemController.registerLoginItemOnFirstLaunch()

        let nudgePanel = NudgePanel(assistant: assistant)
        self.nudgePanel = nudgePanel
        let modelCalls = ModelCalls(assistant: assistant)
        self.modelCalls = modelCalls
        let receive: (Signal) -> Void = { signal in
            assistant.receive(signal)
            statusItem.render(assistant.menuBar)
            nudgePanel.update()
            modelCalls.check()
        }
        let gitWatcher = GitWatcher(delivering: receive)
        self.gitWatcher = gitWatcher
        gitWatcher.watch(assistant.repoPathsToWatch)
        let changed = {
            gitWatcher.watch(assistant.repoPathsToWatch)
            statusItem.render(assistant.menuBar)
            nudgePanel.update()
        }
        nudgePanel.onChange = changed
        modelCalls.onChange = changed
        projectsMenu.onChange = changed
        tasksMenu.onChange = changed
        guardrailsMenu.onChange = changed
        nowMenu.onChange = changed
        exclusionsMenu.onChange = changed
        suggestionsMenu.onChange = changed
        mailTriage.onChange = changed
        sheetsPolling.onChange = changed
        notesPolling.onChange = changed
        setUpQuickAdd(assistant, changed: changed)
        statusItem.onAddTask = { [weak self] in self?.openQuickAdd(assistant) }
        nudgePanel.onSwitchTask = { [weak self] in self?.openQuickAdd(assistant) }
        startMCPServer(assistant, statusItem: statusItem, changed: changed)

        let idleSensor = IdleSensor()
        self.idleSensor = idleSensor
        idleSensor.start(delivering: receive)
        // Without the store, the exclude list can't be trusted, so nothing is read at all.
        guard storeProblem == nil else { return }
        _ = ActiveWindowSensor.requestAccessibility()
        let windowSensor = ActiveWindowSensor()
        windowSensor.excludesApp = { assistant.excludesApp($0) }
        windowSensor.excludesAnySite = { assistant.excludesAnySite }
        let calendarSensor = CalendarSensor()
        (self.windowSensor, self.calendarSensor) = (windowSensor, calendarSensor)
        windowSensor.start(delivering: receive)
        calendarSensor.start(delivering: receive)
        // Like the sensors, only with the exclude list loaded: Excluded senders are never sent.
        mailTriage.start()
        sheetsPolling.start()
        notesPolling.start()
    }

    /// Quitting ends every conversation, so pending Asks are logged as expired, not run.
    func applicationWillTerminate(_ notification: Notification) {
        mailTriage?.stop()
        sheetsPolling?.stop()
        notesPolling?.stop()
        assistant?.expireAllAsks()
        assistant?.closeNowHistory()
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
