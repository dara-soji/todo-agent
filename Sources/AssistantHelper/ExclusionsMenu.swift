import AppKit
import AssistantCore

/// "Exclude <app/site>" under Now, and the Exclusions ▸ list. Adding runs at once; removing asks
/// Dara to confirm in the menu bar.
@MainActor
final class ExclusionsMenu: NSObject {
    private let assistant: Assistant
    var onChange: () -> Void = {}

    init(assistant: Assistant) {
        self.assistant = assistant
    }

    /// "Exclude <app/site>" for the window in front, unless it is Excluded already.
    func excludeItem() -> NSMenuItem? {
        guard let exclusion = assistant.exclusionToOffer else { return nil }
        let name = if case .app = exclusion { assistant.now.window?.app.name ?? exclusion.label } else { exclusion.label }
        return item("Exclude \(name)", #selector(exclude(_:)), exclusion)
    }

    func listItem() -> NSMenuItem {
        let root = NSMenuItem(title: "Exclusions", action: nil, keyEquivalent: "")
        let menu = NSMenu()
        menu.addItem(withTitle: "Always: private-browsing windows, password fields and prompts", action: nil, keyEquivalent: "")
            .isEnabled = false
        menu.addItem(.separator())
        for exclusion in assistant.exclusions {
            let entry = NSMenuItem(title: exclusion.label, action: nil, keyEquivalent: "")
            entry.submenu = NSMenu()
            entry.submenu?.addItem(item("Stop excluding (asks first)", #selector(remove(_:)), exclusion))
            menu.addItem(entry)
        }
        if !assistant.exclusions.isEmpty { menu.addItem(.separator()) }
        let add = NSMenuItem(title: "Exclude a sender or notes folder…", action: #selector(addOther), keyEquivalent: "")
        add.target = self
        menu.addItem(add)
        root.submenu = menu
        return root
    }

    private final class ExclusionBox: NSObject {
        let exclusion: Exclusion
        init(_ exclusion: Exclusion) { self.exclusion = exclusion }
    }

    private func item(_ title: String, _ selector: Selector, _ exclusion: Exclusion) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        item.representedObject = ExclusionBox(exclusion)
        return item
    }

    @objc private func exclude(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? ExclusionBox else { return }
        Attempt.run("Couldn't exclude it", then: onChange) { try assistant.exclude(box.exclusion) }
    }

    @objc private func remove(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? ExclusionBox else { return }
        Attempt.run("Couldn't stop excluding it", then: onChange) { try assistant.removeExclusion(box.exclusion) }
    }

    /// A sender ("you@bank.example" or "@bank.example") or "folder: Name".
    @objc private func addOther() {
        let alert = NSAlert()
        alert.messageText = "Exclude a sender or notes folder"
        alert.informativeText = "An email address, @domain for every address there, or folder: Name for an Apple Notes folder."
        alert.addButton(withTitle: "Exclude")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
        let exclusion: Exclusion = text.lowercased().hasPrefix("folder:")
            ? .notesFolder(String(text.dropFirst("folder:".count))) : .sender(text)
        Attempt.run("Couldn't exclude it", then: onChange) { try assistant.exclude(exclusion) }
    }
}
