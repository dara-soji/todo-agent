import AppKit
import AssistantCore
import ServiceManagement

/// The menu-bar item and its dropdown. Renders the core's MenuBar as-is; holds no domain logic.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var menuBar: MenuBar
    private let storeProblem: String?
    private let projectsMenu: ProjectsMenu
    private let tasksMenu: TasksMenu
    private let guardrailsMenu: GuardrailsMenu
    private let nowMenu: NowMenu
    private let exclusionsMenu: ExclusionsMenu
    private let suggestionsMenu: SuggestionsMenu
    /// Opens the quick-add palette.
    var onAddTask: () -> Void = {}
    /// Whether Claude Code can connect, for the Connect Claude Code item.
    var claudeCode: ClaudeCodeConnection.State = .starting
    /// Today's API spend, from the audit log.
    var currentSpend: () -> Double = { 0 }
    /// The latest state, read whenever the dropdown opens: Next can change with time alone.
    var currentMenuBar: () -> MenuBar = { fatalError("set currentMenuBar before the menu opens") }

    init(showing menuBar: MenuBar, projectsMenu: ProjectsMenu, tasksMenu: TasksMenu, guardrailsMenu: GuardrailsMenu,
         nowMenu: NowMenu, exclusionsMenu: ExclusionsMenu, suggestionsMenu: SuggestionsMenu, storeProblem: String?) {
        self.menuBar = menuBar
        self.suggestionsMenu = suggestionsMenu
        self.nowMenu = nowMenu
        self.exclusionsMenu = exclusionsMenu
        self.projectsMenu = projectsMenu
        self.tasksMenu = tasksMenu
        self.guardrailsMenu = guardrailsMenu
        self.storeProblem = storeProblem
        super.init()
        menu.delegate = self
        statusItem.menu = menu
        drawTitle()
    }

    func render(_ menuBar: MenuBar) {
        guard menuBar != self.menuBar else { return }
        self.menuBar = menuBar
        drawTitle()
    }

    private func drawTitle() {
        let title = NSMutableAttributedString()
        var text: [NSAttributedString.Key: Any] = [.font: Theme.mono(12), .kern: 0.6]
        switch menuBar.marker {
        case .project:
            title.append(NSAttributedString(string: "■ ", attributes: [.foregroundColor: Theme.accent, .font: Theme.mono(11)]))
        case .guess:
            // Hollow dashed dot: a guess, not a match.
            title.append(NSAttributedString(string: "◌ ", attributes: [.foregroundColor: Theme.accent, .font: Theme.mono(11)]))
        case .noProject, .away:
            text[.foregroundColor] = Theme.steel
        case .unknown:
            break
        }
        title.append(NSAttributedString(string: menuBar.title, attributes: text))
        if menuBar.drifting {
            title.append(NSAttributedString(string: " ▲", attributes: [.foregroundColor: Theme.accent, .font: Theme.mono(9)]))
        }
        if menuBar.decisionsWaiting {
            title.append(NSAttributedString(string: " ●", attributes: [.foregroundColor: Theme.accent, .font: Theme.mono(9)]))
        }
        statusItem.button?.attributedTitle = title
    }

    // Built when opened so it always reflects the latest state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        render(currentMenuBar())

        let decisions = tasksMenu.decisionItems()
        if !decisions.isEmpty {
            decisions.forEach(menu.addItem)
            menu.addItem(.separator())
        }

        menu.addItem(header("Now"))
        if let committed = menuBar.committedTaskTitle { menu.addItem(detail(committed)) }
        menu.addItem(metadata(menuBar.nowDetail))
        if let evidence = menuBar.evidence { menu.addItem(metadata(evidence)) }
        if let window = menuBar.window { menu.addItem(metadata(window)) }
        if let markDone = tasksMenu.markDoneItem() { menu.addItem(markDone) }
        nowMenu.items().forEach(menu.addItem)
        if let exclude = exclusionsMenu.excludeItem() { menu.addItem(exclude) }

        menu.addItem(.separator())
        menu.addItem(header("Next"))
        menu.addItem(nextTitle(menuBar.nextTitle))
        if let reason = menuBar.nextReason { menu.addItem(metadata(reason)) }
        tasksMenu.nextItems().forEach(menu.addItem)
        if let suggestions = suggestionsMenu.item() { menu.addItem(suggestions) }
        if let digest = suggestionsMenu.digestItem() { menu.addItem(digest) }

        menu.addItem(.separator())
        let addTask = action("Add task…", #selector(addTask))
        addTask.keyEquivalent = " "
        addTask.keyEquivalentModifierMask = .option
        menu.addItem(addTask)
        menu.addItem(tasksMenu.tasksItem())
        if let deleted = tasksMenu.deletedItem() { menu.addItem(deleted) }
        menu.addItem(projectsMenu.item())
        menu.addItem(guardrailsMenu.item())
        menu.addItem(exclusionsMenu.listItem())
        menu.addItem(suggestionsMenu.vipsItem())
        menu.addItem(suggestionsMenu.sheetsItem())

        let permissions = [
            ActiveWindowSensor.hasAccessibility ? nil
                : action("Allow Accessibility to read window titles…", #selector(openAccessibilitySettings)),
            CalendarSensor.hasAccess ? nil
                : action("Allow Calendar access to match meetings…", #selector(openCalendarSettings)),
            suggestionsMenu.notesPermissionItem(),
        ].compactMap { $0 }
        if !permissions.isEmpty {
            menu.addItem(.separator())
            permissions.forEach(menu.addItem)
        }
        if let storeProblem {
            menu.addItem(.separator())
            menu.addItem(detail("Store unavailable: \(storeProblem)"))
        }

        menu.addItem(.separator())
        switch claudeCode {
        case .starting:
            menu.addItem(withTitle: "Claude Code: starting…", action: nil, keyEquivalent: "").isEnabled = false
        case .ready:
            menu.addItem(action("Connect Claude Code…", #selector(connectClaudeCode)))
        case let .unavailable(reason):
            menu.addItem(detail("Claude Code unavailable: \(reason)"))
        }
        menu.addItem(action(ClaudeAPIKey.load() == nil ? "Set Claude API key…" : "Replace Claude API key…",
                            #selector(setAPIKey)))
        if storeProblem == nil { menu.addItem(suggestionsMenu.connectionItem()) }
        menu.addItem(metadata(String(format: "Claude API today: $%.4f", currentSpend())))
        let login = action("Open at Login", #selector(toggleLoginItem))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(action("Quit", #selector(quit), key: "q"))
    }

    private func header(_ text: String) -> NSMenuItem {
        let item = NSMenuItem()
        item.attributedTitle = Theme.label(text, color: Theme.accent)
        item.isEnabled = false
        return item
    }

    private func detail(_ text: String) -> NSMenuItem {
        let item = NSMenuItem()
        item.attributedTitle = NSAttributedString(string: text, attributes: [.font: Theme.display(13)])
        item.isEnabled = false
        return item
    }

    private func nextTitle(_ text: String) -> NSMenuItem {
        let item = NSMenuItem()
        item.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: Theme.display(13), .foregroundColor: Theme.accent,
        ])
        item.isEnabled = false
        return item
    }

    private func metadata(_ text: String) -> NSMenuItem {
        let item = NSMenuItem()
        item.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: Theme.mono(11), .foregroundColor: Theme.steel,
        ])
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        return item
    }

    /// Dara types the key into a secure field; it goes straight to the Keychain.
    @objc private func setAPIKey() {
        let alert = NSAlert()
        alert.messageText = "Claude API key"
        alert.informativeText = "Used for the occasional screenshot guess, breaking ties for Next, and email Triage. Kept in your Keychain."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        Attempt.run("Couldn't save the key", then: {}) { try ClaudeAPIKey.save(key) }
    }

    @objc private func connectClaudeCode() {
        if case let .ready(command) = claudeCode { ClaudeCodeConnection.offer(command) }
    }

    @objc private func addTask() {
        onAddTask()
    }

    @objc private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    /// Registers the bundled helper as a login item the first time it runs, so it is always on.
    /// Later launches respect Dara's choice in the menu.
    static func registerLoginItemOnFirstLaunch() {
        let key = "loginItemOffered"
        guard Bundle.main.bundleIdentifier != nil, !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        try? SMAppService.mainApp.register()
    }

    @objc private func openCalendarSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!
        NSWorkspace.shared.open(url)
    }

    @objc private func toggleLoginItem() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change Open at Login"
            alert.informativeText = "\(error.localizedDescription)\n\nOpen at Login needs the bundled app (scripts/build-app.sh), not `swift run`."
            alert.runModal()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
