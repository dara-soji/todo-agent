import AssistantCore
import MCP

/// Every tool the helper offers Claude Code. This list is the contract between the two parts:
/// whatever can be done to Tasks from conversation must exist here (ADR 0001).
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
        let schema: Value
        let kind: Kind
    }

    static let specs: [Spec] = [
        Spec(name: "get_now", description: "What Dara is doing now: the Project Now matched and why, the window, and the Committed Task.",
             schema: object([:]), kind: .read),
        Spec(name: "get_next", description: "The one Task the assistant recommends after Now, with its one-line reason.",
             schema: object([:]), kind: .read),
        Spec(name: "list_tasks", description: "Tasks, oldest first. Filter by status or Project; deleted Tasks only on request.",
             schema: object([
                 "status": ["type": "array", "items": enumeration(statuses)],
                 "project_id": uuid,
                 "include_deleted": ["type": "boolean"],
             ]), kind: .read),
        Spec(name: "list_projects", description: "Every Project, active and archived, with its Matchers.",
             schema: object([:]), kind: .read),
        Spec(name: "get_calendar_today", description: "Today's calendar events still to come or under way.",
             schema: object([:]), kind: .read),
        Spec(name: "get_operation_log", description: "Recent Operations, newest first: what ran, its tier and who started it.",
             schema: object(["limit": ["type": "integer", "minimum": 1, "maximum": 500]]), kind: .read),

        Spec(name: "add_task", description: "Add a Task. With no project_id it has no Project.",
             schema: object([
                 "title": ["type": "string", "minLength": 1],
                 "deadline": dateTime,
                 "project_id": uuid,
                 "effort": enumeration(["small", "medium", "large"]),
                 "kind": enumeration(["deep", "shallow"]),
                 "back_link": ["type": "string"],
             ], required: ["title"]), kind: .operation(.addTask)),
        Spec(name: "edit_task", description: "Change a Task's fields. Leave a field out to keep it; pass null to clear it.",
             schema: object([
                 "task_id": uuid,
                 "title": ["type": "string", "minLength": 1],
                 "deadline": nullable(dateTime),
                 "project_id": nullable(uuid),
                 "effort": nullable(enumeration(["small", "medium", "large"])),
                 "kind": nullable(enumeration(["deep", "shallow"])),
             ], required: ["task_id"]), kind: .operation(.editTask)),
        Spec(name: "complete_task", description: "Mark a Task done, when Dara has asked for it.",
             schema: taskOnly, kind: .operation(.completeTask)),
        Spec(name: "snooze_task", description: "Snooze a Task until a time, for some hours, or while waiting on someone (no wake time).",
             schema: object([
                 "task_id": uuid,
                 "until": dateTime,
                 "hours": ["type": "number", "exclusiveMinimum": 0],
                 "waiting_on": ["type": "string", "minLength": 1],
             ], required: ["task_id"]), kind: .operation(.snoozeTask)),
        Spec(name: "drop_task", description: "Drop a Task: it stays in the list but out of play.",
             schema: taskOnly, kind: .operation(.dropTask)),
        Spec(name: "delete_task", description: "Move a Task to the Deleted list, where Dara can restore it.",
             schema: taskOnly, kind: .operation(.deleteTask)),
        Spec(name: "commit_task", description: "Make a Task the Committed Task: what Dara is doing now.",
             schema: taskOnly, kind: .operation(.commitTask)),
        Spec(name: "skip_task", description: "Skip an open Task as Next for two hours.",
             schema: taskOnly, kind: .operation(.skipTask)),
    ]

    static func spec(named name: String) -> Spec? {
        specs.first { $0.name == name }
    }

    /// The tools as MCP lists them. Each Operation tool declares the tier the Guardrail gives it.
    static func tools(tier: (OperationKind) -> Tier) -> [Tool] {
        specs.map { spec in
            switch spec.kind {
            case .read:
                Tool(name: spec.name, description: spec.description, inputSchema: spec.schema,
                     annotations: .init(readOnlyHint: true))
            case let .operation(kind):
                Tool(name: spec.name, description: spec.description, inputSchema: spec.schema,
                     annotations: .init(readOnlyHint: false, destructiveHint: false, openWorldHint: false),
                     _meta: Metadata(additionalFields: ["tier": .string(tier(kind).rawValue)]))
            }
        }
    }

    static let statuses = ["open", "committed", "done", "dropped", "snoozed"]

    // MARK: Schema pieces

    private static let uuid: Value = ["type": "string", "format": "uuid"]
    private static let dateTime: Value = ["type": "string", "format": "date-time"]
    private static let taskOnly = object(["task_id": uuid], required: ["task_id"])

    private static func object(_ properties: [String: Value], required: [String] = []) -> Value {
        ["type": "object", "properties": .object(properties), "required": .array(required.map(Value.string)),
         "additionalProperties": false]
    }

    private static func enumeration(_ values: [String]) -> Value {
        ["type": "string", "enum": .array(values.map(Value.string))]
    }

    private static func nullable(_ schema: Value) -> Value {
        ["anyOf": [schema, ["type": "null"]]]
    }
}
