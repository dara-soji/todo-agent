import AppKit
import AssistantCore
import Foundation

/// The Notes port over AppleScript, run in-process (no shell) on its own queue so a slow or first
/// Automation prompt never freezes the menu bar. Excluded folders, and Recently Deleted, are skipped
/// inside the script: their notes are never read, not even their titles.
final class AppleNotes: NotesSource, @unchecked Sendable {
    private static let fieldSeparator = "\u{1F}"
    private static let noteSeparator = "\u{1E}"
    /// errAEEventNotPermitted: Dara declined Automation for Notes.
    private static let notPermitted = -1743

    private let queue = DispatchQueue(label: "TodoAgent.AppleNotes")
    /// Dara declined Automation for Notes; shown in the menu.
    @MainActor private(set) var denied = false

    @MainActor
    func notes(modifiedSince since: Date?, skippingFolders skipping: [String]) async throws -> [Note] {
        // A second back, so a note saved in the same second as the last read isn't missed.
        let secondsAgo = since.map { max(0, Int(Date().timeIntervalSince($0)) + 1) }
        let source = Self.script(secondsAgo: secondsAgo, skipping: skipping)
        let result: Result<String, Error> = await withCheckedContinuation { continuation in
            queue.async {
                var error: NSDictionary?
                let output = NSAppleScript(source: source)?.executeAndReturnError(&error)
                if let error {
                    let code = error[NSAppleScript.errorNumber] as? Int ?? 0
                    continuation.resume(returning: .failure(Failure.script(code)))
                } else {
                    continuation.resume(returning: .success(output?.stringValue ?? ""))
                }
            }
        }
        switch result {
        case let .success(text):
            denied = false
            return Self.parse(text)
        case let .failure(error):
            if case Failure.script(Self.notPermitted) = error { denied = true }
            throw error
        }
    }

    enum Failure: Error {
        case script(Int)
    }

    /// Opens the note in Notes.
    func show(_ backLink: String) {
        guard backLink.hasPrefix("notes:") else { return }
        let id = Self.quoted(String(backLink.dropFirst("notes:".count)))
        let source = """
            tell application "Notes"
                show note id \(id)
                activate
            end tell
            """
        queue.async {
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
        }
    }

    static func script(secondsAgo: Int?, skipping: [String]) -> String {
        let skipped = (skipping + ["Recently Deleted"]).map(quoted).joined(separator: ", ")
        let filter = secondsAgo.map { "whose modification date > ((current date) - \($0))" } ?? ""
        return """
            with timeout of 120 seconds
                set skipped to {\(skipped)}
                set output to ""
                tell application "Notes"
                    repeat with f in folders
                        if skipped does not contain (name of f as text) then
                            repeat with n in (notes of f \(filter))
                                set output to output & (id of n) & "\(fieldSeparator)" & (name of f) & "\(fieldSeparator)" & (name of n) & "\(fieldSeparator)" & ((modification date of n) as «class isot» as string) & "\(fieldSeparator)" & (plaintext of n) & "\(noteSeparator)"
                            end repeat
                        end if
                    end repeat
                end tell
                return output
            end timeout
            """
    }

    /// An AppleScript string literal.
    static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func parse(_ text: String) -> [Note] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return text.components(separatedBy: noteSeparator).compactMap { record in
            let fields = record.components(separatedBy: fieldSeparator)
            guard fields.count >= 5, let modified = formatter.date(from: fields[3]) else { return nil }
            return Note(
                id: fields[0], folder: fields[1], title: fields[2],
                text: fields[4...].joined(separator: fieldSeparator), modified: modified)
        }
    }
}

/// Reads Notes every 15 minutes, and on wake.
@MainActor
final class NotesPolling {
    static let interval: TimeInterval = 15 * 60

    let notes = AppleNotes()
    private let runner: NotesRunner
    private var timer: Timer?
    private var wake: NSObjectProtocol?
    var onChange: () -> Void = {}

    init(assistant: Assistant) {
        runner = NotesRunner(assistant: assistant, notes: notes)
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        wake = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        check()
    }

    func stop() {
        timer?.invalidate()
        if let wake { NSWorkspace.shared.notificationCenter.removeObserver(wake) }
    }

    func check() {
        _Concurrency.Task {
            await runner.run()
            onChange()
        }
    }
}
