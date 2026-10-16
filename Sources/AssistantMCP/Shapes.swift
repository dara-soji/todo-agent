import AssistantCore
import Foundation
import MCP

/// How core values look to Claude Code: snake_case JSON with ISO 8601 dates and UUID strings.
enum Shapes {
    static let statuses = ["open", "committed", "done", "dropped", "snoozed"]
    static let efforts = AssistantCore.Task.Effort.allCases.map(\.rawValue)
    static let kinds = AssistantCore.Task.Kind.allCases.map(\.rawValue)

    static func task(_ task: AssistantCore.Task) -> Value {
        var snoozedUntil: Value = .null
        var waitingOn: Value = .null
        if case let .snoozed(until, note) = task.status {
            snoozedUntil = until.map(date) ?? .null
            waitingOn = note.map(Value.string) ?? .null
        }
        return [
            "id": .string(task.id.rawValue.uuidString),
            "title": .string(task.title),
            "source": .string(task.source.rawValue),
            "back_link": task.backLink.map(Value.string) ?? .null,
            "status": .string(status(task.status)),
            "snoozed_until": snoozedUntil,
            "waiting_on": waitingOn,
            "created": date(task.created),
            "deadline": task.deadline.map(date) ?? .null,
            "project_id": task.project.map { .string($0.rawValue.uuidString) } ?? .null,
            "effort": task.effort.map { .string($0.rawValue) } ?? .null,
            "kind": task.kind.map { .string($0.rawValue) } ?? .null,
            "resume_after_interruption": .bool(task.resumeAfterInterruption),
            "deleted": .bool(task.deletedAt != nil),
        ]
    }

    static func status(_ status: AssistantCore.Task.Status) -> String {
        switch status {
        case .open: "open"
        case .committed: "committed"
        case .done: "done"
        case .dropped: "dropped"
        case .snoozed: "snoozed"
        }
    }

    /// Why Now is on its Project: matcher, meeting, neutral_hold or correction.
    static func basis(_ basis: Now.Match.Basis) -> String {
        switch basis {
        case .matcher: "matcher"
        case .meeting: "meeting"
        case .neutralHold: "neutral_hold"
        case .correction: "correction"
        case .guess: "guess"
        }
    }

    static func project(_ project: Project) -> Value {
        [
            "id": .string(project.id.rawValue.uuidString),
            "name": .string(project.name),
            "short_name": .string(project.shortName),
            "status": .string(project.status.rawValue),
            "matchers": .array(project.matchers.map { ["kind": .string($0.kind.rawValue), "pattern": .string($0.pattern)] }),
        ]
    }

    static func event(_ event: CalendarEvent) -> Value {
        ["title": .string(event.title), "start": date(event.start), "end": date(event.end)]
    }

    static func logEntry(_ entry: LogEntry) -> Value {
        [
            "id": .string(entry.id.rawValue.uuidString),
            "at": date(entry.at),
            "kind": .string(entry.kind.rawValue),
            "summary": .string(entry.summary),
            "tier": .string(entry.tier.rawValue),
            "started_by": .string(entry.startedBy.rawValue),
            "confirmation": .string(entry.confirmation.rawValue),
            "undoes": entry.undoes.map { .string($0.rawValue.uuidString) } ?? .null,
        ]
    }

    static func date(_ date: Date) -> Value {
        .string(ISO8601DateFormatter().string(from: date))
    }

    /// A refusal in words Claude can relay to Dara.
    static func explain(_ failure: Assistant.Failure) -> String {
        switch failure {
        case let .unknownProject(id): "No Project \(id.rawValue.uuidString)."
        case let .unknownTask(id): "No Task \(id.rawValue.uuidString)."
        case let .unknownLogEntry(id): "No log entry \(id.rawValue.uuidString)."
        case .emptyName: "A Project needs a name."
        case .emptyTitle: "A Task needs a title."
        case .onlyDaraMarksDone: "Only Dara marks a Task done."
        case let .deletedTask(id): "Task \(id.rawValue.uuidString) is in the Deleted list."
        case let .notOpen(id): "Task \(id.rawValue.uuidString) is not open, so it can't be skipped."
        case .secondCommittedTask: "That would leave two Committed Tasks."
        case let .changedSince(id): "Log entry \(id.rawValue.uuidString) can't be undone: things changed since."
        case let .notAllowed(kind, tier): "\(kind.rawValue) is \(tier.rawValue) and can't run here."
        case let .unknownAsk(id): "No pending Ask \(id.rawValue.uuidString)."
        case let .askChangedSince(id): "Ask \(id.rawValue.uuidString) can't run: things changed since."
        case let .cannotTighten(kind): "\(kind.rawValue) can't be made stricter."
        case let .cannotLoosen(kind): "\(kind.rawValue) isn't an Ask Operation, so it can't be loosened."
        case .nothingNext: "There is no Next to start."
        case .noWindow: "There is no window to correct yet."
        case .noOffer: "Nothing is waiting for Always."
        case .alreadyNeutral: "That is already Neutral."
        case .alreadyExcluded: "That is already Excluded."
        case .notExcluded: "That isn't on the exclude list."
        case .windowExcluded: "The window in front is Excluded, so it can't be corrected."
        case let .notUndoable(id): "Log entry \(id.rawValue.uuidString) ran nothing, so there is nothing to undo."
        case let .unknownSuggestion(id): "No open Suggestion \(id.rawValue.uuidString)."
        case let .unknownDigestLine(thread): "No Digest line for thread \(thread)."
        case let .notAVIP(sender): "\(sender) isn't on the VIP list."
        case let .alreadyVIP(sender): "\(sender) is already a VIP."
        case let .notANoiseSender(sender): "\(sender) isn't on the never-from list."
        case let .malformedSheet(text): "\(text) isn't a Google Sheet id or URL."
        case let .alreadyRegisteredSheet(id): "Sheet \(id) is already registered."
        case let .unknownSheet(id): "Sheet \(id) isn't registered."
        }
    }
}
