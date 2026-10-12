import AssistantCore
import AssistantMCP
import AssistantTestSupport
import Foundation
import MCP
import Testing

/// The contract between the helper and Claude Code (ADR 0001): the real MCP server, in process,
/// over the real core with fake ports, driven by the SDK's own HTTP client.
@MainActor
@Suite(.serialized) struct MCPContractTests {
    // MARK: Tool set

    @Test func theToolSetIsExactlyTheContract() async throws {
        let harness = try await Harness.start()
        defer { harness.stop() }

        let (tools, _) = try await harness.client().listTools()

        #expect(Set(tools.map(\.name)) == [
            "get_now", "get_next", "list_tasks", "list_projects", "get_calendar_today", "get_operation_log",
            "add_task", "edit_task", "complete_task", "snooze_task", "drop_task", "delete_task", "commit_task", "skip_task",
        ])
    }

    @Test func readToolsAreReadOnlyAndOperationToolsDeclareTheirGuardrailTier() async throws {
        let harness = try await Harness.start()
        defer { harness.stop() }

        let (tools, _) = try await harness.client().listTools()

        for tool in tools {
            if tool.name.hasPrefix("get_") || tool.name.hasPrefix("list_") {
                #expect(tool.annotations.readOnlyHint == true, "\(tool.name)")
                #expect(tool._meta?["tier"] == nil, "\(tool.name)")
            } else {
                #expect(tool.annotations.readOnlyHint == false, "\(tool.name)")
                #expect(tool._meta?["tier"] == .string("auto"), "\(tool.name)")
            }
        }
    }

    @Test func schemasNameTheirRequiredArguments() async throws {
        let harness = try await Harness.start()
        defer { harness.stop() }

        let (tools, _) = try await harness.client().listTools()
        let required = Dictionary(uniqueKeysWithValues: tools.map { tool in
            (tool.name, Set(tool.inputSchema.objectValue?["required"]?.arrayValue?.compactMap(\.stringValue) ?? []))
        })

        #expect(required["add_task"] == ["title"])
        for name in ["edit_task", "complete_task", "snooze_task", "drop_task", "delete_task", "commit_task", "skip_task"] {
            #expect(required[name] == ["task_id"], "\(name)")
        }
        for name in ["get_now", "get_next", "list_tasks", "list_projects", "get_calendar_today", "get_operation_log"] {
            #expect(required[name] == [], "\(name)")
        }
        #expect(tools.allSatisfy { $0.inputSchema.objectValue?["type"] == .string("object") })
    }

    // MARK: Operations

    @Test func addingATaskOverMCPRunsInTheCoreAndIsLoggedAsClaudeCode() async throws {
        let harness = try await Harness.start()
        defer { harness.stop() }

        let result = try await harness.call("add_task", ["title": "Write the contract suite", "effort": "small", "kind": "deep"])

        #expect(result["status"] == .string("ran"))
        let task = try #require(harness.assistant.tasks.first)
        #expect(task.title == "Write the contract suite")
        #expect(task.effort == .small)
        #expect(task.kind == .deep)
        #expect(result["task"]?.objectValue?["id"] == .string(task.id.rawValue.uuidString))
        #expect(harness.assistant.operationLog.last?.startedBy == .claudeCode)
        #expect(result["log_entry"]?.objectValue?["started_by"] == .string("claudeCode"))
        #expect(result["log_entry"]?.objectValue?["tier"] == .string("auto"))
    }

    @Test(arguments: [
        ("complete_task", "done"), ("drop_task", "dropped"), ("commit_task", "committed"), ("skip_task", "open"),
    ])
    func eachTaskOperationRunsAsClaudeCode(tool: String, status: String) async throws {
        let harness = try await Harness.start()
        defer { harness.stop() }
        let task = try harness.assistant.quickAdd("Target")

        let result = try await harness.call(tool, ["task_id": .string(task.id.rawValue.uuidString)])

        #expect(result["status"] == .string("ran"))
        #expect(result["task"]?.objectValue?["status"] == .string(status))
        #expect(harness.assistant.operationLog.last?.startedBy == .claudeCode)
    }

    @Test func snoozeTakesAWakeTimeOrANoteForWaitingOnSomeone() async throws {
        let harness = try await Harness.start()
        defer { harness.stop() }
        let a = try harness.assistant.quickAdd("A")
        let b = try harness.assistant.quickAdd("B")
        let wake = harness.clock.now + 3600

        _ = try await harness.call("snooze_task", ["task_id": .string(a.id.rawValue.uuidString), "until": .string(iso(wake))])
        _ = try await harness.call("snooze_task", ["task_id": .string(b.id.rawValue.uuidString), "waiting_on": "Sam"])

        #expect(harness.assistant.task(a.id)?.status == .snoozed(until: wake, note: nil))
        #expect(harness.assistant.task(b.id)?.status == .snoozed(until: nil, note: "Sam"))
    }

    @Test func deleteMovesTheTaskToTheDeletedList() async throws {
        let harness = try await Harness.start()
        defer { harness.stop() }
        let task = try harness.assistant.quickAdd("Old idea")

        _ = try await harness.call("delete_task", ["task_id": .string(task.id.rawValue.uuidString)])

        #expect(harness.assistant.deletedTasks.map(\.id) == [task.id])
    }

    @Test func editSetsAndClearsFields() async throws {
        let harness = try await Harness.start()
        defer { harness.stop() }
        let project = try harness.assistant.declareProject(name: "todo-agent", matchers: [])
        let task = try harness.assistant.quickAdd("Draft")
        let id = Value.string(task.id.rawValue.uuidString)
        let deadline = harness.clock.now + 86_400

        _ = try await harness.call("edit_task", [
            "task_id": id, "title": "Draft README", "deadline": .string(iso(deadline)),
            "project_id": .string(project.id.rawValue.uuidString),
        ])
        #expect(harness.assistant.task(task.id)?.title == "Draft README")
        #expect(harness.assistant.task(task.id)?.deadline == deadline)
        #expect(harness.assistant.task(task.id)?.project == project.id)

        _ = try await harness.call("edit_task", ["task_id": id, "deadline": .null])
        #expect(harness.assistant.task(task.id)?.deadline == nil)
        #expect(harness.assistant.task(task.id)?.project == project.id)
    }

    @Test func aRefusedOperationIsAToolErrorAndChangesNothing() async throws {
        let harness = try await Harness.start()
        defer { harness.stop() }
        let committed = try harness.assistant.quickAdd("Committed", start: true)

        let (isError, text) = try await harness.callRaw("skip_task", ["task_id": .string(committed.id.rawValue.uuidString)])

        #expect(isError)
        #expect(text.contains("not open"))
        #expect(harness.assistant.committedTask?.id == committed.id)
    }

    @Test(arguments: [
        ("complete_task", ["task_id": Value.string("not-a-uuid")]),
        ("complete_task", ["task_id": Value.string("6F9619FF-8B86-D011-B42D-00C04FC964FF")]),
        ("add_task", ["title": Value.string("  ")]),
        ("add_task", ["title": Value.string("X"), "effort": Value.string("huge")]),
        ("snooze_task", ["task_id": Value.string("6F9619FF-8B86-D011-B42D-00C04FC964FF"), "until": Value.string("tomorrow")]),
        ("no_such_tool", [String: Value]()),
    ])
    func badCallsAreToolErrors(tool: String, arguments: [String: Value]) async throws {
        let harness = try await Harness.start()
        defer { harness.stop() }

        let (isError, _) = try await harness.callRaw(tool, arguments)

        #expect(isError)
        #expect(harness.assistant.tasks.isEmpty)
        #expect(harness.assistant.operationLog.isEmpty)
    }

    // MARK: Reads

    @Test func readToolsReportNowNextTasksProjectsCalendarAndTheLog() async throws {
        let harness = try await Harness.start()
        defer { harness.stop() }
        let project = try harness.assistant.declareProject(name: "todo-agent", matchers: [.repoPath("~/code/todo-agent")])
        harness.assistant.receive(.activeWindow(
            app: App(bundleID: "com.microsoft.VSCode", name: "Code"), windowTitle: "~/code/todo-agent"))
        let event = CalendarEvent(title: "Standup", start: harness.clock.now + 600, end: harness.clock.now + 1500)
        harness.assistant.receive(.calendar(events: [event]))
        let task = try harness.assistant.quickAdd("Next one")

        let now = try await harness.call("get_now", [:])
        #expect(now["project"]?.objectValue?["id"] == .string(project.id.rawValue.uuidString))
        #expect(now["evidence"] == .string("~/code/todo-agent"))

        let next = try await harness.call("get_next", [:])
        #expect(next["task"]?.objectValue?["id"] == .string(task.id.rawValue.uuidString))
        #expect(next["reason"] == .string("Continues TODO-AGENT"))

        let projects = try await harness.call("list_projects", [:])
        #expect(projects["projects"]?.arrayValue?.first?.objectValue?["matchers"]
            == .array([.object(["kind": "repoPath", "pattern": "~/code/todo-agent"])]))

        let calendar = try await harness.call("get_calendar_today", [:])
        #expect(calendar["events"]?.arrayValue?.first?.objectValue?["title"] == .string("Standup"))

        let log = try await harness.call("get_operation_log", ["limit": 1])
        #expect(log["entries"]?.arrayValue?.count == 1)
        #expect(log["entries"]?.arrayValue?.first?.objectValue?["kind"] == .string("addTask"))
    }

    @Test func listTasksFiltersByStatusAndProject() async throws {
        let harness = try await Harness.start()
        defer { harness.stop() }
        let project = try harness.assistant.declareProject(name: "todo-agent", matchers: [])
        let open = try harness.assistant.addTask(TaskDraft(title: "Open", project: project.id))
        let done = try harness.assistant.quickAdd("Done")
        try harness.assistant.completeTask(done.id)
        let deleted = try harness.assistant.quickAdd("Deleted")
        try harness.assistant.deleteTask(deleted.id)

        let all = try await harness.call("list_tasks", [:])
        #expect(Set(ids(all)) == [open.id, done.id])

        let onlyDone = try await harness.call("list_tasks", ["status": .array(["done"])])
        #expect(ids(onlyDone) == [done.id])

        let inProject = try await harness.call("list_tasks", ["project_id": .string(project.id.rawValue.uuidString)])
        #expect(ids(inProject) == [open.id])

        let withDeleted = try await harness.call("list_tasks", ["include_deleted": true])
        #expect(Set(ids(withDeleted)) == [open.id, done.id, deleted.id])
    }

    // MARK: Access

    @Test func requestsWithoutTheRightTokenAreRejected() async throws {
        let harness = try await Harness.start()
        defer { harness.stop() }

        #expect(try await harness.rawInitialize(authorization: nil) == 401)
        #expect(try await harness.rawInitialize(authorization: "Bearer wrong") == 401)
        #expect(try await harness.rawInitialize(authorization: "Bearer \(harness.token.dropLast())") == 401)
        #expect(try await harness.rawInitialize(authorization: "Bearer \(harness.token)x") == 401)
        #expect(try await harness.rawInitialize(authorization: harness.token) == 401)
        #expect(try await harness.rawInitialize(authorization: "Bearer \(harness.token)") == 200)
        await #expect(throws: (any Error).self) { try await harness.client(token: "wrong").listTools() }
    }

    @Test func theServerListensOnLoopbackOnly() async throws {
        let harness = try await Harness.start()
        defer { harness.stop() }

        #expect(harness.server.boundHost == "127.0.0.1")
        // A rebinding page that resolves its own name to 127.0.0.1 still sends its own Host.
        #expect(try await harness.rawInitialize(authorization: "Bearer \(harness.token)", host: "evil.example") != 200)
    }

    @Test func refusesToBindAnythingButLoopback() {
        #expect(throws: AssistantMCPServer.Failure.notLoopback("0.0.0.0")) {
            _ = try AssistantMCPServer(assistant: Harness.makeAssistant(FakeClock()), token: "t", host: "0.0.0.0", port: 0)
        }
    }

    // MARK: Helpers

    private func ids(_ result: [String: Value]) -> [AssistantCore.Task.ID] {
        (result["tasks"]?.arrayValue ?? []).compactMap {
            $0.objectValue?["id"]?.stringValue.flatMap(UUID.init(uuidString:)).map(AssistantCore.Task.ID.init)
        }
    }
}

