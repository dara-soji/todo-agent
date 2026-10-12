import AppKit
import AssistantMCP

/// How Claude Code is pointed at the helper. The helper runs no commands (ADR 0002), so it hands
/// Dara the one to run rather than editing Claude Code's config itself.
enum ClaudeCodeConnection {
    enum State {
        case starting
        case ready(command: String)
        case unavailable(String)
    }

    static func command(port: Int, token: String) -> String {
        "claude mcp add --transport http --scope user todo-agent "
            + "http://127.0.0.1:\(port)\(AssistantMCPServer.endpoint) --header \"Authorization: Bearer \(token)\""
    }

    /// How long the command (it holds the token) stays on the clipboard.
    private static let clipboardSeconds: TimeInterval = 120

    @MainActor
    static func offer(_ command: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        // Concealed: clipboard managers that honour the convention won't keep it in their history.
        pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        pasteboard.setString(command, forType: .string)
        let change = pasteboard.changeCount
        Timer.scheduledTimer(withTimeInterval: clipboardSeconds, repeats: false) { _ in
            MainActor.assumeIsolated {
                if NSPasteboard.general.changeCount == change { NSPasteboard.general.clearContents() }
            }
        }
        let alert = NSAlert()
        alert.messageText = "Connect Claude Code"
        alert.informativeText = """
            The command is on your clipboard for two minutes. Run it once in a terminal; Claude Code \
            will then reach your Tasks through the helper. It contains the helper's access token, so \
            don't share it.
            """
        NSApp.activate()
        alert.runModal()
    }
}
