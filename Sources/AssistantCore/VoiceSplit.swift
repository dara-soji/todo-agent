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

/// Haiku's answer: one or more Task titles, filler removed, in the order they were said, and the
/// Project named out loud, if one was ("for the Acme deck, …").
public struct SplitAnswer: Sendable {
    public let titles: [String]
    /// One of the request's `projects`, or nil when none was named.
    public let project: String?
    public let call: APICall?

    public init(titles: [String], project: String? = nil, call: APICall?) {
        self.titles = titles
        self.project = project
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

    private static func key(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// Voice quick-add after release: asks the model to split the transcript, records the call, and adds
/// the Tasks as one Operation. With no answer in time (no API key, offline, a refusal, anything
/// malformed) it adds the transcript verbatim as one Task.
@MainActor
public final class VoiceSplitRunner {
    /// Longest wait for the split before the verbatim Task is added instead.
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

    /// The Tasks added, in the order said. They go to the Project named out loud, or else to
    /// `project`: the one the palette showed when recording started. Silence throws `emptyTitle`
    /// and sends nothing.
    @discardableResult
    public func add(_ transcript: String, otherwise project: Project.ID?) async throws -> [Task] {
        guard !Self.heardNothing(transcript) else { throw Assistant.Failure.emptyTitle }
        let transcript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let split = await self.split(transcript)
        return try assistant.addSpoken(transcript, as: split ?? [], otherwise: project)
    }

    private func split(_ transcript: String) async -> [SpokenTask]? {
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
            guard let answer else { return nil }
            if let call = answer.call { assistant.recordAPICall(call) }
            return VoiceSplit.tasks(from: answer.titles, project: VoiceSplit.project(named: answer.project, in: projects))
        } catch {
            if let billed = error as? BilledFailure { assistant.recordAPICall(billed.call) }
            return nil
        }
    }
}
