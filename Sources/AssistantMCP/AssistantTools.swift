import AssistantCore
import Foundation
import MCP

/// Runs each tool against the core, on the main actor where the Assistant lives. Every Operation
/// is started by Claude Code and goes through the core's Guardrail like any other.
@MainActor
public final class AssistantTools {
    private let assistant: Assistant
    /// Called after an Operation runs, so the helper can redraw the menu bar.
    public var onChange: () -> Void = {}

    public init(assistant: Assistant) {
        self.assistant = assistant
    }

    var tools: [Tool] {
        ToolCatalog.tools(tier: assistant.tier(for:))
    }

    /// The tool's result as MCP returns it. A bad call or a refused Operation is a tool error,
    /// with a message Claude can read, and changes nothing.
    func call(_ name: String, _ arguments: [String: Value]) -> CallTool.Result {
        do {
            guard let spec = ToolCatalog.spec(named: name) else { throw ToolError("Unknown tool \(name).") }
            let result = try run(spec, Arguments(arguments))
            if case .operation = spec.kind { onChange() }
            return CallTool.Result(content: [.text(text: Self.json(result), annotations: nil, _meta: nil)])
        } catch {
            return CallTool.Result(content: [.text(text: Self.describe(error), annotations: nil, _meta: nil)], isError: true)
        }
    }

    private func run(_ spec: ToolCatalog.Spec, _ args: Arguments) throws -> Value {
        switch spec.name {
        case "get_now": return nowValue()
        case "get_next": return nextValue()
        case "list_tasks": return try listTasks(args)
        case "list_projects": return ["projects": .array(assistant.projects.map(Shapes.project))]
        case "get_calendar_today": return ["events": .array(assistant.calendarToday.map(Shapes.event))]
        case "get_operation_log":
            let limit = try args.int("limit") ?? 20
            return ["entries": .array(assistant.operationLog.suffix(limit).reversed().map(Shapes.logEntry))]

        case "add_task":
            let task = try assistant.addTask(TaskDraft(
                title: try args.string("title") ?? "", deadline: try args.date("deadline"),
                project: try args.projectID("project_id"), effort: try args.effort("effort"), kind: try args.kind("kind"),
            ), by: .claudeCode)
            return ran(task.id)
        case "edit_task":
            let id = try args.taskID()
            try assistant.editTask(id, TaskChanges(
                title: try args.string("title"), deadline: try args.clearable("deadline", args.date),
                project: try args.clearable("project_id", args.projectID), effort: try args.clearable("effort", args.effort),
                kind: try args.clearable("kind", args.kind)), by: .claudeCode)
            return ran(id)
        case "complete_task": return try operate(args, assistant.completeTask)
        case "drop_task": return try operate(args, assistant.dropTask)
        case "delete_task": return try operate(args, assistant.deleteTask)
        case "commit_task": return try operate(args, { try self.assistant.commitTask($0, by: $1) })
        case "skip_task": return try operate(args, assistant.skipTask)
        case "snooze_task":
            let id = try args.taskID()
            if let note = try args.string("waiting_on") {
                try assistant.snoozeTask(id, until: nil, note: note, by: .claudeCode)
            } else if let until = try args.date("until") {
                try assistant.snoozeTask(id, until: until, by: .claudeCode)
            } else if let hours = try args.number("hours") {
                try assistant.snoozeTask(id, forHours: hours, by: .claudeCode)
            } else {
                throw ToolError("Give until, hours or waiting_on.")
            }
            return ran(id)
        default:
            throw ToolError("Unknown tool \(spec.name).")
        }
    }

    private func operate(_ args: Arguments, _ operation: (AssistantCore.Task.ID, StartedBy) throws -> Void) throws -> Value {
        let id = try args.taskID()
        try operation(id, .claudeCode)
        return ran(id)
    }

    /// The result of an Operation that ran: the Task as it now is and the log entry it wrote.
    private func ran(_ id: AssistantCore.Task.ID) -> Value {
        ["status": "ran", "task": assistant.task(id).map(Shapes.task) ?? .null,
         "log_entry": assistant.operationLog.last.map(Shapes.logEntry) ?? .null]
    }

    // MARK: Reads

    private func nowValue() -> Value {
        let now = assistant.now
        let project = now.project.flatMap(assistant.project)
        return [
            "project": project.map { ["id": .string($0.id.rawValue.uuidString), "name": .string($0.name),
                                      "short_name": .string($0.shortName)] } ?? .null,
            "evidence": now.evidence.map { .string($0.pattern) } ?? .null,
            "window": now.window.map { window in
                ["app": .string(window.app.name), "title": window.title.map(Value.string) ?? .null,
                 "url": window.url.map { .string($0.absoluteString) } ?? .null]
            } ?? .null,
            "since": now.since.map(Shapes.date) ?? .null,
            "away": .bool(now.isAway),
            "committed_task": assistant.committedTask.map(Shapes.task) ?? .null,
        ]
    }

    private func nextValue() -> Value {
        let next = assistant.next
        let menuBar = assistant.menuBar
        return [
            "task": next.task.flatMap(assistant.task).map(Shapes.task) ?? .null,
            "reason": menuBar.nextReason.map(Value.string) ?? .null,
            "wont_fit_before": next.wontFitBefore.map(Shapes.date) ?? .null,
            "plan_tomorrow": .bool(next == .planTomorrow),
        ]
    }

    private func listTasks(_ args: Arguments) throws -> Value {
        let statuses = try args.strings("status")
        if let unknown = statuses?.first(where: { !ToolCatalog.statuses.contains($0) }) {
            throw ToolError("Unknown status \(unknown).")
        }
        let project = try args.projectID("project_id")
        let pool = try args.bool("include_deleted") == true ? assistant.tasks + assistant.deletedTasks : assistant.tasks
        let tasks = pool.filter { task in
            (statuses.map { $0.contains(Shapes.status(task.status)) } ?? true) && (project.map { task.project == $0 } ?? true)
        }
        return ["tasks": .array(tasks.map(Shapes.task))]
    }

    // MARK: Output

    private static func json(_ value: Value) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? String(decoding: encoder.encode(value), as: UTF8.self)) ?? "null"
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case let error as ToolError: error.message
        case let failure as Assistant.Failure: Shapes.explain(failure)
        case let invalid as Matcher.Invalid: "Invalid Matcher: \(invalid)"
        default: "\(error)"
        }
    }
}

struct ToolError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}
