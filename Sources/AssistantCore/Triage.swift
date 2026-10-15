import Foundation

/// One email's headers and labels, as the Gmail adapter lists it. Its body is read separately, and
/// only once the rules let it through; only `TriageInput` ever leaves the Mac, and no body is stored.
public struct EmailMessage: Equatable, Sendable {
    public let threadID: String
    public let messageID: String
    /// The From header, e.g. "Sam <sam@work.example>".
    public let from: String
    public let subject: String
    /// Gmail label ids, e.g. "INBOX", "SENT", "CATEGORY_PROMOTIONS".
    public let labels: [String]
    public let hasListUnsubscribe: Bool
    public let receivedAt: Date

    public init(
        threadID: String, messageID: String, from: String, subject: String, labels: [String],
        hasListUnsubscribe: Bool, receivedAt: Date
    ) {
        self.threadID = threadID
        self.messageID = messageID
        self.from = from
        self.subject = subject
        self.labels = labels
        self.hasListUnsubscribe = hasListUnsubscribe
        self.receivedAt = receivedAt
    }
}

/// New mail since a cursor, and the cursor to resume from once it has all been handled.
public struct MailBatch: Sendable {
    public let messages: [EmailMessage]
    public let cursor: String

    public init(messages: [EmailMessage], cursor: String) {
        self.messages = messages
        self.cursor = cursor
    }
}

/// Port: the mailbox. With no cursor it starts a few days back; otherwise it returns what arrived
/// after the cursor, headers only.
@MainActor
public protocol MailSource: AnyObject {
    func fetchNew(after cursor: String?) async throws -> MailBatch
    /// One message's plain-text body, attachments left out. Asked for only for mail Triage sends.
    func plainText(of message: EmailMessage) async throws -> String
}

/// How Triage sorts an email.
public enum EmailTier: String, Sendable, Codable, CaseIterable {
    /// Dara needs to do something: becomes a Suggestion.
    case action
    /// For the Digest (ticket 14).
    case worthKnowing
    case noise
}

/// Everything Haiku sees of one email.
public struct TriageInput: Equatable, Sendable {
    public let from: String
    public let subject: String
    /// The start of the plain text, at most `TriageRunner.excerptLimit` characters.
    public let excerpt: String
    /// When it arrived, so "by Friday" can be read as a date.
    public let receivedAt: Date
}

public struct TriageAnswer: Sendable {
    public let tier: EmailTier
    /// For an Action email, the Task it asks for, as a short title.
    public let summary: String
    public let reason: String
    public let deadline: Date?
    public let call: APICall?

    public init(tier: EmailTier, summary: String, reason: String, deadline: Date?, call: APICall?) {
        self.tier = tier
        self.summary = summary
        self.reason = reason
        self.deadline = deadline
        self.call = call
    }
}

/// Port: sorts one email. Throws for anything that isn't an answer.
@MainActor
public protocol EmailTriager: AnyObject {
    func triage(_ input: TriageInput) async throws -> TriageAnswer
}

/// A Task Triage proposes from an Action email: Dara accepts or dismisses it. One per thread, ever.
public struct Suggestion: Identifiable, Equatable, Sendable, Codable {
    public struct ID: Hashable, Sendable, Codable {
        public let rawValue: UUID
        public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
    }

    public enum Status: String, Sendable, Codable {
        case open, accepted, dismissed
        /// Left unanswered for `Assistant.suggestionsExpireAfter`.
        case expired
    }

    public let id: ID
    public let threadID: String
    public let title: String
    /// Why Triage made it, in one line.
    public let reason: String
    public let source: Task.Source
    public let backLink: String
    /// Guessed from the email; shown "(guessed)" and applied only on accept.
    public let guessedDeadline: Date?
    public let created: Date
    public var status: Status
}

/// Reads new mail, drops bulk mail and Excluded senders by rule (their bodies are never read), has
/// Haiku sort the rest, and turns Action emails into Suggestions. The cursor only moves on once
/// every email in the batch was handled, so nothing is missed after a network failure, sleep or
/// restart. A billed non-answer (a refusal, say) counts as handled: retrying it would only fail and
/// cost again. Emails already sorted are remembered, so a retried batch isn't sent twice.
@MainActor
public final class TriageRunner {
    /// How much of the plain text Haiku sees.
    public static let excerptLimit = 2_048

    private let assistant: Assistant
    private let mail: MailSource
    private let triager: EmailTriager
    private var running = false
    /// Message ids already sorted this run of the helper, so a retried batch skips them.
    private var sorted: Set<String> = []
    static let sortedLimit = 5_000

    public init(assistant: Assistant, mail: MailSource, triager: EmailTriager) {
        self.assistant = assistant
        self.mail = mail
        self.triager = triager
    }

    public func run() async {
        guard !running else { return }
        running = true
        defer { running = false }
        assistant.expireSuggestions()
        let batch: MailBatch
        do {
            batch = try await mail.fetchNew(after: assistant.mailCursor)
        } catch {
            return NSLog("TodoAgent: mail fetch failed: \(type(of: error))")
        }
        var handledAll = true
        for message in batch.messages {
            // Checked as each email comes up: the exclude list can change mid-batch.
            guard !sorted.contains(message.messageID), assistant.needsTriage(message) else { continue }
            do {
                let text = try await mail.plainText(of: message)
                // Checked again: the list may have changed while the body was read.
                guard assistant.needsTriage(message) else { continue }
                let input = TriageInput(
                    from: message.from, subject: message.subject, excerpt: String(text.prefix(Self.excerptLimit)),
                    receivedAt: message.receivedAt)
                let answer = try await triager.triage(input)
                if let call = answer.call { assistant.recordAPICall(call) }
                if answer.tier == .action { try assistant.suggest(from: message, answer) }
                remember(message)
            } catch let billed as BilledFailure {
                assistant.recordAPICall(billed.call)
                remember(message)
            } catch {
                handledAll = false
            }
        }
        if handledAll { assistant.advanceMailCursor(to: batch.cursor) }
    }
}

