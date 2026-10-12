import AssistantCore
import CoreServices
import Foundation

/// Watches the `.git` folder of each Project repo with FSEvents and reports the checked-out
/// branch by reading `.git/HEAD`. Runs no git commands.
@MainActor
final class GitWatcher {
    private var stream: FSEventStreamRef?
    private var repos: [String] = []
    private let deliver: (Signal) -> Void

    init(delivering deliver: @escaping (Signal) -> Void) {
        self.deliver = deliver
    }

    /// Replaces the set of watched repos. Folders without a `.git` directory are skipped.
    func watch(_ repoPaths: [String]) {
        let repos = repoPaths.filter { FileManager.default.fileExists(atPath: $0 + "/.git/HEAD") }
        guard repos != self.repos else { return }
        self.repos = repos
        stopStream()
        repos.forEach(report)
        guard !repos.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<GitWatcher>.fromOpaque(info).takeUnretainedValue()
            let changed = (unsafeBitCast(paths, to: NSArray.self) as? [String]) ?? []
            MainActor.assumeIsolated { watcher.changed(changed.prefix(count)) }
        }
        let gitDirs = repos.map { $0 + "/.git" } as CFArray
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, gitDirs, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0, flags)
        else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    private func changed(_ paths: ArraySlice<String>) {
        let touched = repos.filter { repo in paths.contains { $0.hasPrefix(repo + "/.git/") } }
        touched.forEach(report)
    }

    private func report(_ repo: String) {
        guard let head = try? String(contentsOfFile: repo + "/.git/HEAD", encoding: .utf8) else { return }
        let line = head.trimmingCharacters(in: .whitespacesAndNewlines)
        let branch = line.hasPrefix("ref: refs/heads/")
            ? String(line.dropFirst("ref: refs/heads/".count))
            : "detached \(line.prefix(7))"
        deliver(.git(repo: repo, branch: branch))
    }

    private func stopStream() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
