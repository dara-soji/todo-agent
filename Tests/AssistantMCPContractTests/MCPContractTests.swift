import AssistantCore
import AssistantMCP
import AssistantTestSupport
import Foundation
import MCP
import Network
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
            "add_task", "edit_task", "bulk_edit_tasks", "complete_task", "snooze_task", "drop_task", "delete_task",
            "restore_task", "commit_task", "skip_task",
        ])
    }

    /// Which Operation each tool runs. The tier a tool declares must be the Guardrail's tier for that
    /// Operation, so a tool wired to the wrong Operation shows up here once tiers differ.
    static let operations: [String: OperationKind] = [
        "add_task": .addTask, "edit_task": .editTask, "bulk_edit_tasks": .bulkEditTasks,
        "complete_task": .completeTask, "snooze_task": .snoozeTask,
        "drop_task": .dropTask, "delete_task": .deleteTask, "restore_task": .restoreTask, "commit_task": .commitTask,
        "skip_task": .skipTask,
    ]

    @Test func readToolsAreReadOnlyAndOperationToolsDeclareTheirGuardrailTier() async throws {
        let harness = try await Harness.start()
        defer { harness.stop() }

        let (tools, _) = try await harness.client().listTools()

        for tool in tools {
            if let kind = Self.operations[tool.name] {
                #expect(tool.annotations.readOnlyHint == false, "\(tool.name)")
                #expect(tool._meta?["tier"] == .string(harness.assistant.tier(for: kind).rawValue), "\(tool.name)")
            } else {
                #expect(tool.annotations.readOnlyHint == true, "\(tool.name)")
                #expect(tool._meta?["tier"] == nil, "\(tool.name)")
            }
        }
        #expect(tools.filter { Self.operations[$0.name] != nil }.count == Self.operations.count)
    }

    @Test func everyResultMatchesItsToolsOutputSchema() async throws {
        let harness = try await Harness.start()
        defer { harness.stop() }
        let (tools, _) = try await harness.client().listTools()
        // Each Operation gets its own Task, deleted first where the tool needs that.
        func fresh(deleted: Bool = false) throws -> Value {
            let task = try harness.assistant.quickAdd("Target")
            if deleted { try harness.assistant.deleteTask(task.id) }
            return .string(task.id.rawValue.uuidString)
        }
        let id = try fresh()
        let calls: [String: [String: Value]] = [
            "get_now": [:], "get_next": [:], "list_tasks": [:], "list_projects": [:], "get_calendar_today": [:],
            "get_operation_log": [:], "add_task": ["title": "New"], "edit_task": ["task_id": id, "title": "Renamed"],
            "skip_task": ["task_id": try fresh()], "snooze_task": ["task_id": try fresh(), "hours": 1],
            "commit_task": ["task_id": try fresh()], "complete_task": ["task_id": try fresh()],
            "drop_task": ["task_id": try fresh()], "delete_task": ["task_id": try fresh()],
            "restore_task": ["task_id": try fresh(deleted: true)],
            "bulk_edit_tasks": ["task_ids": [try fresh(), try fresh()], "kind": "deep"],
        ]
        #expect(Set(calls.keys) == Set(tools.map(\.name)))

        for tool in tools {
            let schema = try #require(tool.outputSchema?.objectValue, "\(tool.name) declares no output schema")
            let result = try await harness.call(tool.name, try #require(calls[tool.name]))
            let required = schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
            #expect(!required.isEmpty, "\(tool.name)")
            #expect(Set(result.keys) == Set(required), "\(tool.name) returned \(result.keys.sorted())")
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
        #expect(required["bulk_edit_tasks"] == ["task_ids"])
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

        let result = try await harness.call("add_task", [
            "title": "Write the contract suite", "effort": "small", "kind": "deep", "back_link": "~/code/todo-agent",
        ])

        #expect(result["status"] == .string("ran"))
        let task = try #require(harness.assistant.tasks.first)
        #expect(task.title == "Write the contract suite")
        #expect(task.effort == .small)
        #expect(task.kind == .deep)
        #expect(task.backLink == "~/code/todo-agent")
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

    @Test func snoozeCanHaveBothAWakeTimeAndANote() async throws {
        let harness = try await Harness.start()
        defer { harness.stop() }
        let task = try harness.assistant.quickAdd("Chase the invoice")
        let wake = harness.clock.now + 2 * 86_400

        _ = try await harness.call("snooze_task", [
            "task_id": .string(task.id.rawValue.uuidString), "until": .string(iso(wake)), "waiting_on": "Accounts",
        ])

        #expect(harness.assistant.task(task.id)?.status == .snoozed(until: wake, note: "Accounts"))
    }

    @Test func restoreBringsADeletedTaskBack() async throws {
        let harness = try await Harness.start()
        defer { harness.stop() }
        let task = try harness.assistant.quickAdd("Old idea")
        try harness.assistant.deleteTask(task.id)

        _ = try await harness.call("restore_task", ["task_id": .string(task.id.rawValue.uuidString)])

        #expect(harness.assistant.tasks.map(\.id) == [task.id])
        #expect(harness.assistant.operationLog.last?.startedBy == .claudeCode)
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
        ("get_operation_log", ["limit": Value.int(-1)]),
        ("get_operation_log", ["limit": Value.int(0)]),
        ("get_operation_log", ["limit": Value.int(10_000)]),
    ])
    func badCallsAreToolErrors(tool: String, arguments: [String: Value]) async throws {
        let harness = try await Harness.start()
        defer { harness.stop() }

        let (isError, _) = try await harness.callRaw(tool, arguments)

        #expect(isError)
        #expect(harness.assistant.tasks.isEmpty)
        #expect(harness.assistant.operationLog.isEmpty)
    }

    // MARK: Asks

    @Test func anAskOperationComesBackPendingAndChangesNothing() async throws {
        let harness = try await Harness.start()
        defer { harness.stop() }
        let task = try harness.assistant.quickAdd("Ship it")
        try harness.assistant.tighten(.completeTask)

        let result = try await harness.call("complete_task", ["task_id": .string(task.id.rawValue.uuidString)])

        let ask = try #require(harness.assistant.asks.first)
        #expect(result["status"] == .string("pending"))
        #expect(result["ask_id"] == .string(ask.id.rawValue.uuidString))
        #expect(result["expires_at"] == .string(iso(ask.expires)))
        #expect(result["log_entry"] == .null)
        #expect(harness.assistant.task(task.id)?.status == .open)
        #expect(ask.startedBy == .claudeCode)
    }

    @Test func aBulkEditOfMoreThanFiveTasksAsksWithAPreview() async throws {
        let harness = try await Harness.start()
        defer { harness.stop() }
        let ids = try (1...6).map { Value.string(try harness.assistant.quickAdd("T\($0)").id.rawValue.uuidString) }

        let small = try await harness.call("bulk_edit_tasks", ["task_ids": .array(Array(ids.prefix(5))), "effort": "small"])
        #expect(small["status"] == .string("ran"))

        let large = try await harness.call("bulk_edit_tasks", ["task_ids": .array(ids), "effort": "large"])
        #expect(large["status"] == .string("pending"))
        #expect(harness.assistant.asks.first?.preview == ["T1", "T2", "T3", "T4", "T5", "T6"])
        #expect(harness.assistant.tasks.allSatisfy { $0.effort != .large })
    }

    @Test func callsInOneConversationAreOneConfirmAndOthersAreSeparate() async throws {
        let harness = try await Harness.start()
        defer { harness.stop() }
        let tasks = try (1...3).map { try harness.assistant.quickAdd("T\($0)") }
        try harness.assistant.tighten(.dropTask)
        let conversation = try await harness.client()
        let other = try await harness.client()

        for task in tasks.prefix(2) {
            _ = try await conversation.callTool(name: "drop_task", arguments: ["task_id": .string(task.id.rawValue.uuidString)])
        }
        _ = try await other.callTool(name: "drop_task", arguments: ["task_id": .string(tasks[2].id.rawValue.uuidString)])

        #expect(harness.assistant.asks.map(\.operations.count).sorted() == [1, 2])
    }

    @Test func whenTheConversationSaysGoodbyeItsAsksExpire() async throws {
        let harness = try await Harness.start()
        defer { harness.stop() }
        let task = try harness.assistant.quickAdd("Ship it")
        try harness.assistant.tighten(.completeTask)
        _ = try await harness.call("complete_task", ["task_id": .string(task.id.rawValue.uuidString)])
        let session = try #require(harness.assistant.asks.first?.session)

        #expect(try await harness.rawDelete(session: session) == 200)

        #expect(harness.assistant.asks.isEmpty)
        #expect(harness.assistant.operationLog.last?.confirmation == .expired)
    }

    @Test func whenTheConversationEndsItsAsksExpire() async throws {
        let harness = try await Harness.start()
        defer { harness.stop() }
        let task = try harness.assistant.quickAdd("Ship it")
        try harness.assistant.tighten(.completeTask)
        // Without its own event stream, so the raw one below is the session's only one.
        _ = try await harness.client(streaming: false)
            .callTool(name: "complete_task", arguments: ["task_id": .string(task.id.rawValue.uuidString)])
        let session = try #require(harness.assistant.asks.first?.session)

        // As when Claude Code quits: its standing event stream's socket closes, with no goodbye.
        try await harness.openEventStreamThenQuit(session: session)

        for _ in 0..<50 where !harness.assistant.asks.isEmpty {
            try await _Concurrency.Task.sleep(for: .milliseconds(20))
        }
        #expect(harness.assistant.asks.isEmpty)
        #expect(harness.assistant.operationLog.last?.confirmation == .expired)
        #expect(harness.assistant.task(task.id)?.status == .open)
    }

    @Test func noToolCanConfirmAnAskChangeATierOrRunANeverOperation() async throws {
        let harness = try await Harness.start()
        defer { harness.stop() }

        let (tools, _) = try await harness.client().listTools()

        #expect(tools.allSatisfy { $0._meta?["tier"] != .string("never") })
        let forbidden = ["confirm", "decline", "approve", "tier", "guardrail", "loosen", "tighten"]
        #expect(tools.allSatisfy { tool in !forbidden.contains { tool.name.contains($0) } })
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
        // Window titles and URLs never leave the helper: Exclusions can't vet them yet (ticket 10).
        #expect(now["window"] == nil)
        #expect(now["app"] == .string("Code"))

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

    @Test func nothingAboutAnExcludedWindowReachesClaudeCode() async throws {
        let harness = try await Harness.start()
        defer { harness.stop() }
        try harness.assistant.exclude(.app("com.example.bank"))
        harness.assistant.receive(.activeWindow(
            app: App(bundleID: "com.example.bank", name: "My Bank"), windowTitle: "SECRET-TITLE",
            url: URL(string: "https://secret.example/acct")))

        let (_, text) = try await harness.callRaw("get_now", [:])

        #expect(text.contains("\"app\":\"Excluded\""))
        for secret in ["SECRET-TITLE", "secret.example", "My Bank", "com.example.bank"] {
            #expect(!text.contains(secret), "\(secret) reached Claude Code")
        }
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

    @Test func anOversizedRequestIsRefusedBeforeItIsRead() async throws {
        let harness = try await Harness.start()
        defer { harness.stop() }

        let status = try await harness.rawInitialize(
            authorization: "Bearer \(harness.token)", padding: AssistantMCPServer.maxRequestBytes + 1)

        #expect(status == 413)
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

    func client(token: String? = nil, streaming: Bool = true) async throws -> Client {
        try await Self.connect(url: url, bearer: token ?? self.token, streaming: streaming)
    }

    private nonisolated static func connect(url: URL, bearer: String, streaming: Bool) async throws -> Client {
        let transport = HTTPClientTransport(endpoint: url, streaming: streaming, requestModifier: { request in
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

    /// Opens the session's standing GET event stream on a raw socket, waits for the response head,
    /// then closes the socket the way a quitting process does.
    func openEventStreamThenQuit(session: String) async throws {
        let port = NWEndpoint.Port(rawValue: UInt16(url.port!))!
        let connection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        let request = """
            GET \(AssistantMCPServer.endpoint) HTTP/1.1\r
            Host: 127.0.0.1:\(url.port!)\r
            Authorization: Bearer \(token)\r
            Accept: text/event-stream\r
            Mcp-Session-Id: \(session)\r
            MCP-Protocol-Version: 2025-11-25\r
            \r

            """
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                guard case .ready = state else { return }
                connection.send(content: Data(request.utf8), completion: .contentProcessed { _ in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, _, error in
                        connection.cancel()
                        if let error { done.resume(throwing: error) } else { done.resume() }
                    }
                })
            }
            connection.start(queue: .global())
        }
    }

    /// Status code of a DELETE ending a session, as a client says goodbye.
    func rawDelete(session: String) async throws -> Int {
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(session, forHTTPHeaderField: "Mcp-Session-Id")
        request.setValue("2025-11-25", forHTTPHeaderField: "MCP-Protocol-Version")
        let (_, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    /// Status code of a bare initialize POST, for checking access rules below the SDK client.
    func rawInitialize(authorization: String?, host: String? = nil, padding: Int = 0) async throws -> Int {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
        if let host { request.setValue(host, forHTTPHeaderField: "Host") }
        request.httpBody = Data("""
            {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25",
             "capabilities":{},"clientInfo":{"name":"raw","version":"1"}}}
            """.utf8) + Data(repeating: 0x20, count: padding)
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
