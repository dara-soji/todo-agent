import AppKit
import AssistantCore
import ServiceManagement

/// The menu-bar item and its dropdown. Renders the core's MenuBar as-is; holds no domain logic.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var menuBar: MenuBar?
    private let storeProblem: String?

    init(storeProblem: String?) {
        self.storeProblem = storeProblem
        super.init()
        menu.delegate = self
        statusItem.menu = menu
    }

    func render(_ menuBar: MenuBar) {
        guard menuBar != self.menuBar else { return }
        self.menuBar = menuBar
        statusItem.button?.attributedTitle = NSAttributedString(string: menuBar.title, attributes: [
            .font: Theme.mono(12), .kern: 0.6,
        ])
    }

    // Built when opened so it always reflects the latest state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        menu.addItem(header("Now"))
        menu.addItem(detail(menuBar?.nowDetail ?? "—"))

        if !FocusSensor.hasAccessibility {
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
        item.attributedTitle = Theme.label(text)
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
