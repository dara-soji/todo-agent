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
    private var pushToTalk = PushToTalk(clock: SystemClock())
    private let voice = VoiceCapture()
    /// Every voice press in play: the one the key is on and earlier ones still finishing.
    private var presses = VoicePresses()
    private var holdTimer: Timer?
    /// Ends a recording at `PushToTalk.recordingCap` as if the key had been released.
    private var capTimer: Timer?
    /// Refreshes the menus after a quick-add.
    private var quickAddChanged: (() -> Void)?
    private var nudgePanel: NudgePanel?
    private var modelCalls: ModelCalls?
    private var mailTriage: MailTriage?
    private var sheetsPolling: SheetsPolling?
    private var notesPolling: NotesPolling?
    private var logWindow: OperationLogWindow?
    /// One walkthrough at a time: it waits on permission prompts, during which the menu still works.
    private var walkthroughRunning = false

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
        // Set once the log window exists, so it stays current while open.
        var refreshLog: () -> Void = {}
        let changed = {
            gitWatcher.watch(assistant.repoPathsToWatch)
            statusItem.render(assistant.menuBar)
            nudgePanel.update()
            refreshLog()
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
        let logWindow = OperationLogWindow(assistant: assistant)
        logWindow.onChange = changed
        self.logWindow = logWindow
        refreshLog = { logWindow.reload() }
        statusItem.onShowLog = { logWindow.show() }
        statusItem.currentNeedsSetup = { assistant.needsSetup }
        let walkthrough = { [weak self] in
            guard let self, !self.walkthroughRunning else { return }
            self.walkthroughRunning = true
            await SetupWalkthrough.run(assistant, askForAPIKey: { StatusItemController.askForAPIKey() },
                                       connectGoogle: { suggestionsMenu.connectGoogle() })
            self.walkthroughRunning = false
            changed()
        }
        statusItem.onRunSetup = { [weak self] in
            _Concurrency.Task {
                let wasNeeded = assistant.needsSetup
                await walkthrough()
                // Finished from the menu after "Later": reading starts now.
                if wasNeeded, !assistant.needsSetup, storeProblem == nil {
                    self?.startReading(assistant, receive: receive, mailTriage: mailTriage, sheetsPolling: sheetsPolling,
                                       notesPolling: notesPolling)
                }
            }
        }

        // Without the store, the exclude list can't be trusted, so nothing is read at all.
        guard storeProblem == nil else { return }
        guard !assistant.needsSetup else {
            // First run: the walkthrough explains each permission before macOS asks for it.
            _Concurrency.Task { [weak self] in
                await walkthrough()
                // "Later": nothing is read until setup is done, so exclusions come first.
                guard !assistant.needsSetup else { return }
                self?.startReading(assistant, receive: receive, mailTriage: mailTriage, sheetsPolling: sheetsPolling,
                                   notesPolling: notesPolling)
            }
            return
        }
        _ = ActiveWindowSensor.requestAccessibility()
        startReading(assistant, receive: receive, mailTriage: mailTriage, sheetsPolling: sheetsPolling, notesPolling: notesPolling)
    }

    /// The window, calendar and Source readers. Only with the exclude list loaded.
    private func startReading(
        _ assistant: Assistant, receive: @escaping (Signal) -> Void, mailTriage: MailTriage, sheetsPolling: SheetsPolling,
        notesPolling: NotesPolling
    ) {
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
        hotKey = HotKey(
            pressed: { [weak self] in self?.quickAddPressed() },
            released: { [weak self] in self?.quickAddReleased() })
        quickAddChanged = changed
        voice.onPartial = { [weak self] text in
            // Partials only while this press's Listening… is up.
            guard let self, let down = presses.down, presses.palette == down.id else { return }
            quickAdd.showTranscript(text)
        }
        quickAdd.onSubmit = { [weak self] title, start in
            guard let self else { return }
            do {
                let task = try assistant.quickAdd(title, start: start)
                // Read at once: nothing else can be logged in between.
                let entry = assistant.task(task.id) == nil ? nil : assistant.operationLog.last?.id
                showAdded([task], undoing: entry, started: start, assistant, changed: changed)
            } catch {
                NSSound.beep()
            }
        }
    }

    /// ⌥Space down: audio starts buffering now, and a timer decides at 300 ms whether it's a hold.
    private func quickAddPressed() {
        guard pushToTalk.keyDown() == .startBuffering else { return }
        let project = assistant?.now.confidentProject
        let press = presses.pressed(voice.begin(), project: project)
        holdTimer?.invalidate()
        holdTimer = Timer.scheduledTimer(withTimeInterval: PushToTalk.holdThreshold, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.quickAddHeld(press.id) }
        }
        capTimer?.invalidate()
        capTimer = Timer.scheduledTimer(withTimeInterval: PushToTalk.recordingCap, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.pushToTalk.capCheck() == .finishListening else { return }
                self.quickAddEnded(.finishListening)
            }
        }
    }

    private func quickAddHeld(_ id: VoicePress.ID) {
        guard pushToTalk.holdCheck() == .startListening, let assistant else { return }
        switch presses.held(id) {
        case .showListening(let press):
            NSSound(named: "Tink")?.play()
            quickAdd.showListening(destination: Self.destination(press.project, in: assistant))
            quickAdd.showTranscript(voice.transcript)
        case .askThenType(let readiness):
            // Voice can't run: the hold still opens the typing box, saying why. The first hold
            // shows macOS's permission prompt too.
            VoiceCapture.askForPermission(readiness)
            openQuickAdd(assistant, voice: readiness)
        case .ignore:
            break
        }
    }

    private func quickAddReleased() {
        quickAddEnded(pushToTalk.keyUp())
    }

    /// The press is over: released, or cut off at the cap (whose later real release is nil here).
    private func quickAddEnded(_ action: PushToTalk.Action?) {
        guard let assistant, let changed = quickAddChanged else { return }
        holdTimer?.invalidate()
        holdTimer = nil
        capTimer?.invalidate()
        capTimer = nil
        switch presses.ended(action) {
        case .discardThenType:
            voice.cancel()
            openQuickAdd(assistant)
        case .finish(let press):
            // Finishes on its own: a new press meanwhile records alongside, and doesn't drop it.
            voice.finish { [weak self] transcript in
                self?.transcribed(press, transcript, assistant, changed: changed)
            }
        case .askThenType(let readiness):
            // Held without voice, released before the timer could open the typing box.
            VoiceCapture.askForPermission(readiness)
            openQuickAdd(assistant, voice: readiness)
        case .ignore:
            break
        }
    }

    /// A finished press's transcript. It touches the palette only while that press still owns it,
    /// so an earlier press never closes a newer press's Listening….
    private func transcribed(_ press: VoicePress, _ transcript: String, _ assistant: Assistant, changed: @escaping () -> Void) {
        switch presses.transcribed(press.id, transcript) {
        case .drop(let closePalette):
            // Nothing heard: nothing added, no Added panel.
            if closePalette { quickAdd.hideListening() }
        case .add(let showAdding):
            if showAdding { quickAdd.showAdding() }
            _Concurrency.Task {
                // Haiku splits it into Tasks and matches a Project named out loud; on any
                // failure it is one verbatim Task. Either way, unnamed means the Project
                // the palette showed when this press started.
                let added = try? await self.modelCalls?.voiceSplit.add(transcript, otherwise: press.project)
                if self.presses.added(press.id) { self.quickAdd.hideListening() }
                guard let added, !added.tasks.isEmpty else { return }
                self.showAdded(added.tasks, undoing: added.undoEntry, started: false, assistant, changed: changed)
            }
        }
    }

    /// The Added panel, whose Undo reverses `entry`: the one Operation that added `tasks`. With
    /// several (a split recording), Start starts the first.
    private func showAdded(
        _ tasks: [AssistantCore.Task], undoing entry: LogEntry.ID?, started: Bool, _ assistant: Assistant,
        changed: @escaping () -> Void
    ) {
        guard let first = tasks.first else { return }
        changed()
        let destination = Self.destination(first.project, in: assistant)
        let heading = started
            ? "Started “\(first.title)” · \(destination)"
            : tasks.count == 1 ? "Added “\(first.title)” · \(destination)" : "Added \(tasks.count) Tasks · \(destination)"
        added.show(
            heading, items: tasks.count == 1 ? [] : tasks.map(\.title), started: started,
            onStart: { Attempt.run("Couldn't start the Task", then: changed) { try assistant.commitTask(first.id, asInterruption: true) } },
            onUndo: { Attempt.run("Couldn't undo", then: changed) { if let entry { try assistant.undo(entry) } } })
    }

    /// The typing box; when a hold couldn't record, with a line saying why (or that macOS is asking).
    private func openQuickAdd(_ assistant: Assistant, voice readiness: VoiceReadiness = .ready) {
        quickAdd.show(destination: Self.destination(assistant.now.project, in: assistant), voiceNotice: readiness.notice)
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
EditMenu.install(in: app)
app.run()
