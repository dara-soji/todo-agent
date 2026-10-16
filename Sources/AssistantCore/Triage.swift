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

/// One email Dara sent: only who it went to, and when. Recent recipients are VIPs.
public struct SentMail: Equatable, Sendable {
    /// To and Cc, as written, e.g. "Alex <alex@friend.example>".
    public let to: [String]
    public let at: Date
    /// The thread it replied on, if known: Dara's reply settles that thread's Suggestion or Task.
    public let threadID: String?

    public init(to: [String], at: Date, threadID: String? = nil) {
        self.to = to
        self.at = at
        self.threadID = threadID
    }
}

/// New mail since a cursor, and the cursor to resume from once it has all been handled.
public struct MailBatch: Sendable {
    public let messages: [EmailMessage]
    public let sent: [SentMail]
    /// False when sent mail couldn't be read: the cursor then stays, so no reply of Dara's is missed.
    public let sentComplete: Bool
    public let cursor: String

    public init(messages: [EmailMessage], sent: [SentMail] = [], sentComplete: Bool = true, cursor: String) {
        self.messages = messages
        self.sent = sent
        self.sentComplete = sentComplete
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
    /// Which of these threads still have unread mail; the rest Dara has read in Gmail (or deleted).
    func unreadThreads(among threadIDs: [String]) async throws -> Set<String>
    /// Mail Dara sent in the last 90 days, recipients and dates only: asked for once, while no
    /// recent recipients are known.
    func recentlySent() async throws -> [SentMail]
}

/// Port: a macOS notification. Only for a VIP's Action due today or tomorrow.
@MainActor
public protocol Notifier: AnyObject {
    func notify(title: String, body: String)
}

/// How Triage sorts an email.
public enum EmailTier: String, Sendable, Codable, CaseIterable {
    /// Dara needs to do something: becomes a Suggestion.
    case action
    /// For the Digest (ticket 14).
    case worthKnowing
    case noise
}

/// A Worth-knowing email as the Digest shows it: who, what and why, never the body. One per thread.
/// A cleared line is kept until its day is up, so the same email can't bring it back.
public struct DigestLine: Equatable, Sendable, Codable {
    public let threadID: String
    public let from: String
    public let subject: String
    public let reason: String
    public let backLink: String
    public let receivedAt: Date
    /// Read in Gmail, promoted, overtaken by a Suggestion, or its sender Excluded.
    public var cleared: Bool
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
        /// Settled by Dara replying in Gmail: a later ask on the thread can still become a Suggestion.
        case replied
        /// A sheet row as it was when the sheet was first read: never offered, but an edit to it is.
        case seen
        /// Left unanswered for `Assistant.suggestionsExpireAfter`.
        case expired
    }

    public let id: ID
    /// Its Source key, one Suggestion per key: a Gmail thread id, or "sheet:<id>:<row>".
    public let threadID: String
    public var title: String
    /// Why Triage made it, in one line.
    public var reason: String
    public let source: Task.Source
    /// Moves with a sheet row.
    public var backLink: String
    /// Guessed from the email; shown "(guessed)" and applied only on accept.
    public var guessedDeadline: Date?
    public let created: Date
    public var status: Status
    /// The sender, for "Never from this sender".
    public let from: String?
    /// When the latest inbox message on its thread arrived: a reply from Dara after this settles it.
    public var messageAt: Date?
    /// The Task it became, once accepted.
    public var task: Task.ID?
    /// Dara's latest reply on the thread, once handled.
    public var repliedAt: Date?
    /// The reply Dara last answered "Not yet" to.
    public var notYetAt: Date?
    /// For a sheet row, its cells as last read: an edit is any change to them.
    public var fingerprint: String?
    /// For a sheet row, where it is now; nil once the row is gone.
    public var row: Int?
    /// For a note, the Apple Notes folders it is in, outermost first.
    public var notesFolder: [String]?
    /// For a note, actions already handled by an earlier Task: never put in the title again.
    public var handledActions: [String]?

