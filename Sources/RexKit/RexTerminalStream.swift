import Foundation

/// What a terminal data stream carries, in order.
public enum RexStreamEvent: Sendable {
    /// A complete libghostty-vt snapshot (`GHOSTSNP`). Replace all terminal state with it.
    case snapshot(Data)
    /// Live terminal output: feed it to the VT parser.
    case output(Data)
    /// A server message embedded in the stream.
    case message(RexStreamMessage)
}

public enum RexStreamMessage: Sendable, Equatable {
    case resize(columns: Int, rows: Int, cellWidth: Int, cellHeight: Int, owner: String?)
    case theme(RexTheme)
    case childExited(code: Int)
    case unknown(type: String, JSONValue)
}

/// Splits a `rex.data.terminal.v1` byte stream into snapshots, output, and
/// embedded `ESC _ rex1;<nonce>;<json> ESC \` messages.
///
/// Pure byte handling, so it can be tested without a server.
public struct RexStreamParser: Sendable {
    static let snapshotMagic = Data("GHOSTSNP".utf8)
    static let apcPrefix = Data("\u{1b}_rex1;".utf8)
    static let apcTerminator = Data("\u{1b}\\".utf8)
    static let maxCarry = 1 << 20

    public var nonce: UInt64
    private var snapshot: Data?     // collecting a snapshot
    private var carry = Data()      // undecided bytes (partial APC)
    private var atStreamStart = true
    private var startCarry = Data() // first bytes, before we know whether a snapshot follows

    public init(nonce: UInt64) { self.nonce = nonce }

    /// Feed the next chunk of stream bytes.
    public mutating func feed(_ chunk: Data) -> [RexStreamEvent] {
        var events: [RexStreamEvent] = []
        var input = chunk

        if atStreamStart || snapshot != nil {
            var pending = (snapshot ?? startCarry) + input
            if snapshot == nil {
                // A stream starts with a snapshot when it begins with the magic.
                // Too few bytes to tell yet: wait for more.
                if pending.count < Self.snapshotMagic.count, Self.snapshotMagic.starts(with: pending) {
                    startCarry = pending
                    return events
                }
                startCarry = Data()
                guard pending.starts(with: Self.snapshotMagic) else {
                    atStreamStart = false
                    return events + feedLive(pending)
                }
            }
            if let end = Self.snapshotLength(pending) {
                let snap = pending.prefix(end)
                pending = pending.dropFirst(end)
                snapshot = nil
                atStreamStart = false
                events.append(.snapshot(Data(snap)))
                input = Data(pending)
            } else {
                snapshot = pending
                return events
            }
        }
        return events + feedLive(input)
    }

    /// Mark a stream restart (a new snapshot may follow).
    public mutating func reset(nonce: UInt64) {
        self.nonce = nonce
        snapshot = nil
        carry = Data()
        startCarry = Data()
        atStreamStart = true
    }

    /// The length of a complete snapshot at the start of `data`, or nil if incomplete.
    /// Layout: 10-byte envelope, then records of [tag u16][len u32][crc u32][payload] until FINISH (tag 6).
    static func snapshotLength(_ data: Data) -> Int? {
        let bytes = [UInt8](data)
        var offset = 10
        while true {
            guard bytes.count >= offset + 10 else { return nil }
            let tag = UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
            let len = Int(UInt32(bytes[offset + 2]) | UInt32(bytes[offset + 3]) << 8
                | UInt32(bytes[offset + 4]) << 16 | UInt32(bytes[offset + 5]) << 24)
            let end = offset + 10 + len
            guard bytes.count >= end else { return nil }
            if tag == 6 { return end }
            offset = end
        }
    }

