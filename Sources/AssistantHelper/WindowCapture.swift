import AppKit
import AssistantCore
import Carbon.HIToolbox
import ImageIO
@preconcurrency import ScreenCaptureKit
import UniformTypeIdentifiers

/// The screenshot port: one ScreenCaptureKit shot of the front window, as a PNG in memory, never
/// written to disk. It refuses unless the window is still the one in front, by window id and title,
/// in an app that isn't Excluded, with no password being typed before or after the shot.
@MainActor
final class WindowCapture: ScreenshotCapturer {
    /// Longest side of the shot: enough for Haiku to read the window, at few tokens.
    private static let maxSide = 1280
    private static let timeout: Duration = .seconds(10)

    private let excludesApp: (String) -> Bool

    init(excludesApp: @escaping (String) -> Bool) {
        self.excludesApp = excludesApp
    }

    enum Failure: Error {
        case notInFront, notSafe, noWindow, timedOut, encodingFailed
    }

    func capture(_ key: GuessKey) async throws -> Data {
        guard let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier == key.bundleID else {
            throw Failure.notInFront
        }
        guard !excludesApp(key.bundleID), !IsSecureEventInputEnabled() else { throw Failure.notSafe }
        guard let windowID = Self.frontWindowID(of: front.processIdentifier) else { throw Failure.noWindow }

        let image = try await Self.withTimeout { try await Self.shoot(windowID: windowID, title: key.title) }

        // Still the same window, and still safe, now that the shot is taken.
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == front.processIdentifier,
              Self.frontWindowID(of: front.processIdentifier) == windowID, !IsSecureEventInputEnabled()
        else { throw Failure.notSafe }
        return try Self.png(image)
    }

    /// The app's frontmost normal window: CGWindowList lists on-screen windows front to back.
    private static func frontWindowID(of pid: pid_t) -> CGWindowID? {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let front = windows.first {
            ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0
        }
        return (front?[kCGWindowNumber as String] as? NSNumber).map { CGWindowID($0.uint32Value) }
    }

    private static func shoot(windowID: CGWindowID, title: String) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == windowID }), window.title == title else {
            throw Failure.noWindow
        }
        let scale = min(1, Double(maxSide) / max(window.frame.width, window.frame.height))
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(window.frame.width * scale))
        configuration.height = max(1, Int(window.frame.height * scale))
        configuration.showsCursor = false
        return try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration)
    }

    private static func withTimeout<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await _Concurrency.Task.sleep(for: timeout)
                throw Failure.timedOut
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private static func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { throw Failure.encodingFailed }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.encodingFailed }
        return data as Data
    }
}
