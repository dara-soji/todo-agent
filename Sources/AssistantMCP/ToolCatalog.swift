import AssistantCore
import Foundation
import MCP

/// Every tool the helper offers Claude Code, each with its schemas and what it runs. This list is
/// the contract between the two parts: whatever can be done to Tasks from conversation must exist
/// here (ADR 0001).
@MainActor
enum ToolCatalog {
    enum Kind {
        /// Reads state; changes nothing.
        case read
        /// Runs an Operation through the Guardrail; declares that Operation's tier.
        case operation(OperationKind)
        /// Like `operation`, but asks when `dara_asked` is false: the assistant proposing it.
        case proposable(OperationKind)
    }

    struct Spec {
        let name: String
        let description: String
        let input: Value
        let output: Value
        let kind: Kind
        let run: @MainActor (Assistant, Arguments) throws -> Value
    }

    static func spec(named name: String) -> Spec? {
        specs.first { $0.name == name }
    }

    /// The tools as MCP lists them. Each Operation tool declares the tier the Guardrail gives it.
    static func tools(tier: (OperationKind) -> Tier) -> [Tool] {
        specs.map { spec in
            switch spec.kind {
            case .read:
                Tool(name: spec.name, description: spec.description, inputSchema: spec.input,
                     annotations: .init(readOnlyHint: true), outputSchema: spec.output)
            case let .operation(kind):
                Tool(name: spec.name, description: spec.description, inputSchema: spec.input,
                     annotations: .init(readOnlyHint: false, destructiveHint: false, openWorldHint: false),
                     outputSchema: spec.output,
                     _meta: Metadata(additionalFields: ["tier": .string(tier(kind).rawValue)]))
            case let .proposable(kind):
                Tool(name: spec.name, description: spec.description, inputSchema: spec.input,
                     annotations: .init(readOnlyHint: false, destructiveHint: false, openWorldHint: false),
                     outputSchema: spec.output,
                     _meta: Metadata(additionalFields: [
                         "tier": .string(tier(kind).rawValue),
                         "tier_when_proposed": .string(tier(kind) == .never ? Tier.never.rawValue : Tier.ask.rawValue),
                     ]))
            }
        }
    }

    static let specs: [Spec] = reads + operations + suggestionTools + projectTools

    // MARK: Reads

