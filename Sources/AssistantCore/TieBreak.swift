import Foundation

/// What a tie-break sends: the tied Tasks (title, deadline, effort, kind) and the time of day.
public struct TieBreakRequest: Equatable, Sendable {
    public struct Candidate: Equatable, Sendable {
        /// A distinct name for the model to answer with.
        public let label: String
        public let title: String
        public let deadline: Date?
        public let effort: Task.Effort?
        public let kind: Task.Kind?
    }

    let key: Set<Task.ID>
    let ids: [Task.ID]
    public let candidates: [Candidate]
    /// E.g. "Saturday 04:00".
    public let timeOfDay: String
}

public struct TieBreakAnswer: Sendable {
    public let choice: String
    public let reason: String
    public let call: APICall?

    public init(choice: String, reason: String, call: APICall?) {
        self.choice = choice
        self.reason = reason
        self.call = call
    }
}

/// Port: picks one of the tied Tasks with a one-line reason. Throws for anything that isn't an answer.
@MainActor
public protocol TieBreaker: AnyObject {
    func breakTie(_ request: TieBreakRequest) async throws -> TieBreakAnswer
}

/// Breaks the tie Next is on, if any: asks the model, records the call, and keeps the pick.
@MainActor
public final class TieBreakRunner {
    private let assistant: Assistant
    private let tieBreaker: TieBreaker

    public init(assistant: Assistant, tieBreaker: TieBreaker) {
        self.assistant = assistant
        self.tieBreaker = tieBreaker
    }

    public func run() async {
        guard let request = assistant.takeTieBreakRequest() else { return }
        do {
            let answer = try await tieBreaker.breakTie(request)
            if let call = answer.call { assistant.recordAPICall(call) }
            assistant.applyTieBreak(request, answer)
        } catch {
            assistant.tieBreakFailed(request.key)
        }
    }
}

extension Assistant {
    /// At most this many tied Tasks are sent.
    static let tieBreakLimit = 5
    /// The longest reason shown under Next, ellipsis included.
    static let reasonLimit = 80

    /// The tied Tasks at the top of Next right now, if any.
    func currentTie() -> [Task]? {
        nextRule().tie(from: tasks.filter { $0.status == .open }, limit: Self.tieBreakLimit)
    }

    /// The tie-break to ask for now, if Next is on a tie not yet broken; taking it marks it in flight.
    func takeTieBreakRequest() -> TieBreakRequest? {
        if let flight = tieInFlight, clock.now.timeIntervalSince(flight.since) >= Self.guessGivesUpAfter {
            tieBreakFailed(flight.key)
        }
        guard tieInFlight == nil, let tie = currentTie() else { return nil }
        let key = Set(tie.map(\.id))
        guard tieBreaks[key] == nil, (tieRetryAt[key] ?? .distantPast) <= clock.now else { return nil }
        tieInFlight = (key, clock.now)
        let labels = uniqueLabels(tie.map(\.title))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEEE HH:mm"
        return TieBreakRequest(
            key: key, ids: tie.map(\.id),
            candidates: zip(labels, tie).map { label, task in
                TieBreakRequest.Candidate(label: label, title: task.title, deadline: task.deadline, effort: task.effort, kind: task.kind)
            },
            timeOfDay: formatter.string(from: clock.now))
    }

    /// Keeps the model's pick for this tie, if it named one of the Tasks.
    func applyTieBreak(_ request: TieBreakRequest, _ answer: TieBreakAnswer) {
        if tieInFlight?.key == request.key { tieInFlight = nil }
        guard let index = request.candidates.firstIndex(where: { $0.label == answer.choice }) else { return }
        tieBreaks[request.key] = (request.ids[index], Self.oneLine(answer.reason))
    }

    func tieBreakFailed(_ key: Set<Task.ID>) {
        if tieInFlight?.key == key { tieInFlight = nil }
        tieRetryAt[key] = clock.now + Self.guessRetryAfter
    }

    /// The model's pick for the current tie, if it has made one.
    func tieBreakPick() -> (task: Task.ID, reason: String)? {
        guard let tie = currentTie(), let pick = tieBreaks[Set(tie.map(\.id))], tie.contains(where: { $0.id == pick.task })
        else { return nil }
        return pick
    }

    private static func oneLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return line.count <= reasonLimit ? line : line.prefix(reasonLimit - 1) + "…"
    }
}
