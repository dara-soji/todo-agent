import Foundation

/// What a voice split sends: the transcript and the active Project names to match a named one
/// against, and nothing else. No window, Task or Excluded content leaves the Mac.
public struct SplitRequest: Equatable, Sendable {
    public let transcript: String
    /// Active Project names, each once, in name order.
    public let projects: [String]

    public init(transcript: String, projects: [String] = []) {
        self.transcript = transcript
        self.projects = projects
    }
}

/// Haiku's answer: one or more Task titles, cleaned up, in the order they were said, and the
/// Project named out loud, if one was ("for the Acme deck, …").
public struct SplitAnswer: Sendable {
    public let titles: [String]
    /// One of the request's `projects`, or nil when none was named.
    public let project: String?
    /// Dara took back everything said ("buy milk… scratch that"), so `titles` is empty on purpose.
    public let retracted: Bool
    public let call: APICall?

    public init(titles: [String], project: String? = nil, retracted: Bool = false, call: APICall?) {
        self.titles = titles
        self.project = project
        self.retracted = retracted
        self.call = call
    }
}

/// One Task to add from a recording, and the Project named out loud for it, if any.
public struct SpokenTask: Equatable, Sendable {
    public let title: String
    /// Nil: no Project was named, or the name matched none; the Task goes to the default.
    public let project: Project.ID?

    public init(title: String, project: Project.ID? = nil) {
        self.title = title
        self.project = project
    }
}

/// What one recording added: its Tasks, as one Operation.
public struct SpokenAdd: Equatable, Sendable {
    public let tasks: [Task]
    public let outcome: Outcome

    public init(tasks: [Task], outcome: Outcome) {
        self.tasks = tasks
        self.outcome = outcome
    }

    /// The Operation log entry the add wrote, which the Added panel's Undo reverses. Nil while
    /// the Guardrail holds it as an Ask: nothing has been added yet.
    public var undoEntry: LogEntry.ID? {
        if case .ran(let entry) = outcome { entry } else { nil }
    }
}

/// Port: turns a transcript into Task titles. Throws for anything that isn't an answer.
@MainActor
public protocol TranscriptSplitter: AnyObject, Sendable {
    func split(_ request: SplitRequest) async throws -> SplitAnswer
}

/// The rule for reading a split: trimmed titles, blanks dropped; nothing usable, or more than
/// `taskLimit`, is no answer.
public enum VoiceSplit {
    /// More Tasks than this from one recording is read as a malformed answer.
    public static let taskLimit = 8

    /// What one split answer means.
    public enum Reading: Equatable, Sendable {
        case tasks([SpokenTask])
        /// Everything said was taken back: nothing is added.
        case retracted
        /// Unusable: the transcript is added as one Task instead.
        case noAnswer
    }