    private static let reads: [Spec] = [
        Spec(name: "get_now",
             description: "What Dara is doing now: the Project Now matched and why, the app, and the Committed Task. Window titles and URLs stay on the Mac.",
             input: object([:]),
             output: output(["project": nullableObject, "basis": nullableString, "evidence": nullableString,
                             "app": nullableString, "since": nullableString, "away": boolean, "excluded": boolean,
                             "committed_task": nullableObject]),
             kind: .read) { assistant, _ in
            let now = assistant.now
            return [
                "project": now.project.flatMap(assistant.project).map(Shapes.project) ?? .null,
                "basis": now.match.map { .string(Shapes.basis($0.basis)) } ?? .null,
                "evidence": now.evidence.map { .string($0.pattern) } ?? .null,
                "app": now.window.map { .string($0.app.name) } ?? .null,
                "since": now.since.map(Shapes.date) ?? .null,
                "away": .bool(now.isAway),
                "excluded": .bool(now.window?.isExcluded == true),
                "committed_task": assistant.committedTask.map(Shapes.task) ?? .null,
            ]
        },
        Spec(name: "get_next", description: "The one Task the assistant recommends after Now, with its one-line reason.",
             input: object([:]),
             output: output(["task": nullableObject, "reason": nullableString, "wont_fit_before": nullableString,
                             "plan_tomorrow": boolean, "review_suggestions": ["type": ["integer", "null"]]]),
             kind: .read) { assistant, _ in
            let next = assistant.next
            return [
                "task": next.task.flatMap(assistant.task).map(Shapes.task) ?? .null,
                "reason": assistant.menuBar.nextReason.map(Value.string) ?? .null,
                "wont_fit_before": next.wontFitBefore.map(Shapes.date) ?? .null,
                "plan_tomorrow": .bool(next == .planTomorrow),
                "review_suggestions": { if case let .reviewSuggestions(count) = next { .int(count) } else { .null } }(),
            ]
        },
        Spec(name: "list_tasks", description: "Tasks, oldest first. Filter by status or Project; deleted Tasks only on request.",
             input: object([
                 "status": ["type": "array", "items": enumeration(Shapes.statuses)],
                 "project_id": uuid,
                 "include_deleted": boolean,
             ]),
             output: output(["tasks": list]), kind: .read) { assistant, args in
            let statuses = try args.strings("status")
            if let unknown = statuses?.first(where: { !Shapes.statuses.contains($0) }) {
                throw ToolError("Unknown status \(unknown).")
            }
            let project = try args.projectID("project_id")
            let pool = try args.bool("include_deleted") == true ? assistant.tasks + assistant.deletedTasks : assistant.tasks
            let tasks = pool.filter { task in
                (statuses.map { $0.contains(Shapes.status(task.status)) } ?? true)
                    && (project.map { task.project == $0 } ?? true)
            }
            return ["tasks": .array(tasks.map(Shapes.task))]
        },
        Spec(name: "list_projects", description: "Every Project, active and archived, with its Matchers.",
             input: object([:]), output: output(["projects": list]), kind: .read) { assistant, _ in
            ["projects": .array(assistant.projects.map(Shapes.project))]
        },
        Spec(name: "get_calendar_today", description: "Today's calendar events still to come or under way.",
             input: object([:]), output: output(["events": list]), kind: .read) { assistant, _ in
            ["events": .array(assistant.calendarToday.map(Shapes.event))]
        },
        Spec(name: "get_operation_log", description: "Recent Operations, newest first: what ran, its tier and who started it.",
             input: object(["limit": ["type": "integer", "minimum": 1, "maximum": .int(maxLogEntries)]]),
             output: output(["entries": list]), kind: .read) { assistant, args in
            let limit = try args.int("limit") ?? 20
            guard (1...maxLogEntries).contains(limit) else { throw ToolError("limit must be 1 to \(maxLogEntries).") }
            return ["entries": .array(assistant.operationLog.suffix(limit).reversed().map(Shapes.logEntry))]
        },
    ]

    static let maxLogEntries = 500

    // MARK: Operations

