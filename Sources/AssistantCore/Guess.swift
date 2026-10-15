import Foundation

/// Which window a Haiku guess is for: its app and title. Guesses are cached by this.
public struct GuessKey: Hashable, Sendable {
    public let bundleID: String
    public let title: String

    public init(bundleID: String, title: String) {
        self.bundleID = bundleID
        self.title = title
    }
}

/// A request for one screenshot guess: the window, and the active Projects Haiku may choose from.
/// Only Project names leave the Mac with the screenshot.
public struct GuessRequest: Equatable, Sendable {
    public struct Choice: Equatable, Sendable {
        public let id: Project.ID
        public let name: String
    }

    public let key: GuessKey
    public let projects: [Choice]
}

/// One call to the Claude API, as the audit log keeps it: metadata only, never content.
public struct APICall: Equatable, Sendable, Codable {
    public enum Purpose: String, Sendable, Codable {
        case projectGuess, nextTieBreak, triage
    }

    /// What kind of content was sent, never the content itself.
    public enum ContentKind: String, Sendable, Codable {
        case screenshotAndProjectNames, taskTitles, emailExcerpt
    }

    public let at: Date
    public let purpose: Purpose
    public let model: String
    public let inputTokens: Int
    public let outputTokens: Int
    public let contentKind: ContentKind

    public init(at: Date, purpose: Purpose, model: String, inputTokens: Int, outputTokens: Int, contentKind: ContentKind) {
        self.at = at
        self.purpose = purpose
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.contentKind = contentKind
    }

    /// US dollars at the model's list price per million tokens (prompts under 100K).
    public var costUSD: Double {
        guard let price = Self.pricePerMillion[model] else { return 0 }
        return (Double(inputTokens) * price.input + Double(outputTokens) * price.output) / 1_000_000
    }

    static let pricePerMillion: [String: (input: Double, output: Double)] = [
        "claude-haiku-5-5": (0.10, 0.50),
        "claude-sonnet-5-5": (2.00, 10.00),
    ]
}

extension Assistant {
    /// Unmatched this long on one app and title, and one screenshot guess is asked for.
    static let guessAfter: TimeInterval = 2 * 60

    /// The screenshot guess to make now, if any; taking it marks it in flight so it is made once.
    /// Only for a stable window that nothing else places: not matched, Neutral, Excluded, corrected,
    /// Away, or already guessed.
    public func takeGuessRequest() -> GuessRequest? {
        guard guessInFlight == nil, let watch = guessWatch, clock.now.timeIntervalSince(watch.since) >= Self.guessAfter,
              guessCache[watch.key] == nil
        else { return nil }
        let choices = activeProjects.map { GuessRequest.Choice(id: $0.id, name: $0.name) }
        guard !choices.isEmpty else { return nil }
        guessInFlight = watch.key
        return GuessRequest(key: watch.key, projects: choices)
    }

    /// Yes to "Is this <Project>?": counts as a correction, so it then offers Always.
    public func confirmGuess() throws {
        guard let match = now.match, match.basis == .guess else { throw Failure.noOffer }
        try correctNow(.project(match.project))
    }

    /// Writes an API call to the audit log and the spend meter. A lost line never blocks anything.
    public func recordAPICall(_ call: APICall) {
        apiSpendSinceLaunch += call.costUSD
        try? store.audit(call)
    }

    func guessKey(for window: ActiveWindow) -> GuessKey? {
        guard !window.isExcluded, let title = window.title, !title.isEmpty else { return nil }
        return GuessKey(bundleID: window.app.bundleID, title: title)
    }

    /// The cached guess for this window, if Haiku named an active Project.
    func guessMatch(for window: ActiveWindow) -> Now.Match? {
        guard let key = guessKey(for: window), case let .some(project?) = guessCache[key],
              projectsByID[project]?.status == .active
        else { return nil }
        return Now.Match(project: project, basis: .guess)
    }

    /// Times how long Now has sat on one unplaced window, for `takeGuessRequest`.
    func trackGuessWatch(placed: Bool) {
        guard !placed, !now.isAway, let window = now.window, let key = guessKey(for: window) else {
            guessWatch = nil
            return
        }
        if guessWatch?.key != key { guessWatch = (key, clock.now) }
    }
}
