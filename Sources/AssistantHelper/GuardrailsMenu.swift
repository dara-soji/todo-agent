import AppKit
import AssistantCore

/// The Guardrails ▸ submenu: Dara makes any Operation ask first, or lets an Ask Operation run
/// without asking, everywhere or for one Project. Never can't be chosen; every change is logged.
@MainActor
final class GuardrailsMenu: NSObject {
    private let assistant: Assistant
    var onChange: () -> Void = {}

    init(assistant: Assistant) {
        self.assistant = assistant
    }

    private static let names: [OperationKind: String] = [
        .addTask: "Add a Task", .editTask: "Edit a Task",
        .bulkEditTasks: "Edit more than \(Guardrail.bulkEditAsksAbove) Tasks",
        .commitTask: "Start a Task", .completeTask: "Mark a Task done", .snoozeTask: "Snooze a Task",
        .dropTask: "Drop a Task", .deleteTask: "Delete a Task", .restoreTask: "Restore a Task",
        .skipTask: "Skip Next", .keepTask: "Keep a skipped Task", .declareProject: "Declare a Project",
        .editProject: "Edit a Project", .archiveProject: "Archive a Project", .restoreProject: "Restore a Project",
        .undo: "Undo", .markNeutral: "Treat an app or site as Neutral",
        .removeExclusion: "Stop excluding something",
        .acceptSuggestion: "Accept a Suggestion", .dismissSuggestion: "Dismiss a Suggestion",
        .promoteDigestLine: "Make a Digest line a Suggestion", .addVIP: "Add a VIP", .removeVIP: "Remove a VIP",
    ]

    func item() -> NSMenuItem {
        let root = NSMenuItem(title: "Guardrails", action: nil, keyEquivalent: "")
        let menu = NSMenu()
        for kind in OperationKind.allCases where Guardrail.canTighten(kind) {
            menu.addItem(kindItem(kind))
        }
        root.submenu = menu
        return root
    }

    private func kindItem(_ kind: OperationKind) -> NSMenuItem {
        let rules = assistant.guardrailRules.filter { $0.kind == kind }
        let scoped = rules.isEmpty ? "" : " (\(rules.count) rule\(rules.count == 1 ? "" : "s"))"
        let title = "\(Self.names[kind] ?? kind.rawValue) — \(label(assistant.tier(for: kind)))\(scoped)"
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu()
        // Ask first is offered only where it would change something.
        if assistant.tier(for: kind) != .ask {
            menu.addItem(choice("Ask first", .tighten, kind, nil))
            menu.addItem(projectChoices("Ask first in", .tighten, kind))
        }
        if Guardrail.canLoosen(kind) {
            menu.addItem(choice("Run without asking", .loosen, kind, nil))
            menu.addItem(projectChoices("Run without asking in", .loosen, kind))
        }
        if !rules.isEmpty {
            menu.addItem(.separator())
            for rule in rules {
                let scope = rule.project.flatMap(assistant.project).map { " in \($0.name)" } ?? ""
                menu.addItem(choice("Back to default\(scope)", .reset, kind, rule.project))
            }
        }
        item.submenu = menu
        return item
    }

    private func projectChoices(_ title: String, _ change: RuleChange, _ kind: OperationKind) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu()
        let projects = assistant.projects.filter { $0.status == .active }
        if projects.isEmpty { menu.addItem(withTitle: "No Projects", action: nil, keyEquivalent: "").isEnabled = false }
        for project in projects {
            menu.addItem(choice(project.name, change, kind, project.id))
        }
        item.submenu = menu
        return item
    }

    private func label(_ tier: Tier) -> String {
        switch tier {
        case .auto: "runs without asking"
        case .ask: "asks first"
        case .never: "never"
        }
    }

    // MARK: Menu handlers

    private enum RuleChange { case tighten, loosen, reset }

    private struct Choice {
        let change: RuleChange
        let kind: OperationKind
        let project: Project.ID?
    }

    private func choice(_ title: String, _ change: RuleChange, _ kind: OperationKind, _ project: Project.ID?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(choose(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = Choice(change: change, kind: kind, project: project)
        return item
    }

    @objc private func choose(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? Choice else { return }
        Attempt.run("Couldn't change the Guardrail", then: onChange) {
            switch choice.change {
            case .tighten: try assistant.tighten(choice.kind, in: choice.project)
            case .loosen: try assistant.loosen(choice.kind, in: choice.project)
            case .reset: try assistant.resetTier(choice.kind, in: choice.project)
            }
        }
    }
}
