import Foundation

/// One Apple Note as read: its id, folder, title and plain text. The text is only looked through
/// for open actions; it is never stored or sent anywhere.
public struct Note: Equatable, Sendable {
    public let id: String
    public let folder: String
    public let title: String
    public let text: String
    public let modified: Date

    public init(id: String, folder: String, title: String, text: String, modified: Date) {
        self.id = id
        self.folder = folder
        self.title = title
        self.text = text
        self.modified = modified
    }
}

/// Port: Apple Notes, read unattended while Dara is logged in. Notes in `skipping` folders are never
/// read, not even their titles.
@MainActor
public protocol NotesSource: AnyObject {
    func notes(modifiedSince since: Date?, skippingFolders skipping: [String]) async throws -> [Note]
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
        let read: [Note]
        do {
            read = try await notes.notes(modifiedSince: since, skippingFolders: assistant.excludedNotesFolders)
        } catch {
            return NSLog("TodoAgent: reading Notes failed: \(type(of: error))")
        }
        // Checked again here: the adapter skips them, but the exclude list may have changed meanwhile.
        assistant.intake(read.filter { !assistant.isExcluded(notesFolder: $0.folder) }, readUpTo: read.map(\.modified).max())
    }
}

extension Assistant {
    /// The longest Suggestion title kept for a note's first action.
    static let notesTitleLimit = 100

    var excludedNotesFolders: [String] {
        exclusions.compactMap { if case let .notesFolder(folder) = $0 { folder } else { nil } }.sorted()
    }

    /// Open actions in a note: unticked checklist lines ("- [ ]", "[ ]", "☐") and "TODO:" lines.
    static func openActions(in text: String) -> [String] {
        let pattern = #"^\s*(?:[-*•]\s*)?(?:\[ \]|☐|TODO:?|To ?do:)\s*(.+?)\s*$"#
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
    /// open actions left loses its open Suggestion.
    func intake(_ notes: [Note], readUpTo latest: Date?) {
        var changed: [Suggestion] = []
        for note in notes {
            let key = "note:\(note.id)"
            let actions = Self.openActions(in: note.text)
            let fingerprint = actions.joined(separator: "\n")
            let title = Self.notesTitle(actions)
            guard let existing = suggestionsByThread[key] else {
                if !actions.isEmpty { changed.append(newNoteSuggestion(note, title, fingerprint)) }
                continue
            }
            guard existing.fingerprint != fingerprint,
                  !asks.contains(where: { $0.touches.contains(existing.id.rawValue) }) else { continue }
            var updated = existing
            updated.fingerprint = fingerprint
            updated.notesFolder = note.folder
            switch existing.status {
            case .open:
                if actions.isEmpty { updated.status = .expired } else { updated.title = title }
                changed.append(updated)
            case .accepted:
                if let task = liveTask(of: existing) {
                    guard actions.isEmpty || (try? sourceUpdate(task.id, title: title)) == true else { continue }
                    changed.append(updated)
                } else if !actions.isEmpty {
                    // Only the actions that are new since the Task was accepted.
                    let old = Set((existing.fingerprint ?? "").split(separator: "\n").map(String.init))
                    let fresh = actions.filter { !old.contains($0) }
                    changed.append(fresh.isEmpty ? updated : newNoteSuggestion(note, Self.notesTitle(fresh), fingerprint))
                } else {
                    changed.append(updated)
                }
            case .expired, .seen:
                changed.append(actions.isEmpty ? updated : newNoteSuggestion(note, title, fingerprint))
            case .dismissed, .replied:
                changed.append(updated)
            }
        }
        do {
            try writeUnlogged(Change(suggestions: changed, notesCursor: latest))
        } catch {
            NSLog("TodoAgent: saving notes failed: \(type(of: error))")
        }
    }

    /// The first action, with how many more there are.
    private static func notesTitle(_ actions: [String]) -> String {
        guard let first = actions.first else { return "" }
        let short = first.count <= notesTitleLimit ? first : first.prefix(notesTitleLimit - 1) + "…"
        return actions.count > 1 ? "\(short) (+\(actions.count - 1) more)" : String(short)
    }

    private func newNoteSuggestion(_ note: Note, _ title: String, _ fingerprint: String) -> Suggestion {
        Suggestion(
            id: Suggestion.ID(), threadID: "note:\(note.id)", title: title, reason: "From the note “\(note.title)”",
            source: .notes, backLink: "notes:\(note.id)", guessedDeadline: nil, created: clock.now, status: .open,
            fingerprint: fingerprint, notesFolder: note.folder)
    }

    /// Open Suggestions from a notes folder now Excluded, expired.
    func suggestionsInExcluded(_ exclusion: Exclusion) -> [Suggestion] {
        guard case let .notesFolder(folder) = exclusion else { return [] }
        return suggestionsByThread.values.filter { $0.status == .open && $0.notesFolder == folder }.map { suggestion in
            var gone = suggestion
            gone.status = .expired
            return gone
        }
    }
}