    /// Reads an answer: an empty one is a retraction only when Haiku says so; any other unusable
    /// answer is no answer, so a recording is never dropped by mistake.
    public static func read(_ answer: SplitAnswer, in projects: [Project]) -> Reading {
        if answer.retracted, answer.titles.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return .retracted
        }
        return tasks(from: answer.titles, project: project(named: answer.project, in: projects)).map(Reading.tasks) ?? .noAnswer
    }

    public static func tasks(from titles: [String], project: Project.ID? = nil) -> [SpokenTask]? {
        let tasks = titles.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            .map { SpokenTask(title: $0, project: project) }
        guard !tasks.isEmpty, tasks.count <= taskLimit else { return nil }
        return tasks
    }

    /// The names a split may choose among: each active Project's name once, in name order.
    public static func labels(for projects: [Project]) -> [String] {
        var seen = Set<String>()
        return projects.map(\.name).filter { seen.insert(key($0)).inserted }
    }

    /// The Project a label names: exactly one active Project by that name (ignoring case and
    /// surrounding space). An unknown label, or one two Projects share, matches none.
    public static func project(named label: String?, in projects: [Project]) -> Project.ID? {
        guard let label, !key(label).isEmpty else { return nil }
        let matches = projects.filter { key($0.name) == key(label) }
        return matches.count == 1 ? matches[0].id : nil
    }

    /// Sounds that are never words (and their common spellings), dropped from a transcript Haiku didn't clean.
    private static let filler: Set<String> = ["um", "umm", "uh", "uhh", "er", "erm", "hmm", "hm", "mm", "mmm"]

    /// The fallback Task's cleanup: standalone filler sounds and immediately repeated words
    /// ("the the") taken out, nothing else touched. Only for voice; typed text is never filtered.
    public static func withoutFiller(_ transcript: String) -> String {
        var kept: [String] = []
        var previous: String?
        for word in transcript.split(whereSeparator: \.isWhitespace).map(String.init) {
            let bare = word.trimmingCharacters(in: .punctuationCharacters).lowercased()
            if filler.contains(bare) { continue }
            if !bare.isEmpty, bare == previous { continue }
            kept.append(word)
            previous = bare
        }
        return kept.joined(separator: " ")
    }

    private static func key(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// Voice quick-add after release: asks the model to split the transcript, records the call, and adds
/// the Tasks as one Operation. With no answer in time (no API key, offline, a refusal, anything
/// malformed) it adds the transcript as one Task, with standalone filler taken out.
@MainActor
public final class VoiceSplitRunner {
    /// Longest wait for the split before the fallback Task is added instead.
    public static let timeout: Duration = .seconds(6)

    private let assistant: Assistant
    private let splitter: TranscriptSplitter
    private let timeout: Duration

    public init(assistant: Assistant, splitter: TranscriptSplitter, timeout: Duration = VoiceSplitRunner.timeout) {
        self.assistant = assistant
        self.splitter = splitter
        self.timeout = timeout
    }

    /// An empty or whitespace-only final transcript: nothing was said, so nothing is added or shown.
    public nonisolated static func heardNothing(_ transcript: String) -> Bool {
        transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The Tasks added, in the order said, and the log entry that added them. They go to the Project named out loud, or else to
    /// `project`: the one the palette showed when recording started. Silence throws `emptyTitle`
    /// and sends nothing.
    @discardableResult
    public func add(_ transcript: String, otherwise project: Project.ID?) async throws -> SpokenAdd {
        guard !Self.heardNothing(transcript) else { throw Assistant.Failure.emptyTitle }
        let transcript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        switch await self.split(transcript) {
        case .tasks(let tasks):
            return try assistant.addSpoken(transcript, as: tasks, otherwise: project)
        case .retracted:
            // "…scratch that": every Task said was taken back, so nothing is added.
            throw Assistant.Failure.emptyTitle
        case .noAnswer:
            // All filler, once filtered: nothing was really said.
            let title = VoiceSplit.withoutFiller(transcript)
            guard !Self.heardNothing(title) else { throw Assistant.Failure.emptyTitle }
            return try assistant.addSpoken(transcript, as: [], titled: title, otherwise: project)
        }
    }

    private func split(_ transcript: String) async -> VoiceSplit.Reading {
        let projects = assistant.activeProjects
        let request = SplitRequest(transcript: transcript, projects: VoiceSplit.labels(for: projects))
        let splitter = self.splitter
        let timeout = self.timeout
        do {
            let answer = try await withThrowingTaskGroup(of: SplitAnswer?.self) { group in
                group.addTask { try await splitter.split(request) }
                group.addTask {
                    try await _Concurrency.Task.sleep(for: timeout)
                    return nil
                }
                defer { group.cancelAll() }
                return try await group.next() ?? nil
            }
            // Timed out: a call cancelled mid-flight has no usage to meter.
            guard let answer else { return .noAnswer }
            if let call = answer.call { assistant.recordAPICall(call) }
            return VoiceSplit.read(answer, in: projects)
        } catch {
            if let billed = error as? BilledFailure { assistant.recordAPICall(billed.call) }
            return .noAnswer
        }
    }
}