    private static let operations: [Spec] = [
        Spec(name: "add_task", description: "Add a Task. With no project_id it has no Project.",
             input: object([
                 "title": ["type": "string", "minLength": 1],
                 "deadline": dateTime,
                 "project_id": uuid,
                 "effort": enumeration(Shapes.efforts),
                 "kind": enumeration(Shapes.kinds),
                 "back_link": ["type": "string", "minLength": 1],
             ], required: ["title"]),
             output: operationResult, kind: .operation(.addTask)) { assistant, args in
            let task = try assistant.addTask(TaskDraft(
                title: try args.string("title") ?? "", backLink: try args.string("back_link"),
                deadline: try args.date("deadline"), project: try args.projectID("project_id"),
                effort: try args.effort("effort"), kind: try args.kind("kind")), by: .claudeCode)
            // Created now, or held in an Ask until Dara confirms.
            if let held = assistant.asks.last(where: { $0.writes(task.id) }) {
                return result(assistant, .pending(held.id), task: task.id)
            }
            let entry = assistant.operationLog.last { $0.after.tasks.contains { $0.id == task.id } }
            return result(assistant, entry.map { .ran($0.id) }, task: task.id)
        },
        Spec(name: "edit_task", description: "Change a Task's fields. Leave a field out to keep it; pass null to clear it.",
             input: object([
                 "task_id": uuid,
                 "title": ["type": "string", "minLength": 1],
                 "deadline": nullable(dateTime),
                 "project_id": nullable(uuid),
                 "effort": nullable(enumeration(Shapes.efforts)),
                 "kind": nullable(enumeration(Shapes.kinds)),
             ], required: ["task_id"]),
             output: operationResult, kind: .operation(.editTask)) { assistant, args in
            let id = try args.taskID()
            let outcome = try assistant.editTask(id, TaskChanges(
                title: try args.string("title"), deadline: try args.clearable("deadline", args.date),
                project: try args.clearable("project_id", args.projectID), effort: try args.clearable("effort", args.effort),
                kind: try args.clearable("kind", args.kind)), by: .claudeCode)
            return result(assistant, outcome, task: id)
        },
        Spec(name: "bulk_edit_tasks",
             description: "Change the same fields on several Tasks. More than \(Guardrail.bulkEditAsksAbove) asks Dara to confirm in the menu bar, with the Tasks listed.",
             input: object([
                 "task_ids": ["type": "array", "items": uuid, "minItems": 1, "maxItems": 200],
                 "title": ["type": "string", "minLength": 1],
                 "deadline": nullable(dateTime),
                 "project_id": nullable(uuid),
                 "effort": nullable(enumeration(Shapes.efforts)),
                 "kind": nullable(enumeration(Shapes.kinds)),
             ], required: ["task_ids"]),
             output: operationResult, kind: .operation(.bulkEditTasks)) { assistant, args in
            let ids = try args.taskIDs("task_ids")
            let outcome = try assistant.editTasks(ids, TaskChanges(
                title: try args.string("title"), deadline: try args.clearable("deadline", args.date),
                project: try args.clearable("project_id", args.projectID), effort: try args.clearable("effort", args.effort),
                kind: try args.clearable("kind", args.kind)), by: .claudeCode)
            return result(assistant, outcome, task: nil)
        },
        taskOperation("complete_task", "Mark a Task done, when Dara has asked for it.", .completeTask) {
            try $0.completeTask($1, by: .claudeCode)
        },
        Spec(name: "snooze_task",
             description: "Snooze a Task until a time or for some hours; waiting_on says who it waits on. With only waiting_on it has no wake time.",
             input: object([
                 "task_id": uuid,
                 "until": dateTime,
                 "hours": ["type": "number", "exclusiveMinimum": 0],
                 "waiting_on": ["type": "string", "minLength": 1],
             ], required: ["task_id"]),
             output: operationResult, kind: .operation(.snoozeTask)) { assistant, args in
            let id = try args.taskID()
            let note = try args.string("waiting_on")
            let wake = try args.date("until") ?? (try args.number("hours")).map { assistant.now(plusHours: $0) }
            guard wake != nil || note != nil else { throw ToolError("Give until, hours or waiting_on.") }
            let outcome = try assistant.snoozeTask(id, until: wake, note: note, by: .claudeCode)
            return result(assistant, outcome, task: id)
        },
        taskOperation("drop_task", "Drop a Task: it stays in the list but out of play.", .dropTask) {
            try $0.dropTask($1, by: .claudeCode)
        },
        taskOperation("delete_task", "Move a Task to the Deleted list, where it can be restored.", .deleteTask) {
            try $0.deleteTask($1, by: .claudeCode)
        },
        taskOperation("restore_task", "Bring a Task back from the Deleted list.", .restoreTask) {
            try $0.restoreTask($1, by: .claudeCode)
        },
        taskOperation("commit_task", "Make a Task the Committed Task: what Dara is doing now.", .commitTask) {
            try $0.commitTask($1, by: .claudeCode)
        },
        taskOperation("skip_task", "Skip an open Task as Next for two hours.", .skipTask) {
            try $0.skipTask($1, by: .claudeCode)
        },
        exclusionOperation("add_exclusion", "Exclude an app, site, email sender or notes folder: the assistant then reads and sends nothing from it.", .addExclusion) {
            try $0.exclude($1, by: .claudeCode)
        },
        exclusionOperation("remove_exclusion", "Stop excluding something. Asks Dara to confirm in the menu bar.", .removeExclusion) {
            try $0.removeExclusion($1, by: .claudeCode)
        },
    ]

