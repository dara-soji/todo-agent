import AssistantCore
import Foundation
import MCP
import NIOConcurrencyHelpers
@preconcurrency import NIOCore
@preconcurrency import NIOHTTP1
@preconcurrency import NIOPosix

/// The helper's local MCP server: Streamable HTTP on loopback only, behind a bearer token.
/// Claude Code reaches the core only through it, never the database file (ADR 0001).
@MainActor
public final class AssistantMCPServer {
    public enum Failure: Error, Equatable {
        /// The server only ever listens on loopback.
        case notLoopback(String)
        case notStarted
    }

    public nonisolated static let endpoint = "/mcp"
    public nonisolated static let defaultPort = 47_615
    /// Larger requests are refused unread. Tool calls are a few kilobytes.
    public nonisolated static let maxRequestBytes = 1_000_000
    /// A session nobody has used for this long is closed.
    nonisolated static let sessionIdleLimit: TimeInterval = 60 * 60

    public let tools: AssistantTools
    private let router: Router
    private let host: String
    private let port: Int
    private var channel: Channel?
    private var group: MultiThreadedEventLoopGroup?

    /// The address actually bound, once started.
    public private(set) var boundHost: String?

    public init(assistant: Assistant, token: String, host: String = "127.0.0.1", port: Int = defaultPort) throws {
        guard ["127.0.0.1", "::1"].contains(host) else { throw Failure.notLoopback(host) }
        self.host = host
        self.port = port
        tools = AssistantTools(assistant: assistant)
        router = Router(token: token, tools: tools)
    }

    /// Starts listening and returns the bound port (useful when `port` is 0).
    @discardableResult
    public func start() async throws -> Int {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let router = router
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 16)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                // No pipelining assistance: it stops reading while a response is in flight, so a client
                // closing a long-lived event stream would never be noticed.
                channel.pipeline.configureHTTPServerPipeline(withPipeliningAssistance: false).flatMap {
                    channel.pipeline.addHandler(HTTPHandler(router: router))
                }
            }
        do {
            let channel = try await bootstrap.bind(host: host, port: port).get()
            self.channel = channel
            self.group = group
            boundHost = channel.localAddress?.ipAddress
            guard let port = channel.localAddress?.port else { throw Failure.notStarted }
            return port
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }

    public func stop() async {
        await router.closeAllSessions()
        try? await channel?.close()
        try? await group?.shutdownGracefully()
        channel = nil
        group = nil
        boundHost = nil
    }
}

// MARK: - Routing

/// Checks the bearer token, then routes each request to its session's MCP server, creating one
/// on `initialize`.
private actor Router {
    private struct Session {
        let server: Server
        let transport: StatefulHTTPServerTransport
        var lastUsed: Date
    }

    private let token: String
    private let tools: AssistantTools
    private var sessions: [String: Session] = [:]

    init(token: String, tools: AssistantTools) {
        self.token = token
        self.tools = tools
    }

    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        guard authorized(request) else {
            return .error(statusCode: 401, .invalidRequest("Unauthorized"), extraHeaders: ["WWW-Authenticate": "Bearer"])
        }
        await closeIdleSessions()
        let sessionID = request.header(HTTPHeaderName.sessionID)
        if let sessionID, let session = sessions[sessionID] {
            sessions[sessionID]?.lastUsed = Date()
            let response = await session.transport.handleRequest(request)
            if request.method.uppercased() == "DELETE", response.statusCode == 200 {
                await close(sessionID)
            }
            return response
        }
        if request.method.uppercased() == "POST", Self.isInitialize(request.body) {
            return await startSession(with: request)
        }
        if sessionID != nil {
            return .error(statusCode: 404, .invalidRequest("Session not found"))
        }
        return .error(statusCode: 400, .invalidRequest("Missing \(HTTPHeaderName.sessionID) header"))
    }

    /// The client's standing event stream for a session dropped: the conversation has gone away,
    /// even if it never sent DELETE.
    func clientLeft(_ id: String) async {
        await close(id)
    }

    /// Sessions a conversation abandoned without saying goodbye.
    private func closeIdleSessions() async {
        let cutoff = Date().addingTimeInterval(-AssistantMCPServer.sessionIdleLimit)
        for (id, session) in sessions where session.lastUsed < cutoff {
            await close(id)
        }
    }

    func closeAllSessions() async {
        for id in sessions.keys { await close(id) }
    }

    private func startSession(with request: HTTPRequest) async -> HTTPResponse {
        let id = UUID().uuidString
        // The SDK's default validation stays on: Host and Origin must be loopback, which stops a
        // DNS-rebinding page from reaching the server even though it resolves to 127.0.0.1.
        let transport = StatefulHTTPServerTransport(sessionIDGenerator: FixedSessionID(id: id))
        let server = Server(
            name: "todo-agent", version: "1",
            instructions: "Dara's personal work assistant: Now, Next, Tasks and Projects. Every change is an Operation the helper logs.",
            capabilities: .init(tools: .init(listChanged: false)))
        let tools = tools
        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: await tools.tools)
        }
        await server.withMethodHandler(CallTool.self) { params in
            await tools.call(params.name, params.arguments ?? [:], session: id)
        }
        do {
            try await server.start(transport: transport)
        } catch {
            await transport.disconnect()
            return .error(statusCode: 500, .internalError("Couldn't start the session"))
        }
        sessions[id] = Session(server: server, transport: transport, lastUsed: Date())
        let response = await transport.handleRequest(request)
        if case .error = response { await close(id) }
        return response
    }

    /// Ends the conversation: its pending Asks expire unrun (ADR 0002).
    private func close(_ id: String) async {
        guard let session = sessions.removeValue(forKey: id) else { return }
        await tools.endSession(id)
        await session.server.stop()
        await session.transport.disconnect()
    }

    /// Compares the whole token in constant time.
    private func authorized(_ request: HTTPRequest) -> Bool {
        guard let header = request.header(HTTPHeaderName.authorization), header.hasPrefix("Bearer ") else { return false }
        let given = Array(header.dropFirst("Bearer ".count).utf8)
        let expected = Array(token.utf8)
        guard given.count == expected.count else { return false }
        return zip(given, expected).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private static func isInitialize(_ body: Data?) -> Bool {
        guard let body, let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return false }
        return object["method"] as? String == "initialize"
    }

    private struct FixedSessionID: SessionIDGenerator {
        let id: String
        func generateSessionID() -> String { id }
    }
}

