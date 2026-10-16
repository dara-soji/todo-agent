import AppKit
import AssistantCore
import Foundation

/// The Notes port over AppleScript, run in-process (no shell) on the shared AppleScript queue so a
/// slow read or a first Automation prompt never freezes the menu bar. Folders are walked one by one
/// with their parents: a folder that is Excluded, or inside one that is, and Recently Deleted, are
/// never opened, so their notes, titles and ids are never read. If Notes wasn't open, it is quit
/// again after the read.
@MainActor
final class AppleNotes: NotesSource {
    private static let bundleID = "com.apple.Notes"
    /// errAEEventNotPermitted: Dara declined Automation for Notes.
    private static let notPermitted = -1743
    /// The most plain text read from one note.
    static let textLimit = 20_000

    /// Dara declined Automation for Notes; shown in the menu.
    private(set) var denied = false

    enum Failure: Error {
        case script(Int)
    }

    func notes(modifiedSince since: Date?, skippingFolders skipping: [String]) async throws -> NotesRead {
        let startedAt = Date()
        let wasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty
        let secondsAgo = since.map { max(0, Int(startedAt.timeIntervalSince($0)) + 1) } ?? 100 * 365 * 86_400
        let source = Self.script(secondsAgo: secondsAgo, skipping: skipping)
        let result: Result<NSAppleEventDescriptor, Failure> = await withCheckedContinuation { continuation in
            AppleScriptQueue.shared.async {
                var error: NSDictionary?
                let output = NSAppleScript(source: source)?.executeAndReturnError(&error)
                if let error {
                    continuation.resume(returning: .failure(.script(error[NSAppleScript.errorNumber] as? Int ?? 0)))
                } else {
                    continuation.resume(returning: .success(output ?? NSAppleEventDescriptor.list()))
                }
            }
        }
        if !wasRunning {
            NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).forEach { $0.terminate() }
        }
        switch result {
        case let .success(descriptor):
            denied = false
            let (notes, present) = Self.parse(descriptor)
            return NotesRead(notes: notes, present: present, startedAt: startedAt)
        case let .failure(error):
            if case .script(Self.notPermitted) = error { denied = true }
            throw error
        }
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
        AppleScriptQueue.shared.async {
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
        }
    }

    /// Returns {found, present}: each found note as {id, {folders outermost first}, title, ISO date,
    /// text}, and the ids of every note in a folder that is read.
    static func script(secondsAgo: Int, skipping: [String]) -> String {
        let skipped = (skipping + ["Recently Deleted"]).map(quoted).joined(separator: ", ")
        return """
            set cutoff to (current date) - \(secondsAgo)
            set skipped to {\(skipped)}
            set found to {}
            set present to {}
            with timeout of 300 seconds
                tell application "Notes"
                    set pending to {}
                    repeat with a in accounts
                        repeat with f in folders of a
                            set end of pending to contents of f
                        end repeat
                    end repeat
                    set visited to {}
                    set i to 1
                    repeat while i is less than or equal to (count of pending)
                        set f to item i of pending
                        set i to i + 1
                        set folderID to id of f
                        if visited does not contain folderID then
                            set end of visited to folderID
                            set folderPath to {}
                            set skip to false
                            set c to f
                            repeat 50 times
                                set folderName to name of c as text
                                set beginning of folderPath to folderName
                                if skipped contains folderName then set skip to true
                                set c to container of c
                                if class of c is not folder then exit repeat
                            end repeat
                            if not skip then
                                repeat with noteID in (id of every note of f)
                                    set end of present to (noteID as text)
                                end repeat
                                repeat with n in (notes of f whose modification date > cutoff)
                                    set t to plaintext of n
                                    if length of t > \(textLimit) then set t to text 1 thru \(textLimit) of t
                                    set end of found to {id of n, folderPath, name of n, (modification date of n) as «class isot» as string, t}
                                end repeat
                                repeat with sub in folders of f
                                    set end of pending to contents of sub
                                end repeat
                            end if
                        end if
                    end repeat
                end tell
            end timeout
            return {found, present}
            """
    }

    /// An AppleScript string literal.
    static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func parse(_ descriptor: NSAppleEventDescriptor) -> (notes: [Note], present: Set<String>) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        func items(_ list: NSAppleEventDescriptor?) -> [NSAppleEventDescriptor] {
            guard let list, list.numberOfItems > 0 else { return [] }
            return (1...list.numberOfItems).compactMap { list.atIndex($0) }
        }
        let notes = items(descriptor.atIndex(1)).compactMap { record -> Note? in
            let fields = items(record)
            guard fields.count == 5, let id = fields[0].stringValue, let date = fields[3].stringValue,
                  let modified = formatter.date(from: date)
            else { return nil }
            return Note(
                id: id, folders: items(fields[1]).compactMap(\.stringValue), title: fields[2].stringValue ?? "",
                text: fields[4].stringValue ?? "", modified: modified)
        }
        return (notes, Set(items(descriptor.atIndex(2)).compactMap(\.stringValue)))
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