    private mutating func feedLive(_ chunk: Data) -> [RexStreamEvent] {
        let buf = carry + chunk
        carry = Data()
        var events: [RexStreamEvent] = []
        var outputStart = buf.startIndex
        var i = buf.startIndex

        func flushOutput(upTo end: Data.Index) {
            if end > outputStart { events.append(.output(buf.subdata(in: outputStart..<end))) }
        }

        while let esc = buf[i...].firstIndex(of: 0x1b) {
            let rest = buf[esc...]
            if rest.count < Self.apcPrefix.count {
                if Self.apcPrefix.starts(with: rest) {
                    flushOutput(upTo: esc)
                    carry = Data(rest)
                    return events
                }
                i = buf.index(after: esc)
                continue
            }
            guard rest.starts(with: Self.apcPrefix) else {
                i = buf.index(after: esc)
                continue
            }
            let bodyStart = esc + Self.apcPrefix.count
            guard let term = buf[bodyStart...].firstRange(of: Self.apcTerminator) else {
                if rest.count > Self.maxCarry {
                    i = buf.index(after: esc) // not a real message; pass it through
                    continue
                }
                flushOutput(upTo: esc)
                carry = Data(rest)
                return events
            }
            let body = buf.subdata(in: bodyStart..<term.lowerBound)
            if let message = parseMessage(body) {
                flushOutput(upTo: esc)
                events.append(.message(message))
                outputStart = term.upperBound
            }
            i = term.upperBound
        }
        flushOutput(upTo: buf.endIndex)
        return events
    }

    private func parseMessage(_ body: Data) -> RexStreamMessage? {
        guard let semi = body.firstIndex(of: UInt8(ascii: ";")),
              let nonceText = String(data: body[body.startIndex..<semi], encoding: .utf8),
              UInt64(nonceText) == nonce,
              let json = try? JSONDecoder().decode(JSONValue.self, from: body[(semi + 1)...])
        else { return nil }
        switch json["type"]?.string {
        case "resize":
            return .resize(
                columns: json["cols"]?.int ?? 0, rows: json["rows"]?.int ?? 0,
                cellWidth: json["cell_width_px"]?.int ?? 0, cellHeight: json["cell_height_px"]?.int ?? 0,
                owner: json["owner"]?.string)
        case "theme":
            return .theme((try? json.decode(RexTheme.self)) ?? RexTheme())
        case "child_exited":
            return .childExited(code: json["exit_code"]?.int ?? 0)
        default:
            return .unknown(type: json["type"]?.string ?? "", json)
        }
    }
}

/// One `rex.data.terminal.v1` connection: handshake, then a stream of events.
/// Reconnects with RESUME when the connection drops, within the server's grace period.
public final class RexTerminalStream: @unchecked Sendable {
    public static let subprotocol = "rex.data.terminal.v1"

    public enum Failure: Error, CustomStringConvertible {
        case rejected(UInt8)
        case badWelcome
        public var description: String {
            switch self {
            case .rejected(let r):
                let reasons: [UInt8: String] = [
                    1: "unknown or used ticket", 2: "already connected", 3: "stream unavailable",
                    4: "limit reached", 5: "malformed handshake", 6: "server error", 7: "wrong subprotocol",
                ]
                return "Rex refused the terminal stream: \(reasons[r] ?? "reason \(r)")"
            case .badWelcome: return "Rex sent an invalid WELCOME"
            }
        }
    }

    public let events: AsyncThrowingStream<RexStreamEvent, Error>
    private let continuation: AsyncThrowingStream<RexStreamEvent, Error>.Continuation
    private let address: RexServerAddress
    private let lock = NSLock()
    private var socket: UnixWebSocket?
    private var token = Data()
    private var received: UInt64 = 0
    private var graceMs: UInt32 = 0
    private var parser = RexStreamParser(nonce: 0)
    private var task: Task<Void, Never>?
    private var cancelled = false

    private init(address: RexServerAddress) {
        self.address = address
        (events, continuation) = AsyncThrowingStream.makeStream(of: RexStreamEvent.self, throwing: Error.self)
    }

    /// Open a stream with a ticket from `data.connect`.
    public static func open(address: RexServerAddress = .personal, ticket: String) async throws -> RexTerminalStream {
        let stream = RexTerminalStream(address: address)
        let ticketBytes = try decodeTicket(ticket)
        let (ws, first) = try await stream.handshake(Data([0x01]) + ticketBytes)
        stream.start(ws: ws, first: first)
        return stream
    }

