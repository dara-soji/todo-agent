import AppKit
import AssistantCore

/// Suggestions ▸ and Worth knowing ▸ in the dropdown: a Suggestion accepted or dismissed in one
/// click, a Digest line made a Suggestion in one click, either opened in Gmail. Also the VIP list,
/// and connecting Gmail to Dara's own Google OAuth client.
@MainActor
final class SuggestionsMenu: NSObject {
    private let assistant: Assistant
    private let mail: MailTriage
    var onChange: () -> Void = {}

    init(assistant: Assistant, mail: MailTriage) {
        self.assistant = assistant
        self.mail = mail
    }

    func item() -> NSMenuItem? {
        let suggestions = assistant.suggestions
        guard !suggestions.isEmpty else { return nil }
        let root = NSMenuItem(title: "Suggestions (\(suggestions.count))", action: nil, keyEquivalent: "")
        let menu = NSMenu()
        for suggestion in suggestions {
            let entry = NSMenuItem(title: Self.label(suggestion), action: nil, keyEquivalent: "")
            entry.toolTip = suggestion.reason
            let actions = NSMenu()
            actions.addItem(action("Accept", #selector(accept(_:)), suggestion))
            actions.addItem(action("Dismiss", #selector(dismiss(_:)), suggestion))
            actions.addItem(action("Open in Gmail", #selector(open(_:)), suggestion))
            entry.submenu = actions
            menu.addItem(entry)
        }
        root.submenu = menu
        return root
    }

    /// The Digest: at most five Worth-knowing lines, newest first.
    func digestItem() -> NSMenuItem? {
        let lines = assistant.digest
        guard !lines.isEmpty else { return nil }
        let root = NSMenuItem(title: "Worth knowing (\(lines.count))", action: nil, keyEquivalent: "")
        let menu = NSMenu()
        for line in lines {
            let entry = NSMenuItem(title: "\(Self.name(line.from)) — \(line.subject)", action: nil, keyEquivalent: "")
            entry.toolTip = line.reason
            let actions = NSMenu()
            actions.addItem(lineAction("Make a Suggestion", #selector(promote(_:)), line))
            actions.addItem(lineAction("Open in Gmail", #selector(openLine(_:)), line))
            entry.submenu = actions
            menu.addItem(entry)
        }
        root.submenu = menu
        return root
    }

    /// VIPs ▸: Dara's list, plus a note that recent recipients count too.
    func vipsItem() -> NSMenuItem {
        let root = NSMenuItem(title: "VIPs", action: nil, keyEquivalent: "")
        let menu = NSMenu()
        menu.addItem(withTitle: "Also: anyone you emailed in the last 90 days", action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(.separator())
        for vip in assistant.vips {
            let entry = NSMenuItem(title: vip, action: nil, keyEquivalent: "")
            entry.submenu = NSMenu()
            let remove = NSMenuItem(title: "Remove", action: #selector(removeVIP(_:)), keyEquivalent: "")
            remove.target = self
            remove.representedObject = vip
            entry.submenu?.addItem(remove)
            menu.addItem(entry)
        }
        if !assistant.vips.isEmpty { menu.addItem(.separator()) }
        let add = NSMenuItem(title: "Add a VIP…", action: #selector(addVIP), keyEquivalent: "")
        add.target = self
        menu.addItem(add)
        root.submenu = menu
        return root
    }

    /// "Sam" from "Sam <sam@work.example>", else the address.
    static func name(_ from: String) -> String {
        guard let open = from.firstIndex(of: "<") else { return from }
        let name = from[..<open].trimmingCharacters(in: CharacterSet(charactersIn: " \""))
        return name.isEmpty ? from : name
    }

    /// "Connect Gmail…", or the connected state with a way out.
    func connectionItem() -> NSMenuItem {
        guard mail.auth.isConnected else {
            let item = NSMenuItem(title: "Connect Gmail…", action: #selector(connect), keyEquivalent: "")
            item.target = self
            return item
        }
        let root = NSMenuItem(title: "Gmail: connected (read-only)", action: nil, keyEquivalent: "")
        root.submenu = NSMenu()
        let disconnect = NSMenuItem(title: "Disconnect Gmail", action: #selector(disconnect), keyEquivalent: "")
        disconnect.target = self
        root.submenu?.addItem(disconnect)
        return root
    }

    /// "Send Sam the invoice · Fri 17:00 (guessed)".
    static func label(_ suggestion: Suggestion) -> String {
        guard let deadline = suggestion.guessedDeadline else { return suggestion.title }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE HH:mm"
        return "\(suggestion.title) · \(formatter.string(from: deadline)) (guessed)"
    }

    private final class SuggestionBox: NSObject {
        let suggestion: Suggestion
        init(_ suggestion: Suggestion) { self.suggestion = suggestion }
    }

    private func action(_ title: String, _ selector: Selector, _ suggestion: Suggestion) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        item.representedObject = SuggestionBox(suggestion)
        return item
    }

    private final class LineBox: NSObject {
        let line: DigestLine
        init(_ line: DigestLine) { self.line = line }
    }

    private func lineAction(_ title: String, _ selector: Selector, _ line: DigestLine) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        item.representedObject = LineBox(line)
        return item
    }

    @objc private func promote(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? LineBox else { return }
        Attempt.run("Couldn't make it a Suggestion", then: onChange) { try assistant.promoteDigestLine(box.line.threadID) }
    }

    @objc private func openLine(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? LineBox, let url = URL(string: box.line.backLink) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func removeVIP(_ sender: NSMenuItem) {
        guard let vip = sender.representedObject as? String else { return }
        Attempt.run("Couldn't remove the VIP", then: onChange) { try assistant.removeVIP(vip) }
    }

    @objc private func addVIP() {
        let alert = NSAlert()
        alert.messageText = "Add a VIP"
        alert.informativeText = "An email address, or @domain for everyone there. Their mail skips the bulk-mail rules but is still triaged."
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let text = field.stringValue
        Attempt.run("Couldn't add the VIP", then: onChange) { try assistant.addVIP(text) }
    }

    @objc private func accept(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? SuggestionBox else { return }
        Attempt.run("Couldn't accept it", then: onChange) { try assistant.acceptSuggestion(box.suggestion.id) }
    }

    @objc private func dismiss(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? SuggestionBox else { return }
        Attempt.run("Couldn't dismiss it", then: onChange) { try assistant.dismissSuggestion(box.suggestion.id) }
    }

    @objc private func open(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? SuggestionBox, let url = URL(string: box.suggestion.backLink) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Dara pastes their own desktop client's id and secret, then signs in in the browser.
    @objc private func connect() {
        if mail.auth.client == nil {
            let alert = NSAlert()
            alert.messageText = "Connect Gmail"
            alert.informativeText = """
                Paste the client ID and secret of your own Google Cloud OAuth client (type: Desktop app). \
                TodoAgent asks only to read Gmail. Both are kept in your Keychain.
                """
            alert.addButton(withTitle: "Continue")
            alert.addButton(withTitle: "Cancel")
            let id = NSTextField(frame: NSRect(x: 0, y: 30, width: 320, height: 24))
            id.placeholderString = "Client ID"
            let secret = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
            secret.placeholderString = "Client secret"
            let fields = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 54))
            fields.addSubview(id)
            fields.addSubview(secret)
            alert.accessoryView = fields
            alert.window.initialFirstResponder = id
            NSApp.activate()
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let client = GoogleAuth.Client(
                id: id.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                secret: secret.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
            guard !client.id.isEmpty, !client.secret.isEmpty else { return }
            var saved = false
            Attempt.run("Couldn't save the client", then: {}) {
                try mail.auth.saveClient(client)
                saved = true
            }
            guard saved else { return }
        }
        _Concurrency.Task {
            do {
                try await mail.auth.signIn()
                mail.check()
            } catch {
                Attempt.run("Couldn't connect Gmail", then: onChange) { throw error }
            }
            onChange()
        }
    }

    @objc private func disconnect() {
        mail.auth.disconnect()
        onChange()
    }
}
