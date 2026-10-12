import AppKit
import AssistantCore

/// The Projects ▸ submenu: declare, edit and archive Projects. Every change goes to the core.
@MainActor
final class ProjectsMenu: NSObject {
    private let assistant: Assistant
    private let changed: () -> Void

    init(assistant: Assistant, changed: @escaping () -> Void) {
        self.assistant = assistant
        self.changed = changed
    }

    func item() -> NSMenuItem {
        let root = NSMenuItem(title: "Projects", action: nil, keyEquivalent: "")
        let menu = NSMenu()
        menu.addItem(action("New Project…", #selector(newProject)))
        if !assistant.projects.isEmpty { menu.addItem(.separator()) }
        for project in assistant.projects {
            menu.addItem(projectItem(project))
        }
        root.submenu = menu
        return root
    }

    private func projectItem(_ project: Project) -> NSMenuItem {
        let title = project.status == .archived ? "\(project.name) (archived)" : project.name
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu()
        menu.addItem(action("Rename…", #selector(rename(_:)), project))
        menu.addItem(action("Add Matcher…", #selector(addMatcher(_:)), project))
        if !project.matchers.isEmpty {
            menu.addItem(.separator())
            menu.addItem(withTitle: "Remove Matcher", action: nil, keyEquivalent: "").isEnabled = false
            for matcher in project.matchers {
                let remove = action(matcher.pattern, #selector(removeMatcher(_:)), (project.id, matcher))
                remove.indentationLevel = 1
                menu.addItem(remove)
            }
        }
        menu.addItem(.separator())
        if project.status == .archived {
            menu.addItem(action("Restore", #selector(restore(_:)), project))
        } else {
            menu.addItem(action("Archive", #selector(archive(_:)), project))
        }
        item.submenu = menu
        return item
    }

    // MARK: Actions

    @objc private func newProject() {
        guard let answers = ask("New Project", fields: [
            ("Name", ""), ("Short name (optional)", ""),
            ("Matchers, one per line: a repo path (~/code/x) or a URL prefix (github.com/you/x)", ""),
        ]) else { return }
        let shortName = answers[1].isEmpty ? nil : answers[1]
        attempt { try assistant.declareProject(name: answers[0], shortName: shortName, matchers: Self.matchers(answers[2])) }
    }

    @objc private func rename(_ sender: NSMenuItem) {
        guard let project = sender.representedObject as? Project,
              let answers = ask("Rename \(project.name)", fields: [("Name", project.name), ("Short name", project.shortName)])
        else { return }
        attempt { try assistant.renameProject(project.id, name: answers[0], shortName: answers[1].isEmpty ? nil : answers[1]) }
    }

    @objc private func addMatcher(_ sender: NSMenuItem) {
        guard let project = sender.representedObject as? Project,
              let answers = ask("Add Matcher to \(project.name)", fields: [("Repo path or URL prefix", "")])
        else { return }
        attempt { for matcher in Self.matchers(answers[0]) { try assistant.addMatcher(matcher, to: project.id) } }
    }

    @objc private func removeMatcher(_ sender: NSMenuItem) {
        guard let (id, matcher) = sender.representedObject as? (Project.ID, Matcher) else { return }
        attempt { try assistant.removeMatcher(matcher, from: id) }
    }

    @objc private func archive(_ sender: NSMenuItem) {
        guard let project = sender.representedObject as? Project else { return }
        attempt { try assistant.archiveProject(project.id) }
    }

    @objc private func restore(_ sender: NSMenuItem) {
        guard let project = sender.representedObject as? Project else { return }
        attempt { try assistant.restoreProject(project.id) }
    }

    // MARK: Helpers

    /// A line starting with `~` or `/` is a repo path; anything else is a URL prefix.
    private static func matchers(_ text: String) -> [Matcher] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { $0.hasPrefix("~") || $0.hasPrefix("/") ? .repoPath($0) : .urlPrefix($0) }
    }

    private func attempt(_ change: () throws -> Void) {
        do {
            try change()
        } catch let invalid as Matcher.Invalid {
            let message = switch invalid {
            case let .bareDomain(prefix): "“\(prefix)” is a bare domain. Add a path, e.g. \(prefix)/your-project."
            case let .relativePath(path): "“\(path)” isn't a full path. Start it with ~/ or /."
            }
            alert(message)
        } catch {
            alert("\(error)")
        }
        changed()
    }

    private func alert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Couldn't save the Project"
        alert.informativeText = message
        NSApp.activate()
        alert.runModal()
    }

    /// A small form; nil when cancelled.
    private func ask(_ title: String, fields: [(label: String, value: String)]) -> [String]? {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        var inputs: [NSTextField] = []
        for field in fields {
            let label = NSTextField(wrappingLabelWithString: field.label)
            label.preferredMaxLayoutWidth = 320
            let input = NSTextField(string: field.value)
            input.widthAnchor.constraint(equalToConstant: 320).isActive = true
            if field.label.hasPrefix("Matchers") {
                input.heightAnchor.constraint(equalToConstant: 60).isActive = true
                input.usesSingleLineMode = false
                input.cell?.wraps = true
            }
            stack.addArrangedSubview(label)
            stack.addArrangedSubview(input)
            inputs.append(input)
        }
        stack.layoutSubtreeIfNeeded()
        stack.frame.size = stack.fittingSize
        alert.accessoryView = stack
        alert.window.initialFirstResponder = inputs.first
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return inputs.map { $0.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private func action(_ title: String, _ selector: Selector, _ object: Any? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        item.representedObject = object
        return item
    }
}