func iso(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
}

/// One server over one Assistant, for one test.
@MainActor
struct Harness {
    let clock: FakeClock
    let assistant: Assistant
    let server: AssistantMCPServer
    let token = "test-token-\(UUID().uuidString)"
    let url: URL

    static func makeAssistant(_ clock: FakeClock) -> Assistant {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        return try! Assistant(clock: clock, store: InMemoryStore(), homeDirectory: "/Users/dara", calendar: utc)
    }

    static func start() async throws -> Harness {
        let clock = FakeClock()
        let assistant = makeAssistant(clock)
        return try await Harness(clock: clock, assistant: assistant)
    }

    private init(clock: FakeClock, assistant: Assistant) async throws {
        self.clock = clock
        self.assistant = assistant
        let token = self.token
        server = try AssistantMCPServer(assistant: assistant, token: token, port: 0)
        let port = try await server.start()
        url = URL(string: "http://127.0.0.1:\(port)\(AssistantMCPServer.endpoint)")!
    }

    func stop() {
        let server = server
        _Concurrency.Task { await server.stop() }
    }

    func client(token: String? = nil) async throws -> Client {
        try await Self.connect(url: url, bearer: token ?? self.token)
    }

    private nonisolated static func connect(url: URL, bearer: String) async throws -> Client {
        let transport = HTTPClientTransport(endpoint: url, requestModifier: { request in
            var request = request
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
            return request
        })
        let client = Client(name: "contract-tests", version: "1")
        _ = try await client.connect(transport: transport)
        return client
    }

