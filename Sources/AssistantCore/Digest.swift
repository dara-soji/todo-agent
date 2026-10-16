import Foundation

extension Assistant {
    /// The most Digest lines shown.
    static let digestLimit = 5
    /// A Worth-knowing email leaves the Digest this long after it arrived.
    static let digestLastsFor: TimeInterval = 24 * 60 * 60
    /// Anyone Dara emailed within this long is a VIP.
    static let recentRecipientsFor: TimeInterval = 90 * 24 * 60 * 60

    /// Worth-knowing mail, newest first, at most `digestLimit` lines.
    public var digest: [DigestLine] {
        Array(liveDigest.sorted { $0.receivedAt > $1.receivedAt }.prefix(Self.digestLimit))
    }

    /// Every thread with a line, shown or not, to check against Gmail's read state.
    var digestThreads: [String] {
        liveDigest.map(\.threadID).sorted()
    }

    private var liveDigest: [DigestLine] {
        digestByThread.values.filter {
            !$0.cleared && clock.now.timeIntervalSince($0.receivedAt) < Self.digestLastsFor && !isExcluded(sender: $0.from)
        }
    }

    /// Adds a Worth-knowing email to the Digest, replacing an older line on its thread. A line
    /// cleared since is only replaced by a newer email.
    func addToDigest(_ message: EmailMessage, reason: String) throws {
        guard clock.now.timeIntervalSince(message.receivedAt) < Self.digestLastsFor else { return }
        if let line = digestByThread[message.threadID],
           line.cleared ? line.receivedAt >= message.receivedAt : line.receivedAt > message.receivedAt { return }
        let line = DigestLine(
            threadID: message.threadID, from: message.from, subject: message.subject, reason: reason,
            backLink: Self.gmailLink(message.threadID), receivedAt: message.receivedAt, cleared: false)
        try writeUnlogged(Change(digest: [line]))
    }

    /// The live lines on these threads, cleared.
    func clearing(_ threads: [String]) -> [DigestLine] {
        threads.compactMap { digestByThread[$0] }.filter { !$0.cleared }.map { line in
            var cleared = line
            cleared.cleared = true
            return cleared
        }
    }

    func clearDigest(_ threads: [String]) {
        let lines = clearing(threads)
        guard !lines.isEmpty else { return }
        try? writeUnlogged(Change(digest: lines))
    }

    /// Lines past their day, cleared or not, go from the store: no email that old joins the Digest.
    func expireDigest() {
        let due = digestByThread.values.filter { clock.now.timeIntervalSince($0.receivedAt) >= Self.digestLastsFor }
        guard !due.isEmpty else { return }
        try? writeUnlogged(Change(droppedDigest: due.map(\.threadID)))
    }

    /// Lines from senders now Excluded, cleared.
    func clearingExcluded(by exclusions: [Exclusion]) -> [DigestLine] {
        let patterns = exclusions.compactMap { if case let .sender(pattern) = $0 { pattern } else { nil } }
        return clearing(digestByThread.values.filter { line in
            patterns.contains { Self.address(Self.address(in: line.from), matches: $0) }
        }.map(\.threadID))
    }

    /// One click: a Digest line Triage was too lenient about becomes a Suggestion.
    @discardableResult
    public func promoteDigestLine(_ threadID: String, by startedBy: StartedBy = .dara) throws -> Outcome {
        guard let line = liveDigest.first(where: { $0.threadID == threadID }) else { throw Failure.unknownDigestLine(threadID) }
        let suggestion = Suggestion(
            id: Suggestion.ID(), threadID: threadID, title: line.subject.isEmpty ? line.from : line.subject,
            reason: "From the Digest", source: .email, backLink: line.backLink, guessedDeadline: nil,
            created: clock.now, status: .open, from: line.from, messageAt: line.receivedAt)
        return try perform(.promoteDigestLine, "Made “\(suggestion.title)” a Suggestion", by: startedBy,
                           writing: Change(suggestions: [suggestion], digest: clearing([threadID])))
    }

    /// Whether to raise a macOS notification: only a VIP's Action due today or tomorrow.
    func shouldNotify(_ suggestion: Suggestion, from sender: String) -> Bool {
        guard let deadline = suggestion.guessedDeadline, isVIP(sender: sender) else { return false }
        let today = calendar.startOfDay(for: clock.now)
        let afterTomorrow = calendar.date(byAdding: .day, value: 2, to: today)!
        return deadline >= today && deadline < afterTomorrow
    }

    // MARK: VIPs

    /// Dara's own VIP list: addresses, or "@domain" for everyone there.
    public var vips: [String] { settings.vips }

    /// On Dara's list, or emailed by Dara in the last 90 days.
    public func isVIP(sender: String) -> Bool {
        let address = Self.address(in: sender)
        if vips.contains(where: { Self.address(address, matches: $0) }) { return true }
        return recipients[address].map { clock.now.timeIntervalSince($0) <= Self.recentRecipientsFor } ?? false
    }

    @discardableResult
    public func addVIP(_ sender: String, by startedBy: StartedBy = .dara) throws -> Outcome {
        guard case let .sender(vip) = try Exclusion.sender(Self.address(in: sender)).normalised() else {
            throw Failure.notAVIP(sender)
        }
        guard !vips.contains(vip) else { throw Failure.alreadyVIP(vip) }
        return try perform(.addVIP, "Added \(vip) as a VIP", by: startedBy, writing: changingSettings { $0.vips.append(vip) })
    }

    @discardableResult
    public func removeVIP(_ sender: String, by startedBy: StartedBy = .dara) throws -> Outcome {
        let vip = sender.trimmingCharacters(in: .whitespaces).lowercased()
        guard vips.contains(vip) else { throw Failure.notAVIP(vip) }
        return try perform(.removeVIP, "Removed \(vip) as a VIP", by: startedBy,
                           writing: changingSettings { $0.vips.removeAll { $0 == vip } })
    }

    var knowsNoRecipients: Bool { recipients.isEmpty }

    /// Keeps who Dara wrote to and when, the latest per address, for the last 90 days. Excluded
    /// addresses aren't kept.
    func recordRecipients(_ sent: [SentMail]) {
        var updated = recipients.filter { clock.now.timeIntervalSince($0.value) <= Self.recentRecipientsFor }
        for mail in sent where clock.now.timeIntervalSince(mail.at) <= Self.recentRecipientsFor {
            for recipient in mail.to {
                let address = Self.address(in: recipient)
                guard address.contains("@"), !isExcluded(sender: address) else { continue }
                updated[address] = max(updated[address] ?? .distantPast, mail.at)
            }
        }
        guard updated != recipients else { return }
        try? writeUnlogged(Change(recipients: updated))
    }
}