    public func close() {
        let (task, socket) = lock.withLock { () -> (Task<Void, Never>?, UnixWebSocket?) in
            cancelled = true
            return (self.task, self.socket)
        }
        task?.cancel()
        socket?.close()
        continuation.finish()
    }

    static func decodeTicket(_ ticket: String) throws -> Data {
        var b64 = ticket.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64), data.count == 16 else {
            throw RexError(code: "bad_ticket", message: "Malformed data ticket")
        }
        return data
    }

    /// Send HELLO/RESUME and read WELCOME. Returns the socket and any bytes after the WELCOME frame.
    private func handshake(_ hello: Data) async throws -> (UnixWebSocket, [Data]) {
        let ws = try await UnixWebSocket.connect(
            endpoint: address.endpoint, path: "/api/data", subprotocol: Self.subprotocol)
        ws.send(binary: hello)
        var it = ws.messages.makeAsyncIterator()
        guard case .binary(let w)? = try await it.next() else { throw Failure.badWelcome }
        let b = [UInt8](w)
        if b.first == 0x82 { throw Failure.rejected(b.count > 1 ? b[1] : 0) }
        guard b.count >= 32, b[0] == 0x81 else { throw Failure.badWelcome }
        let newToken = Data(b[1..<17])
        let grace = UInt32(b[20]) | UInt32(b[21]) << 8 | UInt32(b[22]) << 16 | UInt32(b[23]) << 24
        var nonce: UInt64 = 0
        for k in (24..<32).reversed() { nonce = nonce << 8 | UInt64(b[k]) }
        lock.withLock {
            token = newToken
            graceMs = grace
            if hello.first == 0x01 {
                parser.reset(nonce: nonce)
                received = 0
            } else {
                parser.nonce = nonce
            }
        }
        return (ws, [])
    }

    private func start(ws: UnixWebSocket, first: [Data]) {
        lock.withLock { socket = ws }
        // Nobody listening any more (the pane went away): let go of the connection.
        continuation.onTermination = { [weak self] _ in self?.close() }
        let task = Task.detached { [weak self] in
            var ws = ws
            while let self {
                do {
                    for try await message in ws.messages {
                        guard case .binary(let chunk) = message else { continue }
                        let events = self.lock.withLock { () -> [RexStreamEvent] in
                            self.received += UInt64(chunk.count)
                            return self.parser.feed(chunk)
                        }
                        for e in events { self.continuation.yield(e) }
                    }
                    // A clean close from the server ends the stream.
                    self.continuation.finish()
                    return
                } catch {
                    if self.lock.withLock({ self.cancelled }) { return }
                    // Try to resume within the grace period.
                    guard let resumed = await self.resume() else {
                        self.continuation.finish(throwing: error)
                        return
                    }
                    // Closed while reconnecting: don't keep the new connection.
                    let closed = self.lock.withLock { () -> Bool in
                        if self.cancelled { return true }
                        self.socket = resumed
                        return false
                    }
                    if closed { resumed.close(); return }
                    ws = resumed
                }
            }
        }
        lock.withLock { self.task = task }
    }

    private func resume() async -> UnixWebSocket? {
        let (tok, count, grace) = lock.withLock { (token, received, graceMs) }
        let deadline = Date().addingTimeInterval(Double(grace) / 1000)
        var delay: UInt64 = 200_000_000
        while Date() < deadline, !lock.withLock({ cancelled }) {
            var msg = Data([0x02]) + tok
            withUnsafeBytes(of: count.littleEndian) { msg.append(contentsOf: $0) }
            do {
                return try await handshake(msg).0
            } catch Failure.rejected {
                return nil   // Rex won't take this stream back; retrying can't help
            } catch {}
            try? await Task.sleep(nanoseconds: delay)
            delay = min(delay * 2, 2_000_000_000)
        }
        return nil
    }
}
