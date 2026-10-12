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
            }
        }
    }

    static let specs: [Spec] = reads + operations

    // MARK: Reads

    private static let reads: [Spec] = [
        Spec(name: "get_now",
             description: "What Dara is doing now: the Project Now matched and why, the app, and the Committed Task. Window titles and URLs stay on the Mac.",
             input: object([:]),
             output: result(["project": nullableObject, "evidence": nullableString, "app": nullableString,
                             "since": nullableString, "away": boolean, "committed_task": nullableObject]),
             kind: .read) { assistant, _ in
            let now = assistant.now
            return [
                "project": now.project.flatMap(assistant.project).map(Shapes.project) ?? .null,
                "evidence": now.evidence.map { .string($0.pattern) } ?? .null,
                "app": now.window.map { .string($0.app.name) } ?? .null,
                "since": now.since.map(Shapes.date) ?? .null,
                "away": .bool(now.isAway),
                "committed_task": assistant.committedTask.map(Shapes.task) ?? .null,
            ]
        },
        Spec(name: "get_next", description: "The one Task the assistant recommends after Now, with its one-line reason.",
             input: object([:]),
             output: result(["task": nullableObject, "reason": nullableString, "wont_fit_before": nullableString,
                             "plan_tomorrow": boolean]),
             kind: .read) { assistant, _ in
            let next = assistant.next
            return [
                "task": next.task.flatMap(assistant.task).map(Shapes.task) ?? .null,
                "reason": assistant.menuBar.nextReason.map(Value.string) ?? .null,
                "wont_fit_before": next.wontFitBefore.map(Shapes.date) ?? .null,
                "plan_tomorrow": .bool(next == .planTomorrow),
            ]
        },
        Spec(name: "list_tasks", description: "Tasks, oldest first. Filter by status or Project; deleted Tasks only on request.",
             input: object([
                 "status": ["type": "array", "items": enumeration(Shapes.statuses)],
                 "project_id": uuid,
                 "include_deleted": boolean,
             ]),
             output: result(["tasks": list]), kind: .read) { assistant, args in
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
             input: object([:]), output: result(["projects": list]), kind: .read) { assistant, _ in
            ["projects": .array(assistant.projects.map(Shapes.project))]
        },
        Spec(name: "get_calendar_today", description: "Today's calendar events still to come or under way.",
             input: object([:]), output: result(["events": list]), kind: .read) { assistant, _ in
            ["events": .array(assistant.calendarToday.map(Shapes.event))]
        },
        Spec(name: "get_operation_log", description: "Recent Operations, newest first: what ran, its tier and who started it.",
             input: object(["limit": ["type": "integer", "minimum": 1, "maximum": .int(maxLogEntries)]]),
             output: result(["entries": list]), kind: .read) { assistant, args in
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
             output: ran, kind: .operation(.addTask)) { assistant, args in
            let task = try assistant.addTask(TaskDraft(
                title: try args.string("title") ?? "", backLink: try args.string("back_link"),
                deadline: try args.date("deadline"), project: try args.projectID("project_id"),
                effort: try args.effort("effort"), kind: try args.kind("kind")), by: .claudeCode)
            return ranResult(assistant, task.id)
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
             output: ran, kind: .operation(.editTask)) { assistant, args in
            let id = try args.taskID()
            try assistant.editTask(id, TaskChanges(
                title: try args.string("title"), deadline: try args.clearable("deadline", args.date),
                project: try args.clearable("project_id", args.projectID), effort: try args.clearable("effort", args.effort),
                kind: try args.clearable("kind", args.kind)), by: .claudeCode)
            return ranResult(assistant, id)
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
             output: ran, kind: .operation(.snoozeTask)) { assistant, args in
            let id = try args.taskID()
            let note = try args.string("waiting_on")
            let wake = try args.date("until") ?? (try args.number("hours")).map { assistant.now(plusHours: $0) }
            guard wake != nil || note != nil else { throw ToolError("Give until, hours or waiting_on.") }
            try assistant.snoozeTask(id, until: wake, note: note, by: .claudeCode)
            return ranResult(assistant, id)
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
    ]

    /// A tool that runs one Operation on one Task, named by task_id.
    private static func taskOperation(
        _ name: String, _ description: String, _ kind: OperationKind,
        _ operation: @escaping @MainActor (Assistant, AssistantCore.Task.ID) throws -> Void
    ) -> Spec {
        Spec(name: name, description: description, input: object(["task_id": uuid], required: ["task_id"]),
             output: ran, kind: .operation(kind)) { assistant, args in
            let id = try args.taskID()
            try operation(assistant, id)
            return ranResult(assistant, id)
        }
    }

    /// An Operation that ran: the Task as it now is, and the log entry it wrote.
    private static func ranResult(_ assistant: Assistant, _ id: AssistantCore.Task.ID) -> Value {
        ["status": "ran", "task": assistant.task(id).map(Shapes.task) ?? .null,
         "log_entry": assistant.operationLog.last.map(Shapes.logEntry) ?? .null]
    }

    // MARK: Schema pieces

    private static let uuid: Value = ["type": "string", "format": "uuid"]
    private static let dateTime: Value = ["type": "string", "format": "date-time"]
    private static let boolean: Value = ["type": "boolean"]
    private static let list: Value = ["type": "array", "items": ["type": "object"]]
    private static let nullableObject: Value = ["type": ["object", "null"]]
    private static let nullableString: Value = ["type": ["string", "null"]]
    /// Every Operation tool returns this shape.
    private static let ran = result([
        "status": enumeration(["ran"]), "task": nullableObject, "log_entry": nullableObject,
    ])

    private static func object(_ properties: [String: Value], required: [String] = []) -> Value {
        ["type": "object", "properties": .object(properties), "required": .array(required.map(Value.string)),
         "additionalProperties": false]
    }

    /// An output schema: every key is always present.
    private static func result(_ properties: [String: Value]) -> Value {
        object(properties, required: properties.keys.sorted())
    }

    private static func enumeration(_ values: [String]) -> Value {
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