// MARK: - NIO adapter

/// Converts between NIO's HTTP parts and the SDK's framework-agnostic request and response,
/// streaming SSE bodies as they come.
private final class HTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let router: Router
    private var head: HTTPRequestHead?
    private var body = ByteBuffer()
    private var tooLarge = false
    /// Set when the client goes away, so a streaming response stops instead of writing into nothing.
    private let disconnected = NIOLockedValueBox(false)
    /// The session whose standing event stream this connection carries, if any.
    private let streamingSession = NIOLockedValueBox<String?>(nil)

    init(router: Router) {
        self.router = router
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case let .head(head):
            self.head = head
            body.clear()
            tooLarge = (head.headers.first(name: "Content-Length").flatMap(Int.init) ?? 0) > AssistantMCPServer.maxRequestBytes
        case var .body(buffer):
            guard !tooLarge else { return }
            if body.readableBytes + buffer.readableBytes > AssistantMCPServer.maxRequestBytes {
                tooLarge = true
                body.clear()
            } else {
                body.writeBuffer(&buffer)
            }
        case .end:
            guard let head else { return }
            self.head = nil
            if tooLarge {
                let bound = NIOLoopBound(context, eventLoop: context.eventLoop)
                _Concurrency.Task {
                    await self.write(.error(statusCode: 413, .invalidRequest("Request too large")),
                                     version: head.version, context: bound)
                }
                return
            }
            let request = makeRequest(head)
            // The context may only be touched on its event loop; NIOLoopBound enforces that.
            let bound = NIOLoopBound(context, eventLoop: context.eventLoop)
            _Concurrency.Task { await self.respond(to: request, head: head, context: bound) }
        }
    }

    /// The socket closed. If it carried a session's standing event stream, the client has gone away
    /// (e.g. Claude Code quit) even without a DELETE, so the conversation ends.
    func channelInactive(context: ChannelHandlerContext) {
        disconnected.withLockedValue { $0 = true }
        if let session = streamingSession.withLockedValue({ $0 }) {
            let router = router
            _Concurrency.Task { await router.clientLeft(session) }
        }
        context.fireChannelInactive()
    }

    private func respond(to request: HTTPRequest, head: HTTPRequestHead, context: NIOLoopBound<ChannelHandlerContext>) async {
        let path = head.uri.split(separator: "?").first.map(String.init) ?? head.uri
        let response = path == AssistantMCPServer.endpoint
            ? await router.handle(request)
            : .error(statusCode: 404, .invalidRequest("Not found"))
        // A GET answered with a stream is the session's standing event stream.
        if request.method.uppercased() == "GET", case .stream = response,
           let session = request.header(HTTPHeaderName.sessionID) {
            streamingSession.withLockedValue { $0 = session }
            if disconnected.withLockedValue({ $0 }) { await router.clientLeft(session) }
        }
        await write(response, version: head.version, context: context)
    }

    private func makeRequest(_ head: HTTPRequestHead) -> HTTPRequest {
        var headers: [String: String] = [:]
        for (name, value) in head.headers {
            headers[name] = headers[name].map { "\($0), \(value)" } ?? value
        }
        let bytes = body.readableBytes > 0 ? body.getBytes(at: body.readerIndex, length: body.readableBytes) : nil
        return HTTPRequest(method: head.method.rawValue, headers: headers, body: bytes.map { Data($0) }, path: head.uri)
    }

    private func write(_ response: HTTPResponse, version: HTTPVersion, context bound: NIOLoopBound<ChannelHandlerContext>) async {
        let loop = bound.eventLoop
        var responseHead = HTTPResponseHead(version: version, status: HTTPResponseStatus(statusCode: response.statusCode))
        for (name, value) in response.headers { responseHead.headers.add(name: name, value: value) }

        if case let .stream(stream, _) = response {
            let head = responseHead
            loop.execute {
                bound.value.writeAndFlush(self.wrapOutboundOut(.head(head)), promise: nil)
            }
            do {
                for try await chunk in stream {
                    if disconnected.withLockedValue({ $0 }) { break }
                    loop.execute {
                        var buffer = bound.value.channel.allocator.buffer(capacity: chunk.count)
                        buffer.writeBytes(chunk)
                        bound.value.writeAndFlush(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
                    }
                }
            } catch {
                // The stream ended early; close the response below.
            }
            loop.execute {
                bound.value.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
            }
            return
        }

        let data = response.bodyData
        if let data { responseHead.headers.replaceOrAdd(name: "Content-Length", value: String(data.count)) }
        let head = responseHead
        loop.execute {
            let context = bound.value
            context.write(self.wrapOutboundOut(.head(head)), promise: nil)
            if let data {
                var buffer = context.channel.allocator.buffer(capacity: data.count)
                buffer.writeBytes(data)
                context.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
            }
            context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
        }
    }
}
