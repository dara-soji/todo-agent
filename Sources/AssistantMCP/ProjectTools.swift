import AssistantCore
import Foundation
import MCP

extension ToolCatalog {
    // MARK: Suggestions and the Digest

    static let suggestionTools: [Spec] = [
        Spec(name: "list_suggestions",
             description: "Suggestions waiting for Dara: Tasks proposed from email, Sheets and Notes. Accepting one makes it a Task.",
             input: object([:]), output: output(["suggestions": list]), kind: .read) { assistant, _ in
            ["suggestions": .array(assistant.suggestions.map(Shapes.suggestion))]
        },
        Spec(name: "get_digest",
             description: "Worth-knowing email, newest first: sender, subject and why. No bodies.",
             input: object([:]), output: output(["lines": list]), kind: .read) { assistant, _ in
            ["lines": .array(assistant.digest.map(Shapes.digestLine))]
        },
        Spec(name: "accept_suggestion", description: "Accept a Suggestion: it becomes a Task, with its guessed deadline.",
             input: object(["suggestion_id": uuid], required: ["suggestion_id"]),
             output: operationResult, kind: .operation(.acceptSuggestion)) { assistant, args in
            let id = try suggestionID(args)
            let outcome = try assistant.acceptSuggestion(id, by: .claudeCode)
            return result(assistant, outcome, task: assistant.task(acceptedFrom: id)?.id)
        },
        Spec(name: "dismiss_suggestion",
             description: "Dismiss a Suggestion. With never_from_sender, only if Dara said so: that sender's mail is Noise from now on.",
             input: object(["suggestion_id": uuid, "never_from_sender": boolean], required: ["suggestion_id"]),
             output: operationResult, kind: .operation(.dismissSuggestion)) { assistant, args in
            let outcome = try assistant.dismissSuggestion(
                try suggestionID(args), neverFromSender: try args.bool("never_from_sender") ?? false, by: .claudeCode)
            return result(assistant, outcome, task: nil)
        },
    ]

    private static func suggestionID(_ args: Arguments) throws -> Suggestion.ID {
        guard let text = try args.string("suggestion_id"), let uuid = UUID(uuidString: text) else {
            throw ToolError("suggestion_id must be a UUID.")
        }
        return Suggestion.ID(uuid)
    }

    // MARK: Projects and Matchers

    /// Whether Dara asked for the change in this conversation (Auto) or the assistant is proposing
    /// it (Ask: Dara confirms in the menu bar). Required on every Project tool.
    private static let daraAsked: Value = [
        "type": "boolean",
        "description": "True only if Dara explicitly asked for this change. False when you are proposing it: it then waits for Dara to confirm in the menu bar.",
    ]

    private static let matcherSchema: Value = [
        "type": "array",
        "items": object([
            "kind": enumeration(["repoPath", "urlPrefix", "calendarKeyword", "sheetID"]),
            "pattern": ["type": "string"],
        ], required: ["kind", "pattern"]),
    ]

    private static let projectResult = output([
        "status": enumeration(["ran", "pending"]), "project": nullableObject, "log_entry": nullableObject,
        "ask_id": nullableString, "expires_at": nullableString,
    ])

