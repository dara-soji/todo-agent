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
        case projectGuess, nextTieBreak
    }

    /// What kind of content was sent, never the content itself.
    public enum ContentKind: String, Sendable, Codable {
        case screenshotAndProjectNames, taskTitles
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

/// Names made distinct for a model to choose among: repeats are numbered "Name (2)", "Name (3)".
func uniqueLabels(_ names: [String]) -> [String] {
    var seen: [String: Int] = [:]
    return names.map { name in
        seen[name, default: 0] += 1
        return seen[name]! == 1 ? name : "\(name) (\(seen[name]!))"
    }
}

/// Port: one screenshot of the window a guess is for, as PNG data in memory. The helper's adapter
/// uses ScreenCaptureKit; tests use a fake.
@MainActor
public protocol ScreenshotCapturer: AnyObject {
    func capture(_ key: GuessKey) async throws -> Data
}

/// Port: asks a model which of `choices` the screenshot shows, or `none`. Throws for any failure,
/// a refusal or a cut-off answer: those are not answers.
@MainActor
public protocol ModelClient: AnyObject {
    func chooseProject(screenshot: Data, choices: [String], none: String) async throws -> ModelAnswer
}

public struct ModelAnswer: Sendable {
    public let choice: String
    /// The call as the audit log keeps it.
    public let call: APICall?

    public init(choice: String, call: APICall?) {
        self.choice = choice
        self.call = call
    }
}

/// Makes the screenshot guesses Now asks for: takes the request, captures the window, checks the
/// window is still the one in front and unplaced before anything is sent, asks the model, and
/// records the call. Only the screenshot and Project names leave the Mac.
@MainActor
public final class GuessRunner {
    static let none = "No Project"

    private let assistant: Assistant
    private let capturer: ScreenshotCapturer
    private let model: ModelClient

    public init(assistant: Assistant, capturer: ScreenshotCapturer, model: ModelClient) {
        self.assistant = assistant
        self.capturer = capturer
        self.model = model
    }

    public func run() async {
        guard let request = assistant.takeGuessRequest() else { return }
        let labels = Self.labels(for: request.projects)
        do {
            let screenshot = try await capturer.capture(request.key)
            // The window may have changed, or become Excluded, while it was captured: send nothing.
            guard assistant.isUnplaced(request.key) else { return assistant.guessFailed(request.key) }
            let answer = try await model.chooseProject(screenshot: screenshot, choices: labels, none: Self.none)
            if let call = answer.call { assistant.recordAPICall(call) }
            let project = zip(labels, request.projects).first { $0.0 == answer.choice }?.1.id
            assistant.applyGuess(request.key, project: project)
        } catch {
            assistant.guessFailed(request.key)
        }
    }

    /// One distinct label per Project: twins are numbered, and none can be mistaken for "No Project".
    static func labels(for projects: [GuessRequest.Choice]) -> [String] {
        uniqueLabels(projects.map { $0.name == none ? "\($0.name) (Project)" : $0.name })
    }
}

extension Assistant {
    /// Unmatched this long on one app and title, and one screenshot guess is asked for.
    static let guessAfter: TimeInterval = 2 * 60

    /// A guess still in flight after this long is given up on (a capture or call that never returned).
    static let guessGivesUpAfter: TimeInterval = 2 * 60
    /// After a failure, the same window is tried again no sooner than this.
    static let guessRetryAfter: TimeInterval = 10 * 60
    /// Guesses kept in memory; beyond this the oldest go.
    static let guessCacheLimit = 500

    /// The screenshot guess to make now, if any; taking it marks it in flight so it is made once.
    /// Only for a stable window that nothing else places: not matched, Neutral, Excluded, corrected,
    /// Away, or already guessed.
    func takeGuessRequest() -> GuessRequest? {
        if let flight = guessInFlight, clock.now.timeIntervalSince(flight.since) >= Self.guessGivesUpAfter {
            guessFailed(flight.key)
        }
        guard guessInFlight == nil, let watch = guessWatch, clock.now.timeIntervalSince(watch.since) >= Self.guessAfter,
              guessCache[watch.key] == nil, (guessRetryAt[watch.key] ?? .distantPast) <= clock.now
        else { return nil }
        let choices = activeProjects.map { GuessRequest.Choice(id: $0.id, name: $0.name) }
        guard !choices.isEmpty else { return nil }
        guessInFlight = (watch.key, clock.now)
        return GuessRequest(key: watch.key, projects: choices)
    }

    /// Whether the window in front is still `key` and still placed by nothing.
    func isUnplaced(_ key: GuessKey) -> Bool {
        guard let window = now.window, guessKey(for: window) == key else { return false }
        return now.match == nil && now.neutral == nil && correction == nil && !now.isAway
    }

    /// Haiku's answer for a window: a Project, or nil for none. Cached by app and title.
    func applyGuess(_ key: GuessKey, project: Project.ID?) {
        if guessInFlight?.key == key { guessInFlight = nil }
        if guessCache.count >= Self.guessCacheLimit, let oldest = guessOrder.first {
            guessCache[oldest] = nil
            guessOrder.removeFirst()
        }
        guessCache[key] = .some(project)
        guessOrder.append(key)
        resolve(now.visit)
    }

    /// No answer this time (a failure, a refusal, or the window moved): try again later.
    func guessFailed(_ key: GuessKey) {
        if guessInFlight?.key == key { guessInFlight = nil }
        guessRetryAt[key] = clock.now + Self.guessRetryAfter
    }

    /// Projects changed: windows answered "none", or guessed to a Project now gone, get another look.
    func forgetStaleGuesses() {
        for (key, answer) in guessCache {
            let stillGood = answer.flatMap { projectsByID[$0]?.status == .active } ?? false
            if !stillGood { guessCache.removeValue(forKey: key) }
        }
        guessOrder.removeAll { guessCache[$0] == nil }
    }

    /// Yes to "Is this <Project>?": counts as a correction, so it then offers Always.
    public func confirmGuess() throws {
        guard let match = now.match, match.isGuess else { throw Failure.noOffer }
        try correctNow(.project(match.project))
    }

    /// Writes an API call to the audit log and the spend meter. A lost line never blocks anything.
    public func recordAPICall(_ call: APICall) {
        rollSpendDay()
        apiSpend.today += call.costUSD
        try? store.audit(call)
    }

    /// What the Claude API has cost today, from the audit log.
    public var apiSpendToday: Double {
        rollSpendDay()
        return apiSpend.today
    }

    private func rollSpendDay() {
        let day = calendar.startOfDay(for: clock.now)
        guard day != apiSpend.day else { return }
        apiSpend = (day, (try? store.apiSpend(since: day)) ?? 0)
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
