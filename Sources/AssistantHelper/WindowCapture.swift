import AppKit
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// One ScreenCaptureKit shot of the front window of an app, as a PNG in memory. Never written to disk.
enum WindowCapture {
    /// Longest side of the shot; enough for Haiku to read the window, and few tokens.
    private static let maxSide = 1280

    enum Failure: Error {
        case noWindow, encodingFailed
    }

    /// The topmost on-screen window of the app with `pid` whose title is `title`.
    static func png(pid: pid_t, title: String) async throws -> Data {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: {
            $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.title == title
        }) else { throw Failure.noWindow }

        let scale = min(1, Double(maxSide) / max(window.frame.width, window.frame.height))
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(window.frame.width * scale))
        configuration.height = max(1, Int(window.frame.height * scale))
        configuration.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration)

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { throw Failure.encodingFailed }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.encodingFailed }
        return data as Data
    }
}
