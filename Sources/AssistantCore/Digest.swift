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
        digestByThread.values.filter { !$0.cleared && clock.now.timeIntervalSince($0.receivedAt) < Self.digestLastsFor }
    }

    /// Adds a Worth-knowing email to the Digest, replacing an older line on its thread.
    func addToDigest(_ message: EmailMessage, reason: String) throws {
        guard clock.now.timeIntervalSince(message.receivedAt) < Self.digestLastsFor else { return }
        if let line = digestByThread[message.threadID], !line.cleared, line.receivedAt > message.receivedAt { return }
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

    /// Lines past their day go from the store too.
    func expireDigest() {
        clearDigest(digestByThread.values
            .filter { !$0.cleared && clock.now.timeIntervalSince($0.receivedAt) >= Self.digestLastsFor }
            .map(\.threadID))
    }

    /// One click: a Digest line Triage was too lenient about becomes a Suggestion.
    @discardableResult
    public func promoteDigestLine(_ threadID: String, by startedBy: StartedBy = .dara) throws -> Outcome {
        guard let line = digest.first(where: { $0.threadID == threadID }) ?? liveDigest.first(where: { $0.threadID == threadID })
        else { throw Failure.unknownDigestLine(threadID) }
        let suggestion = Suggestion(
            id: Suggestion.ID(), threadID: threadID, title: line.subject.isEmpty ? line.from : line.subject,
            reason: "From the Digest", source: .email, backLink: line.backLink, guessedDeadline: nil,
            created: clock.now, status: .open)
        return try perform(.promoteDigestLine, "Made “\(suggestion.title)” a Suggestion", by: startedBy,
                           writing: Change(suggestions: [suggestion], digest: clearing([threadID])))
    }

    /// Whether to raise a macOS notification: only a VIP's Action due today or tomorrow.
    func shouldNotify(_ suggestion: Suggestion, from sender: String) -> Bool {
        guard let deadline = suggestion.guessedDeadline, isVIP(sender: sender) else { return false }
        let today = calendar.startOfDay(for: clock.now)
        let afterTomorrow = calendar.date(byAdding: .day, value: 2, to: today)!
        return deadline < afterTomorrow && deadline >= clock.now - Self.digestLastsFor
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
        guard case let .sender(vip) = try Exclusion.sender(sender).normalised() else { throw Exclusion.Invalid.empty }
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

    /// Keeps who Dara wrote to and when, the latest per address, for the last 90 days.
    func recordRecipients(_ sent: [SentMail]) {
        var updated = recipients.filter { clock.now.timeIntervalSince($0.value) <= Self.recentRecipientsFor }
        for mail in sent where clock.now.timeIntervalSince(mail.at) <= Self.recentRecipientsFor {
            for recipient in mail.to {
                let address = Self.address(in: recipient)
                guard address.contains("@") else { continue }
                updated[address] = max(updated[address] ?? .distantPast, mail.at)
            }
        }
        guard updated != recipients else { return }
        try? writeUnlogged(Change(recipients: updated))
    }
}