    /// A tool that adds or removes one exclusion, named by exactly one of app, site, sender or
    /// notes_folder. The result says the list changed, never what is on it.
    private static func exclusionOperation(
        _ name: String, _ description: String, _ kind: OperationKind,
        _ operation: @escaping @MainActor (Assistant, Exclusion) throws -> Outcome
    ) -> Spec {
        Spec(name: name, description: description,
             input: object([
                 "app": ["type": "string", "description": "A bundle id."],
                 "site": ["type": "string", "description": "A host, optionally with a path, no scheme."],
                 "sender": ["type": "string", "description": "An email address, or @domain."],
                 "notes_folder": ["type": "string"],
             ]),
             output: operationResult, kind: .operation(kind)) { assistant, args in
            let given = [
                try args.string("app").map(Exclusion.app), try args.string("site").map(Exclusion.site),
                try args.string("sender").map(Exclusion.sender), try args.string("notes_folder").map(Exclusion.notesFolder),
            ].compactMap { $0 }
            guard given.count == 1, let exclusion = given.first else {
                throw ToolError("Give exactly one of app, site, sender or notes_folder.")
            }
            return result(assistant, try operation(assistant, exclusion), task: nil)
        }
    }

    /// A tool that runs one Operation on one Task, named by task_id.
    private static func taskOperation(
        _ name: String, _ description: String, _ kind: OperationKind,
        _ operation: @escaping @MainActor (Assistant, AssistantCore.Task.ID) throws -> Outcome
    ) -> Spec {
        Spec(name: name, description: description, input: object(["task_id": uuid], required: ["task_id"]),
             output: operationResult, kind: .operation(kind)) { assistant, args in
            let id = try args.taskID()
            return result(assistant, try operation(assistant, id), task: id)
        }
    }

    /// What came of the Operation: if it ran, the Task as it now is and the log entry it wrote; if it
    /// waits for Dara, the Ask and when it expires, with the Task unchanged.
    static func result(_ assistant: Assistant, _ outcome: Outcome?, task id: AssistantCore.Task.ID?) -> Value {
        let task = id.flatMap(assistant.task).map(Shapes.task) ?? .null
        switch outcome {
        case let .pending(askID)?:
            let ask = assistant.asks.first { $0.id == askID }
            return ["status": "pending", "task": task, "log_entry": .null,
                    "ask_id": .string(askID.rawValue.uuidString), "expires_at": ask.map { Shapes.date($0.expires) } ?? .null]
        case let .ran(entryID)?:
            let entry = assistant.operationLog.last { $0.id == entryID }
            return ["status": "ran", "task": task, "log_entry": entry.map(Shapes.logEntry) ?? .null,
                    "ask_id": .null, "expires_at": .null]
        case nil:
            return ["status": "ran", "task": task, "log_entry": .null, "ask_id": .null, "expires_at": .null]
        }
    }

    // MARK: Schema pieces

    // Internal, not private, so the tools in ProjectTools.swift share the same pieces.

    static let uuid: Value = ["type": "string", "format": "uuid"]
    static let dateTime: Value = ["type": "string", "format": "date-time"]
    static let boolean: Value = ["type": "boolean"]
    static let list: Value = ["type": "array", "items": ["type": "object"]]
    static let nullableObject: Value = ["type": ["object", "null"]]
    static let nullableString: Value = ["type": ["string", "null"]]
    /// Every Operation tool returns this shape: "ran", or "pending" until Dara confirms in the menu bar.
    static let operationResult = output([
        "status": enumeration(["ran", "pending"]), "task": nullableObject, "log_entry": nullableObject,
        "ask_id": nullableString, "expires_at": nullableString,
    ])

    static func object(_ properties: [String: Value], required: [String] = []) -> Value {
        ["type": "object", "properties": .object(properties), "required": .array(required.map(Value.string)),
         "additionalProperties": false]
    }

    /// An output schema: every key is always present.
    static func output(_ properties: [String: Value]) -> Value {
        object(properties, required: properties.keys.sorted())
    }

    static func enumeration(_ values: [String]) -> Value {
        ["type": "string", "enum": .array(values.map(Value.string))]
    }

    private static func nullable(_ schema: Value) -> Value {
        ["anyOf": [schema, ["type": "null"]]]
    }
}

private extension Assistant {
    /// A wake time some hours from now, by the Assistant's clock.
    func now(plusHours hours: Double) -> Date {
        clockNow + hours * 60 * 60
    }
}
