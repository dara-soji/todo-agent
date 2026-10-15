import AppKit
import AssistantCore

/// Suggestions ▸ in the dropdown: each one accepted or dismissed in one click, or opened in Gmail.
/// Also connecting Gmail to Dara's own Google OAuth client.
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
                Paste the client ID and secret of your own Google OAuth desktop client (see docs/adr/0003). \
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
