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

    @MainActor
    static func offer(_ command: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        let alert = NSAlert()
        alert.messageText = "Connect Claude Code"
        alert.informativeText = """
            The command is on your clipboard. Run it once in a terminal; Claude Code will then reach \
            your Tasks through the helper. It contains the helper's access token, so don't share it.
            """
        NSApp.activate()
        alert.runModal()
    }
}
