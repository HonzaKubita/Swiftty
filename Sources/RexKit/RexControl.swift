import Foundation

/// Where a Rex server listens.
public struct RexServerAddress: Sendable, Hashable {
    public var endpoint: RexEndpoint

    public init(endpoint: RexEndpoint) { self.endpoint = endpoint }
    public init(socketPath: String) { self.endpoint = .unix(path: socketPath) }

    /// The Unix socket path, for a local server.
    public var socketPath: String {
        if case .unix(let p) = endpoint { return p }
        return ""
    }

    /// The personal server Rex.app runs on macOS.
    public static var personal: RexServerAddress {
        if let override = ProcessInfo.processInfo.environment["REX_SOCKET"] {
            return RexServerAddress(socketPath: override)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return RexServerAddress(socketPath: support.appendingPathComponent("rex/server.sock").path)
    }
}

/// What this client tells the server about itself in `hello`.
public struct RexClientInfo: Sendable, Codable {
    public var name: String
    public var version: String
    public var kind: String
    public var label: String

    public init(name: String = "Swiftty", version: String = "0.1", kind: String = "app", label: String) {
        self.name = name
        self.version = version
        self.kind = kind
        self.label = label
    }
}

public struct RexError: Error, Sendable, CustomStringConvertible {
    public var code: String
    public var message: String
    public var status: Int?

    public var description: String { "\(message) (code=\(code))" }

    public init(code: String, message: String, status: Int? = nil) {
        self.code = code
        self.message = message
        self.status = status
    }

    static let closed = RexError(code: "closed", message: "The connection to Rex closed")
}

/// One event from the control channel.
public struct RexEvent: Sendable {
    public var seq: Int
    /// The raw event payload: `{type, payload}`.
    public var payload: JSONValue

    public var type: String { payload["type"]?.string ?? "" }

    /// For `session_event`: the session and the inner event.
    public var sessionEvent: (sessionId: String, type: String, payload: JSONValue)? {
        guard type == "session_event", let inner = payload["payload"],
              let sid = inner["session_id"]?.string, let ev = inner["event"] else { return nil }
        return (sid, ev["type"]?.string ?? "", ev["payload"] ?? .null)
    }
}

/// The `rex.control.v1` connection: JSON requests, responses and events.
public actor RexControl {
    public struct Welcome: Sendable {
        public var clientId: String
        public var reconnectToken: String
        public var apiRevision: Int
        public var maxMessageBytes: Int
    }

    public nonisolated let events: AsyncStream<RexEvent>
    public private(set) var welcome: Welcome?

    private let address: RexServerAddress
    private let client: RexClientInfo
    private let eventContinuation: AsyncStream<RexEvent>.Continuation
    private var socket: UnixWebSocket?
    private var pending: [String: CheckedContinuation<JSONValue, Error>] = [:]
    private var nextID = 1
    private var readTask: Task<Void, Never>?
    /// Counts connections, so a finished one can't tear down its successor.
    private var generation = 0

    public init(address: RexServerAddress = .personal, client: RexClientInfo) {
        self.address = address
        self.client = client
        (events, eventContinuation) = AsyncStream.makeStream(of: RexEvent.self, bufferingPolicy: .unbounded)
    }

    /// Open the control connection and complete hello/welcome.
    @discardableResult
    public func connect() async throws -> Welcome {
        let ws = try await UnixWebSocket.connect(
            endpoint: address.endpoint, path: "/api/control", subprotocol: "rex.control.v1")
        // Requests still waiting on the previous connection will never be answered.
        socket?.close()
        failPending()
        socket = ws
        generation += 1
        let generation = generation
        var hello: [String: JSONValue] = [
            "type": "hello",
            "client": try JSONValue.from(client),
        ]
        if let token = welcome?.reconnectToken { hello["reconnect_token"] = .string(token) }
        ws.send(text: try String(decoding: JSONEncoder().encode(JSONValue.object(hello)), as: UTF8.self))

        var iterator = ws.messages.makeAsyncIterator()
        guard case .text(let text)? = try await iterator.next() else {
            throw RexError(code: "protocol", message: "Rex sent no welcome")
        }
        let msg = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        guard msg["type"]?.string == "welcome" else {
            throw RexError(code: "protocol", message: "Expected welcome, got \(text.prefix(200))")
        }
        let w = Welcome(
            clientId: msg["client"]?["id"]?.string ?? "",
            reconnectToken: msg["client"]?["reconnect_token"]?.string ?? "",
            apiRevision: msg["api_server_revision"]?.int ?? 0,
            maxMessageBytes: msg["limits"]?["max_message_bytes"]?.int ?? 1 << 20)
        welcome = w

        let stream = ws.messages
        readTask = Task { [weak self] in
            do {
                for try await message in stream {
                    guard case .text(let text) = message else { continue }
                    await self?.handle(text)
                }
                await self?.connectionEnded(generation)
            } catch {
                await self?.connectionEnded(generation)
            }
        }
        _ = iterator
        return w
    }

    public func disconnect() {
        socket?.close()
        socket = nil
    }

    /// Call a method and return its payload.
    @discardableResult
    public func call(_ method: String, _ payload: JSONValue? = nil) async throws -> JSONValue {
        guard let socket else { throw RexError.closed }
        let id = String(nextID)
        nextID += 1
        var request: [String: JSONValue] = ["type": "request", "id": .string(id), "method": .string(method)]
        if let payload { request["payload"] = payload }
        let text = String(decoding: try JSONEncoder().encode(JSONValue.object(request)), as: UTF8.self)
        return try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
            socket.send(text: text)
        }
    }

    /// Call a method and decode its payload.
    public func call<T: Decodable & Sendable>(_ method: String, _ payload: JSONValue? = nil, as: T.Type) async throws -> T {
        try await call(method, payload).decode(T.self)
    }

    private func handle(_ text: String) {
        guard let msg = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) else { return }
        switch msg["type"]?.string {
        case "response":
            guard let id = msg["id"]?.string, let cont = pending.removeValue(forKey: id) else { return }
            if let error = msg["error"], error != .null {
                cont.resume(throwing: RexError(
                    code: error["code"]?.string ?? "unknown",
                    message: error["message"]?.string ?? "Request failed",
                    status: error["status"]?.int))
            } else {
                cont.resume(returning: msg["payload"] ?? .null)
            }
        case "event":
            eventContinuation.yield(RexEvent(seq: msg["seq"]?.int ?? 0, payload: msg["payload"] ?? .null))
        default:
            break
        }
    }

    private func connectionEnded(_ ended: Int) {
        guard ended == generation else { return }
        failPending()
        socket = nil
        eventContinuation.yield(RexEvent(seq: -1, payload: ["type": "swiftty_disconnected"]))
    }

    private func failPending() {
        let waiting = pending
        pending.removeAll()
        for (_, cont) in waiting { cont.resume(throwing: RexError.closed) }
    }
}
