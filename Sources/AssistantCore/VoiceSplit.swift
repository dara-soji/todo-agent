import Foundation

/// What a voice split sends: the transcript, and nothing else. No window, Project or Task leaves the Mac.
public struct SplitRequest: Equatable, Sendable {
    public let transcript: String

    public init(transcript: String) {
        self.transcript = transcript
    }
}

/// Haiku's answer: one or more Task titles, filler removed, in the order they were said.
public struct SplitAnswer: Sendable {
    public let titles: [String]
    public let call: APICall?

    public init(titles: [String], call: APICall?) {
        self.titles = titles
        self.call = call
    }
}

/// One Task to add from a recording. Room for where it goes, once a Project can be named out loud.
public struct SpokenTask: Equatable, Sendable {
    public let title: String

    public init(title: String) {
        self.title = title
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

    public static func tasks(from titles: [String]) -> [SpokenTask]? {
        let tasks = titles.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            .map(SpokenTask.init)
        guard !tasks.isEmpty, tasks.count <= taskLimit else { return nil }
        return tasks
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

    /// The Tasks added, in the order said. Silence throws `emptyTitle` and sends nothing.
    @discardableResult
    public func add(_ transcript: String) async throws -> [Task] {
        guard !Self.heardNothing(transcript) else { throw Assistant.Failure.emptyTitle }
        let transcript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let split = await self.split(transcript)
        return try assistant.addSpoken(transcript, as: split ?? [])
    }

    private func split(_ transcript: String) async -> [SpokenTask]? {
        let request = SplitRequest(transcript: transcript)
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
            return VoiceSplit.tasks(from: answer.titles)
        } catch {
            if let billed = error as? BilledFailure { assistant.recordAPICall(billed.call) }
            return nil
        }
    }
}
