import Foundation

/// One Apple Note as read: its id, folders, title and plain text. The text is only looked through
/// for open actions; it is never stored or sent anywhere.
public struct Note: Equatable, Sendable {
    public let id: String
    /// The folder it is in, and the folders around that one, outermost first.
    public let folders: [String]
    public let title: String
    public let text: String
    public let modified: Date

    public init(id: String, folders: [String], title: String, text: String, modified: Date) {
        self.id = id
        self.folders = folders
        self.title = title
        self.text = text
        self.modified = modified
    }
}

/// What one read of Notes found: the notes changed since the cut-off, the ids of every note still in
/// a readable folder (to notice deleted or moved notes), and when the read began.
public struct NotesRead: Sendable {
    public let notes: [Note]
    public let present: Set<String>
    public let startedAt: Date

    public init(notes: [Note], present: Set<String>, startedAt: Date) {
        self.notes = notes
        self.present = present
        self.startedAt = startedAt
    }
}

/// Port: Apple Notes, read unattended while Dara is logged in. Notes in a `skipping` folder, or in
/// any folder inside one, are never read, not even their titles or ids.
@MainActor
public protocol NotesSource: AnyObject {
    func notes(modifiedSince since: Date?, skippingFolders skipping: [String]) async throws -> NotesRead
}

/// Reads notes changed since the last read and turns their open actions into Suggestions, one per
/// note. Nothing from a note goes to the Claude API.
@MainActor
public final class NotesRunner {
    /// How far back the very first read looks.
    public static let firstReadLooksBack: TimeInterval = 14 * 24 * 60 * 60

    private let assistant: Assistant
    private let notes: NotesSource
    private var running = false

    public init(assistant: Assistant, notes: NotesSource) {
        self.assistant = assistant
        self.notes = notes
    }

    public func run() async {
        guard !running else { return }
        running = true
        defer { running = false }
        let since = assistant.notesCursor ?? assistant.clockNow - Self.firstReadLooksBack
        let read: NotesRead
        do {
            read = try await notes.notes(modifiedSince: since, skippingFolders: assistant.excludedNotesFolders)
        } catch {
            return NSLog("TodoAgent: reading Notes failed: \(type(of: error))")
        }
        assistant.intake(read, readFrom: since)
    }
}

extension Assistant {
    /// Each read of Notes starts this long before the last one began, so an edit made while it ran
    /// isn't missed.
    static let notesOverlap: TimeInterval = 60
    /// The longest Suggestion title kept for a note's first action.
    static let notesTitleLimit = 100

    /// Where Notes has been read up to; nil until the first read, or after a folder stops being Excluded.
    public var notesReadUpTo: Date? { notesCursor }

    var excludedNotesFolders: [String] {
        exclusions.compactMap { if case let .notesFolder(folder) = $0 { folder } else { nil } }.sorted()
    }

