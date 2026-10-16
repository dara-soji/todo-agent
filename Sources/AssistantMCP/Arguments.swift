import AssistantCore
import Foundation
import MCP

/// A tool call's arguments, read with types and clear errors.
struct Arguments {
    let values: [String: Value]

    init(_ values: [String: Value]) {
        self.values = values
    }

    func string(_ key: String) throws -> String? {
        try read(key, "a string") { $0.stringValue }
    }

    func strings(_ key: String) throws -> [String]? {
        try read(key, "an array of strings") { value in
            value.arrayValue.flatMap { items in
                let strings = items.compactMap(\.stringValue)
                return strings.count == items.count ? strings : nil
            }
        }
    }

    func int(_ key: String) throws -> Int? {
        try read(key, "an integer") { $0.intValue }
    }

    func number(_ key: String) throws -> Double? {
        try read(key, "a number") { $0.doubleValue ?? $0.intValue.map(Double.init) }
    }

    func bool(_ key: String) throws -> Bool? {
        try read(key, "true or false") { $0.boolValue }
    }

    func date(_ key: String) throws -> Date? {
        try read(key, "an ISO 8601 date-time") { value in
            value.stringValue.flatMap { text in
                let formatter = ISO8601DateFormatter()
                if let date = formatter.date(from: text) { return date }
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                return formatter.date(from: text)
            }
        }
    }

    func taskID() throws -> AssistantCore.Task.ID {
        guard let id = try uuid("task_id") else { throw ToolError("task_id is required.") }
        return AssistantCore.Task.ID(id)
    }

    func taskIDs(_ key: String) throws -> [AssistantCore.Task.ID] {
        guard let strings = try strings(key), !strings.isEmpty else { throw ToolError("\(key) needs at least one Task id.") }
        return try strings.map { text in
            guard let uuid = UUID(uuidString: text) else { throw ToolError("\(text) in \(key) is not a UUID.") }
            return AssistantCore.Task.ID(uuid)
        }
    }

    func projectID(_ key: String) throws -> Project.ID? {
        try uuid(key).map(Project.ID.init)
    }

    func effort(_ key: String) throws -> AssistantCore.Task.Effort? {
        try read(key, Shapes.efforts.joined(separator: ", ")) { $0.stringValue.flatMap(AssistantCore.Task.Effort.init(rawValue:)) }
    }

    func kind(_ key: String) throws -> AssistantCore.Task.Kind? {
        try read(key, Shapes.kinds.joined(separator: ", ")) { $0.stringValue.flatMap(AssistantCore.Task.Kind.init(rawValue:)) }
    }

    /// For edits: absent leaves the field alone (nil), null clears it (.some(nil)), a value sets it.
    func clearable<T>(_ key: String, _ read: (String) throws -> T?) throws -> T?? {
        guard let value = values[key] else { return nil }
        if value == .null { return .some(nil) }
        return .some(try read(key))
    }

    private func uuid(_ key: String) throws -> UUID? {
        try read(key, "a UUID") { $0.stringValue.flatMap(UUID.init(uuidString:)) }
    }

    /// Nil when the key is absent or null; an error when it holds the wrong kind of value.
    private func read<T>(_ key: String, _ expected: String, _ convert: (Value) -> T?) throws -> T? {
        guard let value = values[key], value != .null else { return nil }
        guard let converted = convert(value) else { throw ToolError("\(key) must be \(expected).") }
        return converted
    }
}
