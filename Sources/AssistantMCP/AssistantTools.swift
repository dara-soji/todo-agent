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

    /// The tool's result as MCP returns it: structured, and as JSON text for clients that only
    /// read text. A bad call or a refused Operation is a tool error, with a message Claude can
    /// read, and changes nothing.
    func call(_ name: String, _ arguments: [String: Value], session: String? = nil) -> CallTool.Result {
        do {
            guard let spec = ToolCatalog.spec(named: name) else { throw ToolError("Unknown tool \(name).") }
            let result = try assistant.inSession(session) { try spec.run(assistant, Arguments(arguments)) }
            if case .operation = spec.kind { onChange() }
            return try CallTool.Result(
                content: [.text(text: Self.json(result), annotations: nil, _meta: nil)], structuredContent: result)
        } catch {
            return CallTool.Result(content: [.text(text: Self.describe(error), annotations: nil, _meta: nil)], isError: true)
        }
    }

    /// The conversation ended: Asks it started expire unrun.
    func endSession(_ id: String) {
        assistant.endSession(id)
        onChange()
    }

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
