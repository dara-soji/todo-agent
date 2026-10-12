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

    init(showing menuBar: MenuBar, storeProblem: String?) {
        self.menuBar = menuBar
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
        statusItem.button?.attributedTitle = NSAttributedString(string: menuBar.title, attributes: [
            .font: Theme.mono(12), .kern: 0.6,
        ])
    }

    // Built when opened so it always reflects the latest state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        menu.addItem(header("Now"))
        menu.addItem(detail(menuBar.nowDetail))

        if !ActiveWindowSensor.hasAccessibility {
            menu.addItem(.separator())
            menu.addItem(action("Allow Accessibility to read window titles…", #selector(openAccessibilitySettings)))
        }
        if let storeProblem {
            menu.addItem(.separator())
            menu.addItem(detail("Store unavailable: \(storeProblem)"))
        }

        menu.addItem(.separator())
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

    private func action(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        return item
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
