import AppKit
import AssistantCore

/// The Projects ▸ submenu: declare, edit and archive Projects. Every change goes to the core.
@MainActor
final class ProjectsMenu: NSObject {
    private let assistant: Assistant
    /// Called after every attempted change, so the menu bar can redraw.
    var onChange: () -> Void = {}

    init(assistant: Assistant) {
        self.assistant = assistant
    }

    func item() -> NSMenuItem {
        let root = NSMenuItem(title: "Projects", action: nil, keyEquivalent: "")
        let menu = NSMenu()
        menu.addItem(menuItem("New Project…", #selector(newProject)))
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
        menu.addItem(menuItem("Rename…", #selector(rename(_:)), project))
        menu.addItem(menuItem("Add Matcher…", #selector(addMatcher(_:)), project))
        if !project.matchers.isEmpty {
            menu.addItem(.separator())
            menu.addItem(withTitle: "Remove Matcher", action: nil, keyEquivalent: "").isEnabled = false
            for matcher in project.matchers {
                let remove = menuItem(MatcherText.format(matcher), #selector(removeMatcher(_:)), (project.id, matcher))
                remove.indentationLevel = 1
                menu.addItem(remove)
            }
        }
        menu.addItem(.separator())
        if project.status == .archived {
            menu.addItem(menuItem("Restore", #selector(restore(_:)), project))
        } else {
            menu.addItem(menuItem("Archive", #selector(archive(_:)), project))
        }
        item.submenu = menu
        return item
    }

    // MARK: Menu handlers

    @objc private func newProject() {
        guard let answers = ask("New Project", fields: [
            ("Name", ""), ("Short name (optional)", ""),
            ("Matchers, separated by commas: a repo path (~/code/x), a URL prefix (github.com/you/x) or a calendar keyword (calendar: standup)", ""),
        ]) else { return }
        let shortName = answers[1].isEmpty ? nil : answers[1]
        attempt { try assistant.declareProject(name: answers[0], shortName: shortName, matchers: MatcherText.parse(answers[2])) }
    }

    @objc private func rename(_ sender: NSMenuItem) {
        guard let project = sender.representedObject as? Project,
              let answers = ask("Rename \(project.name)", fields: [("Name", project.name), ("Short name", project.shortName)])
        else { return }
        attempt { try assistant.renameProject(project.id, name: answers[0], shortName: answers[1].isEmpty ? nil : answers[1]) }
    }

    @objc private func addMatcher(_ sender: NSMenuItem) {
        guard let project = sender.representedObject as? Project,
              let answers = ask("Add Matcher to \(project.name)", fields: [("Repo paths, URL prefixes or calendar keywords (calendar: standup), separated by commas", "")])
        else { return }
        attempt { try assistant.addMatchers(MatcherText.parse(answers[0]), to: project.id) }
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

    private func attempt(_ change: () throws -> Void) {
        Attempt.run("Couldn't save the Project", explaining: Self.explain, then: onChange, change)
    }

    private static func explain(_ error: Error) -> String {
        switch error {
        case Matcher.Invalid.bareDomain(let prefix): "“\(prefix)” is a bare domain. Add a path, e.g. \(prefix)/your-project."
        case Matcher.Invalid.relativePath(let path): "“\(path)” isn't a full path. Start it with ~/ or /."
        case Matcher.Invalid.shortKeyword(let keyword): "“\(keyword)” is too short for a calendar keyword."
        case Assistant.Failure.emptyName: "A Project needs a name."
        default: "\(error)"
        }
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

    private func menuItem(_ title: String, _ selector: Selector, _ object: Any? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        item.representedObject = object
        return item
    }
}