    /// Open actions in a note: unticked checklist lines typed as "- [ ]", "[ ]" or "☐", and lines
    /// starting "TODO:" or "To do:". Notes' own checklists don't say in plain text whether an item is
    /// ticked, so they aren't read as actions.
    static func openActions(in text: String) -> [String] {
        let pattern = #"^\s*(?:[-*•]\s*)?(?:\[ \]|☐|\bTODO\s*:|\bTo[ -]?do\s*:)\s*(.+?)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            let line = String(line)
            guard let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let range = Range(match.range(at: 1), in: line)
            else { return nil }
            return String(line[range])
        }
    }

    /// Each note's open actions become, or update, its one Suggestion. An edit updates the open
    /// Suggestion, or the accepted Task (never over a title Dara set); new actions in a note whose
    /// Task is done or dropped become a new Suggestion; a dismissed note stays quiet; a note with no
    /// open actions left, or gone (deleted, or moved somewhere not read), loses its open Suggestion.
    /// A note whose Suggestion or Task is waiting in an Ask is read again next time.
    func intake(_ read: NotesRead, readFrom since: Date) {
        var changed: [Suggestion] = []
        var skippedSince: Date?
        // Checked again here: the adapter skips them, but the exclude list may have changed meanwhile.
        for note in read.notes where !isExcluded(notesFolder: note.folders.last ?? "", within: note.folders.dropLast()) {
            let key = "note:\(note.id)"
            let actions = Self.openActions(in: note.text)
            let fingerprint = actions.joined(separator: "\n")
            guard let existing = suggestionsByThread[key] else {
                if !actions.isEmpty { changed.append(newNoteSuggestion(note, actions, handled: [])) }
                continue
            }
            let task = liveTask(of: existing)
            guard existing.fingerprint != fingerprint else { continue }
            let held = asks.contains { ask in
                ask.touches.contains(existing.id.rawValue) || task.map { ask.touches.contains($0.id.rawValue) } == true
            }
            guard !held else {
                skippedSince = min(skippedSince ?? note.modified, note.modified)
                continue
            }
            let handled = existing.handledActions ?? []
            let open = actions.filter { !handled.contains($0) }
            var updated = existing
            updated.fingerprint = fingerprint
            updated.notesFolder = note.folders
            switch existing.status {
            case .open:
                if open.isEmpty { updated.status = .expired } else { updated.title = Self.notesTitle(open) }
                changed.append(updated)
            case .accepted:
                if let task {
                    guard open.isEmpty || (try? sourceUpdate(task.id, title: Self.notesTitle(open))) == true else {
                        skippedSince = min(skippedSince ?? note.modified, note.modified)
                        continue
                    }
                    changed.append(updated)
                } else {
                    // Only the actions that are new since the Task was accepted.
                    let done = handled + Self.actions(in: existing.fingerprint).filter { !handled.contains($0) }
                    let fresh = actions.filter { !done.contains($0) }
                    changed.append(fresh.isEmpty ? updated : newNoteSuggestion(note, actions, handled: done))
                }
            case .expired, .seen:
                changed.append(open.isEmpty ? updated : newNoteSuggestion(note, actions, handled: handled))
            case .dismissed, .replied:
                changed.append(updated)
            }
        }
        // Open Suggestions whose note is gone from every readable folder go too.
        changed += suggestionsByThread.values.filter { suggestion in
            suggestion.status == .open && suggestion.threadID.hasPrefix("note:")
                && !read.present.contains(String(suggestion.threadID.dropFirst("note:".count)))
                && !changed.contains { $0.threadID == suggestion.threadID }
                && !asks.contains { $0.touches.contains(suggestion.id.rawValue) }
        }.map { var gone = $0; gone.status = .expired; return gone }
        // The next read starts just before this one did, and never after a note left for later.
        let cursor = min(read.startedAt - Self.notesOverlap, (skippedSince ?? .distantFuture) - 1)
        do {
            try writeUnlogged(Change(suggestions: changed, notesCursor: max(cursor, since)))
        } catch {
            NSLog("TodoAgent: saving notes failed: \(type(of: error))")
        }
    }

    private static func actions(in fingerprint: String?) -> [String] {
        (fingerprint ?? "").split(separator: "\n").map(String.init)
    }

    /// The first action, with how many more there are.
    private static func notesTitle(_ actions: [String]) -> String {
        guard let first = actions.first else { return "" }
        let short = first.count <= notesTitleLimit ? first : first.prefix(notesTitleLimit - 1) + "…"
        return actions.count > 1 ? "\(short) (+\(actions.count - 1) more)" : String(short)
    }

    private func newNoteSuggestion(_ note: Note, _ actions: [String], handled: [String]) -> Suggestion {
        Suggestion(
            id: Suggestion.ID(), threadID: "note:\(note.id)", title: Self.notesTitle(actions.filter { !handled.contains($0) }),
            reason: "From the note “\(note.title)”", source: .notes, backLink: "notes:\(note.id)", guessedDeadline: nil,
            created: clock.now, status: .open, fingerprint: actions.joined(separator: "\n"), notesFolder: note.folders,
            handledActions: handled)
    }

    /// Open Suggestions from a notes folder now Excluded, or one inside it, expired.
    func suggestionsInExcluded(_ exclusion: Exclusion) -> [Suggestion] {
        guard case let .notesFolder(folder) = exclusion else { return [] }
        return suggestionsByThread.values.filter { suggestion in
            suggestion.status == .open && (suggestion.notesFolder ?? []).contains { $0.lowercased() == folder.lowercased() }
        }.map { suggestion in
            var gone = suggestion
            gone.status = .expired
            return gone
        }
    }
}