    static let projectTools: [Spec] = [
        Spec(name: "declare_project",
             description: "Declare a Project with its Matchers (repo path, URL prefix, calendar keyword or Sheet id).",
             input: object(["name": ["type": "string"], "short_name": ["type": "string"], "matchers": matcherSchema,
                            "dara_asked": daraAsked], required: ["name", "dara_asked"]),
             output: projectResult, kind: .operation(.declareProject)) { assistant, args in
            let name = try args.string("name") ?? ""
            let matchers = try matchers(args)
            let short = try args.string("short_name")
            if try requireDaraAsked(args) {
                let project = try assistant.declareProject(name: name, shortName: short, matchers: matchers, by: .claudeCode)
                return projectResult(assistant, .ran(assistant.operationLog.last!.id), project.id)
            }
            let proposed = try assistant.declareProjectProposed(name: name, shortName: short, matchers: matchers, by: .claudeCode)
            return projectResult(assistant, proposed.outcome, nil)
        },
        projectOperation("rename_project", "Rename a Project.", .editProject,
                         extra: ["name": ["type": "string"], "short_name": ["type": "string"]], required: ["name"]) { assistant, id, args, proposed in
            try assistant.renameProject(id, name: try args.string("name") ?? "", shortName: try args.string("short_name"),
                                        by: .claudeCode, proposed: proposed)
        },
        projectOperation("add_matchers", "Add Matchers to a Project.", .editProject,
                         extra: ["matchers": matcherSchema], required: ["matchers"]) { assistant, id, args, proposed in
            try assistant.addMatchers(try matchers(args), to: id, by: .claudeCode, proposed: proposed)
        },
        projectOperation("remove_matcher", "Remove one Matcher from a Project.", .editProject,
                         extra: ["kind": enumeration(["repoPath", "urlPrefix", "calendarKeyword", "sheetID"]),
                                 "pattern": ["type": "string"]], required: ["kind", "pattern"]) { assistant, id, args, proposed in
            guard let kind = try args.string("kind").flatMap(Matcher.Kind.init), let pattern = try args.string("pattern") else {
                throw ToolError("Give kind and pattern.")
            }
            return try assistant.removeMatcher(Matcher(kind: kind, pattern: pattern), from: id, by: .claudeCode, proposed: proposed)
        },
        projectOperation("archive_project", "Archive a Project: it matches nothing until restored.", .archiveProject) { assistant, id, _, proposed in
            try assistant.archiveProject(id, by: .claudeCode, proposed: proposed)
        },
        projectOperation("restore_project", "Restore an archived Project.", .restoreProject) { assistant, id, _, proposed in
            try assistant.restoreProject(id, by: .claudeCode, proposed: proposed)
        },
    ]

    /// A tool that runs one Operation on one Project, named by project_id.
    private static func projectOperation(
        _ name: String, _ description: String, _ kind: OperationKind, extra: [String: Value] = [:], required: [String] = [],
        _ operation: @escaping @MainActor (Assistant, Project.ID, Arguments, Bool) throws -> Outcome
    ) -> Spec {
        Spec(name: name, description: description,
             input: object(extra.merging(["project_id": uuid, "dara_asked": daraAsked]) { a, _ in a },
                           required: ["project_id", "dara_asked"] + required),
             output: projectResult, kind: .operation(kind)) { assistant, args in
            guard let id = try args.projectID("project_id") else { throw ToolError("project_id must be a UUID.") }
            let proposed = !(try requireDaraAsked(args))
            return projectResult(assistant, try operation(assistant, id, args, proposed), id)
        }
    }

    private static func requireDaraAsked(_ args: Arguments) throws -> Bool {
        guard let asked = try args.bool("dara_asked") else { throw ToolError("Give dara_asked: true or false.") }
        return asked
    }

    private static func matchers(_ args: Arguments) throws -> [Matcher] {
        guard let list = args.values["matchers"], list != Value.null else { return [] }
        guard let items = list.arrayValue else { throw ToolError("matchers must be a list.") }
        return try items.map { item in
            guard let kind = item.objectValue?["kind"]?.stringValue.flatMap(Matcher.Kind.init),
                  let pattern = item.objectValue?["pattern"]?.stringValue
            else { throw ToolError("Each Matcher needs a kind and a pattern.") }
            return Matcher(kind: kind, pattern: pattern)
        }
    }

    private static func projectResult(_ assistant: Assistant, _ outcome: Outcome, _ id: Project.ID?) -> Value {
        let project = id.flatMap(assistant.project).map(Shapes.project) ?? .null
        switch outcome {
        case let .pending(askID):
            let ask = assistant.asks.first { $0.id == askID }
            return ["status": "pending", "project": project, "log_entry": .null,
                    "ask_id": .string(askID.rawValue.uuidString), "expires_at": ask.map { Shapes.date($0.expires) } ?? .null]
        case let .ran(entryID):
            let entry = assistant.operationLog.last { $0.id == entryID }
            return ["status": "ran", "project": project, "log_entry": entry.map(Shapes.logEntry) ?? .null,
                    "ask_id": .null, "expires_at": .null]
        }
    }
}