    init(
        id: ID, threadID: String, title: String, reason: String, source: Task.Source, backLink: String,
        guessedDeadline: Date?, created: Date, status: Status, from: String? = nil, messageAt: Date? = nil,
        task: Task.ID? = nil, repliedAt: Date? = nil, notYetAt: Date? = nil, fingerprint: String? = nil, row: Int? = nil, notesFolder: [String]? = nil,
        handledActions: [String]? = nil
    ) {
        self.notesFolder = notesFolder
        self.handledActions = handledActions
        self.fingerprint = fingerprint
        self.row = row
        self.repliedAt = repliedAt
        self.notYetAt = notYetAt
        self.id = id
        self.threadID = threadID
        self.title = title
        self.reason = reason
        self.source = source
        self.backLink = backLink
        self.guessedDeadline = guessedDeadline
        self.created = created
        self.status = status
        self.from = from
        self.messageAt = messageAt
        self.task = task
    }

    /// Suggestions stored before these fields existed still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(ID.self, forKey: .id), threadID: try c.decode(String.self, forKey: .threadID),
            title: try c.decode(String.self, forKey: .title), reason: try c.decode(String.self, forKey: .reason),
            source: try c.decode(Task.Source.self, forKey: .source), backLink: try c.decode(String.self, forKey: .backLink),
            guessedDeadline: try c.decodeIfPresent(Date.self, forKey: .guessedDeadline),
            created: try c.decode(Date.self, forKey: .created), status: try c.decode(Status.self, forKey: .status),
            from: try c.decodeIfPresent(String.self, forKey: .from),
            messageAt: try c.decodeIfPresent(Date.self, forKey: .messageAt),
            task: try c.decodeIfPresent(Task.ID.self, forKey: .task),
            repliedAt: try c.decodeIfPresent(Date.self, forKey: .repliedAt),
            notYetAt: try c.decodeIfPresent(Date.self, forKey: .notYetAt),
            fingerprint: try c.decodeIfPresent(String.self, forKey: .fingerprint),
            row: try c.decodeIfPresent(Int.self, forKey: .row),
            notesFolder: try c.decodeIfPresent([String].self, forKey: .notesFolder),
            handledActions: try c.decodeIfPresent([String].self, forKey: .handledActions))
    }
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
    private let notifier: Notifier?
    private var running = false
    /// The 90-day sent-mail read has been done this run of the helper.
    private var backfilledRecipients = false
    /// Message ids already sorted this run of the helper, so a retried batch skips them.
    private var sorted: Set<String> = []
    static let sortedLimit = 5_000

    public init(assistant: Assistant, mail: MailSource, triager: EmailTriager, notifier: Notifier? = nil) {
        self.assistant = assistant
        self.mail = mail
        self.triager = triager
        self.notifier = notifier
    }

    public func run() async {
        guard !running else { return }
        running = true
        defer { running = false }
        assistant.expireSuggestions()
        assistant.expireDigest()
        let batch: MailBatch
        do {
            batch = try await mail.fetchNew(after: assistant.mailCursor)
        } catch {
            return NSLog("TodoAgent: mail fetch failed: \(type(of: error))")
        }
        // Recipients first, so someone Dara just wrote to is already a VIP for this batch.
        var sent = batch.sent
        if !backfilledRecipients, assistant.knowsNoRecipients {
            do {
                sent += try await mail.recentlySent()
                backfilledRecipients = true
            } catch {
                NSLog("TodoAgent: reading sent mail failed: \(type(of: error))")
            }
        }
        assistant.recordRecipients(sent)
        var handledAll = batch.sentComplete
        for message in batch.messages {
            // A new message on an accepted Task's thread only marks it: no model call.
            assistant.noteNewMessage(message)
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
                switch answer.tier {
                case .action:
                    let (suggestion, isNew) = try assistant.suggest(from: message, answer)
                    if isNew, assistant.shouldNotify(suggestion, from: message.from) {
                        notifier?.notify(title: suggestion.title, body: "\(message.from) · \(message.subject)")
                    }
                case .worthKnowing:
                    // A follow-up on a thread already in hand doesn't also join the Digest.
                    if !assistant.threadIsInHand(message.threadID) { try assistant.addToDigest(message, reason: answer.reason) }
                case .noise:
                    break
                }
                remember(message)
            } catch let billed as BilledFailure {
                assistant.recordAPICall(billed.call)
                remember(message)
            } catch {
                handledAll = false
            }
        }
        // After the batch, so a reply settles a Suggestion made from mail read in the same batch.
        for reply in sent { assistant.daraReplied(reply) }
        if handledAll { assistant.advanceMailCursor(to: batch.cursor) }
        await clearReadDigestLines()
    }

    /// Lines whose thread Dara has since read in Gmail leave the Digest.
    private func clearReadDigestLines() async {
        let threads = assistant.digestThreads
        guard !threads.isEmpty, let unread = try? await mail.unreadThreads(among: threads) else { return }
        assistant.clearDigest(threads.filter { !unread.contains($0) })
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
            .sorted { a, b in
                // Made together (a sheet's rows): in row order, then by key.
                if a.created != b.created { return a.created < b.created }
                if a.row != b.row { return (a.row ?? 0) < (b.row ?? 0) }
                return a.threadID < b.threadID
            }
    }

    /// Whether Haiku should see this email: inbox mail Dara didn't send, not from an Excluded sender,
    /// on a thread with no Suggestion yet, and not bulk by rule unless it is from a VIP.
    func needsTriage(_ message: EmailMessage) -> Bool {
        let labels = Set(message.labels)
        guard labels.contains("INBOX"), !labels.contains("SENT"), !isExcluded(sender: message.from),
              !isNoise(sender: message.from), threadIsOpenToTriage(message.threadID)
        else { return false }
        let bulk = !labels.isDisjoint(with: Self.bulkCategories) || message.hasListUnsubscribe || Self.isNoReply(message.from)
        return !bulk || isVIP(sender: message.from)
    }

    /// no-reply@, noreply@, donotreply@, do-not-reply@ and the like.
    static func isNoReply(_ sender: String) -> Bool {
        let local = address(in: sender).split(separator: "@").first.map(String.init) ?? ""
        let squashed = local.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "")
        return squashed.contains("noreply") || squashed.contains("donotreply")
    }

    /// Whether a new message on this thread goes to Haiku: no Suggestion yet; an open one, to update
    /// it; one settled by Dara's reply, or accepted with its Task done, dropped or deleted, for a fresh
    /// ask. A dismissed or expired thread stays quiet, and a live Task's thread is only marked
    /// "new reply".
    func threadIsOpenToTriage(_ thread: String) -> Bool {
        guard let suggestion = suggestionsByThread[thread] else { return true }
        switch suggestion.status {
        case .open, .replied, .seen: return true
        case .dismissed, .expired: return false
        case .accepted: return liveTask(of: suggestion) == nil
        }
    }

    /// An open Suggestion or a live Task on the thread.
    func threadIsInHand(_ thread: String) -> Bool {
        guard let suggestion = suggestionsByThread[thread] else { return false }
        return suggestion.status == .open || liveTask(of: suggestion) != nil
    }

    /// The accepted Suggestion's Task, while it is still in play. Suggestions accepted before they
    /// kept their Task are matched by back-link.
    func liveTask(of suggestion: Suggestion) -> Task? {
        guard suggestion.status == .accepted else { return nil }
        let found = suggestion.task.flatMap { tasksByID[$0] }
            ?? tasksByID.values.filter { $0.backLink == suggestion.backLink }.max { $0.created < $1.created }
        guard let task = found, task.deletedAt == nil else { return nil }
        switch task.status {
        case .done, .dropped: return nil
        case .open, .committed, .snoozed: return task
        }
    }

    /// Whether a Suggestion is waiting in an Ask: Triage then leaves it as it was held.
    private func isHeld(_ suggestion: Suggestion) -> Bool {
        asks.contains { $0.touches.contains(suggestion.id.rawValue) }
    }

    /// Makes the Action email's Suggestion, or brings the thread's open one up to date with the new
    /// message, and clears the thread's Digest line. True when it is a new Suggestion.
    @discardableResult
    func suggest(from message: EmailMessage, _ answer: TriageAnswer) throws -> (Suggestion, isNew: Bool) {
        let summary = answer.summary.split(whereSeparator: \.isNewline).first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let full = summary.isEmpty ? message.subject : summary
        let title = full.count <= Self.suggestionTitleLimit ? full : full.prefix(Self.suggestionTitleLimit - 1) + "…"
        if var open = suggestionsByThread[message.threadID], open.status == .open {
            guard !isHeld(open) else { return (open, false) }
            open.title = title
            open.reason = answer.reason
            open.guessedDeadline = answer.deadline ?? open.guessedDeadline
            open.messageAt = max(open.messageAt ?? .distantPast, message.receivedAt)
            try writeUnlogged(Change(suggestions: [open], digest: clearing([message.threadID])))
            return (open, false)
        }
        let suggestion = Suggestion(
            id: Suggestion.ID(), threadID: message.threadID, title: title, reason: answer.reason, source: .email,
            backLink: Self.gmailLink(message.threadID), guessedDeadline: answer.deadline, created: clock.now,
            status: .open, from: message.from, messageAt: message.receivedAt)
        try writeUnlogged(Change(suggestions: [suggestion], digest: clearing([message.threadID])))
        return (suggestion, true)
    }

    /// An inbox message on a live Task's thread moves the thread's latest-message time on, which
    /// marks the Task "new reply" until Dara replies. Archiving, which only takes the inbox label
    /// away, changes nothing. The Task itself isn't written, so nothing Dara can undo or confirm is.
    func noteNewMessage(_ message: EmailMessage) {
        let labels = Set(message.labels)
        guard labels.contains("INBOX"), !labels.contains("SENT"), !isExcluded(sender: message.from),
              var suggestion = suggestionsByThread[message.threadID], liveTask(of: suggestion) != nil,
              message.receivedAt > suggestion.messageAt ?? suggestion.created
        else { return }
        suggestion.messageAt = message.receivedAt
        try? writeUnlogged(Change(suggestions: [suggestion]))
    }

    /// A new message arrived on the Task's email thread since Dara last replied.
    public func hasNewReply(_ id: Task.ID) -> Bool {
        guard let task = tasksByID[id], let suggestion = acceptedSuggestion(of: task),
              let latest = suggestion.messageAt
        else { return false }
        return latest > max(task.created, suggestion.repliedAt ?? .distantPast)
    }

    private func acceptedSuggestion(of task: Task) -> Suggestion? {
        suggestionsByThread.values.first { $0.status == .accepted && ($0.task == task.id || ($0.task == nil && $0.backLink == task.backLink)) }
    }

    /// Dara replied on a thread. An open Suggestion from before the reply is settled, quietly. On a
    /// live Task's thread, a reply after the latest message asks "Done?" and clears "new reply". Each
    /// reply is handled once, so a retried batch doesn't ask again.
    func daraReplied(_ reply: SentMail) {
        guard let thread = reply.threadID, var suggestion = suggestionsByThread[thread], !isHeld(suggestion),
              reply.at > suggestion.repliedAt ?? .distantPast
        else { return }
        let latest = suggestion.messageAt ?? suggestion.created
        if suggestion.status == .open {
            guard reply.at >= latest else { return }
            suggestion.status = .replied
        } else if let task = liveTask(of: suggestion) {
            guard reply.at >= max(latest, task.created) else { return }
        } else {
            return
        }
        suggestion.repliedAt = reply.at
        try? writeUnlogged(Change(suggestions: [suggestion]))
    }

    /// "Done?" for each live Task whose thread Dara replied on, until answered.
    var doneDecisions: [Decision] {
        suggestionsByThread.values.compactMap { suggestion -> (Date, Task.ID)? in
            guard let replied = suggestion.repliedAt, replied > suggestion.notYetAt ?? .distantPast,
                  let task = liveTask(of: suggestion), [.open, .committed].contains(task.status)
            else { return nil }
            return (replied, task.id)
        }
        .sorted { $0.0 < $1.0 }
        .map { .isItDone($0.1) }
    }

    /// "Not yet" to "Done?": asked again only after another reply.
    public func notDoneYet(_ id: Task.ID) {
        guard let task = tasksByID[id], var suggestion = acceptedSuggestion(of: task) else { return }
        suggestion.notYetAt = suggestion.repliedAt
        try? writeUnlogged(Change(suggestions: [suggestion]))
    }

    /// "Never from this sender" was chosen for this sender.
    public func isNoise(sender: String) -> Bool {
        let address = Self.address(in: sender)
        return noiseSenders.contains { Self.address(address, matches: $0) }
    }

    public var noiseSenders: [String] { settings.noiseSenders }

    /// Takes a sender off "Never from this sender": their mail is triaged again.
    @discardableResult
    public func forgetNoiseSender(_ sender: String, by startedBy: StartedBy = .dara) throws -> Outcome {
        let address = Self.address(in: sender)
        guard noiseSenders.contains(address) else { throw Failure.notANoiseSender(address) }
        return try perform(.forgetNoiseSender, "Triaging mail from \(address) again", by: startedBy,
                           writing: changingSettings { $0.noiseSenders.removeAll { $0 == address } })
    }

    /// A Source's newer title and deadline for a Task, run as the helper. A title Dara set is kept.
    @discardableResult
    public func updateFromSource(_ id: Task.ID, title: String?, deadline: Date?) throws -> Task? {
        _ = try sourceUpdate(id, title: title, deadline: deadline)
        return tasksByID[id]
    }

    /// True once the Task matches its Source: updated now, or nothing to change. False when the
    /// update is waiting in an Ask.
    func sourceUpdate(_ id: Task.ID, title: String?, deadline: Date? = nil, backLink: String? = nil) throws -> Bool {
        guard var task = tasksByID[id] else { throw Failure.unknownTask(id) }
        if let title, !task.titleSetByDara, let trimmed = try? Self.nonEmpty(title, else: .emptyTitle) { task.title = trimmed }
        if let deadline { task.deadline = deadline }
        if let backLink { task.backLink = backLink }
        guard task != tasksByID[id] else { return true }
        let outcome = try perform(.sourceUpdate, "Updated “\(task.title)” from its Source", by: .helper, writing: Change(tasks: [task]))
        if case .ran = outcome { return true }
        return false
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
        let task = Task(
            id: Task.ID(), title: suggestion.title, source: suggestion.source, backLink: suggestion.backLink,
            status: .open, created: clock.now, deadline: suggestion.guessedDeadline, project: nil, effort: nil, kind: nil)
        suggestion.status = .accepted
        suggestion.task = task.id
        return try perform(.acceptSuggestion, "Accepted “\(suggestion.title)”", by: startedBy,
                           writing: Change(tasks: [task], suggestions: [suggestion]))
    }

    /// Dismisses a Suggestion. With `neverFromSender`, that sender's mail is Noise from now on;
    /// nothing is learnt otherwise.
    @discardableResult
    public func dismissSuggestion(
        _ id: Suggestion.ID, neverFromSender: Bool = false, by startedBy: StartedBy = .dara
    ) throws -> Outcome {
        var suggestion = try openSuggestion(id)
        suggestion.status = .dismissed
        var change = Change(suggestions: [suggestion])
        var summary = "Dismissed “\(suggestion.title)”"
        if neverFromSender, let from = suggestion.from {
            let address = Self.address(in: from)
            if !noiseSenders.contains(address) { change.settings = changingSettings { $0.noiseSenders.append(address) }.settings }
            summary += ", never from this sender"
        }
        return try perform(.dismissSuggestion, summary, by: startedBy, writing: change)
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
