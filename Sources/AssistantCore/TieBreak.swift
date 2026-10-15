import Foundation

/// Which tie a pick is for: the tied Tasks, what about them was sent, and the part of the day. If any
/// of that changes, the old pick and its reason no longer apply.
struct TieKey: Hashable, Sendable {
    let tasks: Set<Task.ID>
    let fingerprint: String
}

/// What a tie-break sends: the tied Tasks' titles, deadlines (in Dara's time), effort and kind, and
/// the time of day.
public struct TieBreakRequest: Equatable, Sendable {
    public struct Candidate: Equatable, Sendable {
        /// A distinct name for the model to answer with.
        public let label: String
        public let title: String
        /// E.g. "Thursday 17:00", in Dara's time zone.
        public let due: String?
        public let effort: Task.Effort?
        public let kind: Task.Kind?
    }

    let key: TieKey
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

/// Sonnet's pick for a tie, and the one-line reason shown under Next.
struct TieBreakPick {
    let task: Task.ID
    let reason: String
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
            if let billed = error as? BilledFailure { assistant.recordAPICall(billed.call) }
            assistant.tieBreakFailed(request.key)
        }
    }
}

extension Assistant {
    /// At most this many tied Tasks are sent.
    static let tieBreakLimit = 5
    /// The longest reason shown under Next, ellipsis included.
    static let reasonLimit = 80
    /// A tie-break still in flight after this long is given up on.
    static let tieBreakGivesUpAfter: TimeInterval = 2 * 60
    /// After a failure (or a non-answer), the same tie is asked about again no sooner than this.
    static let tieBreakRetryAfter: TimeInterval = 10 * 60
    /// Picks kept in memory; beyond this they are all dropped and asked for again as ties come up.
    static let tieBreakCacheLimit = 100

    /// The tied Tasks at the top of Next right now, if any.
    func currentTie() -> [Task]? {
        nextRule().tie(from: tasks.filter { $0.status == .open }, limit: Self.tieBreakLimit)
    }

    /// The tie-break to ask for now, if Next is on a tie not yet broken; taking it marks it in flight.
    func takeTieBreakRequest() -> TieBreakRequest? {
        if let flight = tieInFlight, clock.now.timeIntervalSince(flight.since) >= Self.tieBreakGivesUpAfter {
            tieBreakFailed(flight.key)
        }
        tieRetryAt = tieRetryAt.filter { $0.value > clock.now }
        guard tieInFlight == nil, let tie = currentTie() else { return nil }
        let key = tieKey(tie)
        guard tieBreaks[key] == nil, tieRetryAt[key] == nil else { return nil }
        tieInFlight = (key, clock.now)
        let labels = uniqueLabels(tie.map(\.title))
        return TieBreakRequest(
            key: key, ids: tie.map(\.id),
            candidates: zip(labels, tie).map { label, task in
                TieBreakRequest.Candidate(
                    label: label, title: task.title, due: task.deadline.map { format($0, "EEEE HH:mm") },
                    effort: task.effort, kind: task.kind)
            },
            timeOfDay: format(clock.now, "EEEE HH:mm"))
    }

    /// Keeps the model's pick for this tie. An answer that isn't one of the Tasks counts as no answer.
    func applyTieBreak(_ request: TieBreakRequest, _ answer: TieBreakAnswer) {
        guard let index = request.candidates.firstIndex(where: { $0.label == answer.choice }) else {
            return tieBreakFailed(request.key)
        }
        if tieInFlight?.key == request.key { tieInFlight = nil }
        if tieBreaks.count >= Self.tieBreakCacheLimit { tieBreaks.removeAll() }
        tieBreaks[request.key] = TieBreakPick(task: request.ids[index], reason: Self.oneLine(answer.reason))
    }

    func tieBreakFailed(_ key: TieKey) {
        if tieInFlight?.key == key { tieInFlight = nil }
        tieRetryAt[key] = clock.now + Self.tieBreakRetryAfter
    }

    /// The model's pick for the current tie, if it has made one.
    func tieBreakPick() -> TieBreakPick? {
        guard let tie = currentTie(), let pick = tieBreaks[tieKey(tie)] else { return nil }
        return pick
    }

    private func tieKey(_ tie: [Task]) -> TieKey {
        let details = tie.sorted { $0.id.rawValue.uuidString < $1.id.rawValue.uuidString }.map { task in
            [task.id.rawValue.uuidString, task.title, task.deadline.map { "\($0.timeIntervalSince1970)" } ?? "",
             task.effort?.rawValue ?? "", task.kind?.rawValue ?? ""].joined(separator: "|")
        }
        return TieKey(tasks: Set(tie.map(\.id)), fingerprint: (details + [nextRule().partOfDay]).joined(separator: "\n"))
    }

    private func format(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    private static func oneLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return line.count <= reasonLimit ? line : line.prefix(reasonLimit - 1) + "…"
    }
}
