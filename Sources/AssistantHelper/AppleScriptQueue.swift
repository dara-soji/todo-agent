import Foundation

/// The one queue every AppleScript runs on: NSAppleScript isn't safe to run on two threads at once.
enum AppleScriptQueue {
    static let shared = DispatchQueue(label: "TodoAgent.AppleScript")
}