extension TriageRunner {
    private func remember(_ message: EmailMessage) {
        if sorted.count >= Self.sortedLimit { sorted.removeAll() }
        sorted.insert(message.messageID)
    }
}

extension Assistant {
    /// An unanswered Suggestion quietly goes after this long.
    static let suggestionsExpireAfter: TimeInterval = 7 * 24 * 60 * 60
    /// Gmail's bulk categories: never sent to Haiku.
    static let bulkCategories: Set<String> = ["CATEGORY_PROMOTIONS", "CATEGORY_SOCIAL", "CATEGORY_FORUMS"]
    /// The longest Suggestion title kept.
    static let suggestionTitleLimit = 120

    /// Open Suggestions, oldest first. One already waiting in an Ask isn't offered again.
    public var suggestions: [Suggestion] {
        let held = asks.reduce(into: Set<UUID>()) { $0.formUnion($1.touches) }
        return suggestionsByThread.values.filter { $0.status == .open && !held.contains($0.id.rawValue) }
            .sorted { $0.created < $1.created }
    }

    /// Whether Haiku should see this email: inbox mail Dara didn't send, not bulk by rule, not from
    /// an Excluded sender, on a thread with no Suggestion yet.
    func needsTriage(_ message: EmailMessage) -> Bool {
        let labels = Set(message.labels)
        guard labels.contains("INBOX"), !labels.contains("SENT"), labels.isDisjoint(with: Self.bulkCategories),
              !message.hasListUnsubscribe, !Self.isNoReply(message.from), !isExcluded(sender: message.from)
        else { return false }
        return suggestionsByThread[message.threadID] == nil
    }

    /// no-reply@, noreply@, donotreply@, do-not-reply@ and the like.
    static func isNoReply(_ sender: String) -> Bool {
        let local = address(in: sender).split(separator: "@").first.map(String.init) ?? ""
        let squashed = local.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "")
        return squashed.contains("noreply") || squashed.contains("donotreply")
    }

    /// Makes the Action email's Suggestion. `needsTriage` has already checked its thread has none.
    func suggest(from message: EmailMessage, _ answer: TriageAnswer) throws {
        let summary = answer.summary.split(whereSeparator: \.isNewline).first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let title = summary.isEmpty ? message.subject : summary
        let suggestion = Suggestion(
            id: Suggestion.ID(), threadID: message.threadID,
            title: title.count <= Self.suggestionTitleLimit ? title : title.prefix(Self.suggestionTitleLimit - 1) + "…",
            reason: answer.reason, source: .email, backLink: Self.gmailLink(message.threadID),
            guessedDeadline: answer.deadline, created: clock.now, status: .open)
        try writeUnlogged(Change(suggestions: [suggestion]))
    }

    static func gmailLink(_ threadID: String) -> String {
        let id = threadID.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_"))) ?? threadID
        return "https://mail.google.com/mail/u/0/#all/\(id)"
    }

    func advanceMailCursor(to cursor: String) {
        try? writeUnlogged(Change(mailCursor: cursor))
    }

    /// Accepts a Suggestion: it becomes a Task, with the guessed deadline, linked to the thread.
    @discardableResult
    public func acceptSuggestion(_ id: Suggestion.ID, by startedBy: StartedBy = .dara) throws -> Outcome {
        var suggestion = try openSuggestion(id)
        suggestion.status = .accepted
        let task = Task(
            id: Task.ID(), title: suggestion.title, source: suggestion.source, backLink: suggestion.backLink,
            status: .open, created: clock.now, deadline: suggestion.guessedDeadline, project: nil, effort: nil, kind: nil)
        return try perform(.acceptSuggestion, "Accepted “\(suggestion.title)”", by: startedBy,
                           writing: Change(tasks: [task], suggestions: [suggestion]))
    }

    @discardableResult
    public func dismissSuggestion(_ id: Suggestion.ID, by startedBy: StartedBy = .dara) throws -> Outcome {
        var suggestion = try openSuggestion(id)
        suggestion.status = .dismissed
        return try perform(.dismissSuggestion, "Dismissed “\(suggestion.title)”", by: startedBy,
                           writing: Change(suggestions: [suggestion]))
    }

    private func openSuggestion(_ id: Suggestion.ID) throws -> Suggestion {
        guard let suggestion = suggestions.first(where: { $0.id == id })
        else { throw Failure.unknownSuggestion(id) }
        return suggestion
    }

    /// Unanswered Suggestions past their week go, without a word. The week runs from when it was made,
    /// or from when an undo last brought it back.
    func expireSuggestions() {
        let due = suggestions.filter { suggestion in
            guard clock.now.timeIntervalSince(suggestion.created) >= Self.suggestionsExpireAfter else { return false }
            let reopened = operationLog.last { entry in
                entry.after.suggestions.contains { $0.id == suggestion.id && $0.status == .open }
            }?.at ?? suggestion.created
            return clock.now.timeIntervalSince(reopened) >= Self.suggestionsExpireAfter
        }
        guard !due.isEmpty else { return }
        try? writeUnlogged(Change(suggestions: due.map { var expired = $0; expired.status = .expired; return expired }))
    }
}