    /// The tool's JSON result; fails the test if the call was a tool error.
    func call(_ tool: String, _ arguments: [String: Value]) async throws -> [String: Value] {
        let (isError, text) = try await callRaw(tool, arguments)
        #expect(!isError, "\(tool) failed: \(text)")
        return try JSONDecoder().decode(Value.self, from: Data(text.utf8)).objectValue ?? [:]
    }

    func callRaw(_ tool: String, _ arguments: [String: Value]) async throws -> (isError: Bool, text: String) {
        let (content, isError) = try await client().callTool(name: tool, arguments: arguments)
        let text = content.compactMap { if case let .text(text, _, _) = $0 { text } else { nil } }.joined()
        return (isError ?? false, text)
    }

    /// Status code of a bare initialize POST, for checking access rules below the SDK client.
    func rawInitialize(authorization: String?, host: String? = nil) async throws -> Int {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
        if let host { request.setValue(host, forHTTPHeaderField: "Host") }
        request.httpBody = Data("""
            {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25",
             "capabilities":{},"clientInfo":{"name":"raw","version":"1"}}}
            """.utf8)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        let delegate = HeadOnly()
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (stream, response) = try await session.bytes(for: request)
        _ = stream
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }
}

/// Lets a raw request return as soon as the head arrives, even when the body is a long SSE stream.
private final class HeadOnly: NSObject, URLSessionDataDelegate {}
