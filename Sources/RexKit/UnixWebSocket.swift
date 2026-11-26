import Foundation
import Darwin

/// A minimal RFC 6455 WebSocket client over a Unix domain socket.
///
/// Rex serves its control and data protocols as WebSockets on a Unix socket,
/// which URLSession can't reach, so this speaks the handshake and framing
/// directly. No extensions (no permessage-deflate) are negotiated.
public final class UnixWebSocket: @unchecked Sendable {
    public enum Message: Sendable {
        case text(String)
        case binary(Data)
    }

    public enum Failure: Error, CustomStringConvertible {
        case socket(String)
        case handshake(String)
        case closed(code: UInt16?, reason: String)
        case protocolViolation(String)

        public var description: String {
            switch self {
            case .socket(let s): "socket error: \(s)"
            case .handshake(let s): "WebSocket handshake failed: \(s)"
            case .closed(let code, let reason): "connection closed (\(code.map(String.init) ?? "-")) \(reason)"
            case .protocolViolation(let s): "WebSocket protocol violation: \(s)"
            }
        }
    }

    /// Every message the server sends, in order. Finishes when the connection closes.
    public let messages: AsyncThrowingStream<Message, Error>
    public let negotiatedSubprotocol: String?

    private let continuation: AsyncThrowingStream<Message, Error>.Continuation
    private let queue: DispatchQueue
    private let fd: Int32
    private var readSource: DispatchSourceRead?
    private var buffer = Data()
    private var fragment: (opcode: UInt8, data: Data)?
    private var isClosed = false
    /// Keeps an ssh bridge alive for as long as the socket.
    fileprivate(set) var transport: RexTransport?

    private init(fd: Int32, leftover: Data, subprotocol: String?, label: String) {
        self.fd = fd
        self.buffer = leftover
        self.negotiatedSubprotocol = subprotocol
        self.queue = DispatchQueue(label: "swiftty.ws.\(label)")
        (messages, continuation) = AsyncThrowingStream.makeStream(of: Message.self, throwing: Error.self)
    }

    deinit {
        readSource?.cancel()
    }

    /// Connect to a Rex endpoint, then upgrade `GET path` to a WebSocket.
    public static func connect(endpoint: RexEndpoint, path: String, subprotocol: String) async throws -> UnixWebSocket {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let transport = try RexTransport.open(endpoint)
                    let ws = try connectBlocking(transport: transport, path: path, subprotocol: subprotocol)
                    cont.resume(returning: ws)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    public static func connect(socketPath: String, path: String, subprotocol: String) async throws -> UnixWebSocket {
        try await connect(endpoint: .unix(path: socketPath), path: path, subprotocol: subprotocol)
    }

    static func handshake(transport: RexTransport, path: String, subprotocol: String) throws -> UnixWebSocket {
        try connectBlocking(transport: transport, path: path, subprotocol: subprotocol)
    }

    private static func connectBlocking(transport: RexTransport, path: String, subprotocol: String) throws -> UnixWebSocket {
        let fd = transport.fd
        var keyBytes = [UInt8](repeating: 0, count: 16)
        for i in keyBytes.indices { keyBytes[i] = UInt8.random(in: 0...255) }
        let key = Data(keyBytes).base64EncodedString()
        let request =
            "GET \(path) HTTP/1.1\r\n" +
            "Host: localhost\r\n" +
            "Upgrade: websocket\r\n" +
            "Connection: Upgrade\r\n" +
            "Sec-WebSocket-Key: \(key)\r\n" +
            "Sec-WebSocket-Version: 13\r\n" +
            "Sec-WebSocket-Protocol: \(subprotocol)\r\n\r\n"
        do {
            try writeAll(fd: fd, Data(request.utf8))
        } catch {
            Darwin.close(fd)
            throw error
        }

        // Read the HTTP response head.
        var head = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        let terminator = Data("\r\n\r\n".utf8)
        while head.range(of: terminator) == nil {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 {
                Darwin.close(fd)
                throw Failure.handshake("server closed during handshake")
            }
            head.append(contentsOf: chunk[0..<n])
            if head.count > 64 * 1024 {
                Darwin.close(fd)
                throw Failure.handshake("response head too large")
            }
        }
        let split = head.range(of: terminator)!
        let leftover = head.subdata(in: split.upperBound..<head.endIndex)
        let headText = String(decoding: head[..<split.lowerBound], as: UTF8.self)
        let lines = headText.components(separatedBy: "\r\n")
        guard let status = lines.first, status.contains(" 101") else {
            Darwin.close(fd)
            throw Failure.handshake(lines.first ?? "no status line")
        }
        var negotiated: String?
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == "sec-websocket-protocol" {
                negotiated = parts[1].trimmingCharacters(in: .whitespaces)
            }
        }

        let ws = UnixWebSocket(fd: fd, leftover: leftover, subprotocol: negotiated, label: path)
        ws.transport = transport
        ws.queue.async { ws.startReading() }
        return ws
    }

    // MARK: Sending

    public func send(text: String) {
        send(opcode: 0x1, payload: Data(text.utf8))
    }

    public func send(binary: Data) {
        send(opcode: 0x2, payload: binary)
    }

    /// Send a close frame and tear the connection down.
    public func close(code: UInt16 = 1000) {
        queue.async {
            guard !self.isClosed else { return }
            var payload = Data()
            payload.append(UInt8(code >> 8))
            payload.append(UInt8(code & 0xff))
            try? Self.writeAll(fd: self.fd, Self.frame(opcode: 0x8, payload: payload))
            self.shutdown(error: nil)
        }
    }

    private func send(opcode: UInt8, payload: Data) {
        queue.async {
            guard !self.isClosed else { return }
            do {
                try Self.writeAll(fd: self.fd, Self.frame(opcode: opcode, payload: payload))
            } catch {
                self.shutdown(error: error)
            }
        }
    }

    static func frame(opcode: UInt8, payload: Data) -> Data {
        var out = Data()
        out.append(0x80 | opcode)
        let n = payload.count
        if n < 126 {
            out.append(0x80 | UInt8(n))
        } else if n < 65536 {
            out.append(0x80 | 126)
            out.append(UInt8(n >> 8))
            out.append(UInt8(n & 0xff))
        } else {
            out.append(0x80 | 127)
            for shift in stride(from: 56, through: 0, by: -8) {
                out.append(UInt8((UInt64(n) >> UInt64(shift)) & 0xff))
            }
        }
        let mask = (0..<4).map { _ in UInt8.random(in: 0...255) }
        out.append(contentsOf: mask)
        var masked = [UInt8](payload)
        for i in masked.indices { masked[i] ^= mask[i & 3] }
        out.append(contentsOf: masked)
        return out
    }

    private static func writeAll(fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw Failure.socket(String(cString: strerror(errno)))
                }
                offset += n
            }
        }
    }

    // MARK: Receiving

    private func startReading() {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.setCancelHandler { [fd] in Darwin.close(fd) }
        readSource = source
        source.resume()
        // The handshake may already have read the first frames.
        if !buffer.isEmpty { parseFrames() }
    }

    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let n = read(fd, &chunk, chunk.count)
        if n > 0 {
            buffer.append(contentsOf: chunk[0..<n])
            parseFrames()
        } else if n == 0 {
            shutdown(error: Failure.closed(code: nil, reason: "EOF"))
        } else if errno != EAGAIN && errno != EINTR {
            shutdown(error: Failure.socket(String(cString: strerror(errno))))
        }
    }

    private func parseFrames() {
        while !isClosed {
            guard buffer.count >= 2 else { return }
            let bytes = buffer
            let b0 = bytes[bytes.startIndex]
            let b1 = bytes[bytes.startIndex + 1]
            let fin = b0 & 0x80 != 0
            let opcode = b0 & 0x0f
            let masked = b1 & 0x80 != 0
            var length = UInt64(b1 & 0x7f)
            var offset = 2
            if length == 126 {
                guard bytes.count >= 4 else { return }
                length = UInt64(bytes[bytes.startIndex + 2]) << 8 | UInt64(bytes[bytes.startIndex + 3])
                offset = 4
            } else if length == 127 {
                guard bytes.count >= 10 else { return }
                length = 0
                for i in 0..<8 { length = length << 8 | UInt64(bytes[bytes.startIndex + 2 + i]) }
                offset = 10
            }
            var mask: [UInt8] = []
            if masked {
                guard bytes.count >= offset + 4 else { return }
                mask = Array(bytes[(bytes.startIndex + offset)..<(bytes.startIndex + offset + 4)])
                offset += 4
            }
            guard UInt64(bytes.count - offset) >= length else { return }
            let start = bytes.startIndex + offset
            var payload = bytes.subdata(in: start..<(start + Int(length)))
            buffer = bytes.subdata(in: (start + Int(length))..<bytes.endIndex)
            if masked {
                payload = Data(payload.enumerated().map { $0.element ^ mask[$0.offset & 3] })
            }
            handleFrame(fin: fin, opcode: opcode, payload: payload)
        }
    }

    private func handleFrame(fin: Bool, opcode: UInt8, payload: Data) {
        switch opcode {
        case 0x0: // continuation
            guard var f = fragment else {
                shutdown(error: Failure.protocolViolation("continuation without a start"))
                return
            }
            f.data.append(payload)
            if fin {
                fragment = nil
                deliver(opcode: f.opcode, payload: f.data)
            } else {
                fragment = f
            }
        case 0x1, 0x2:
            if fin { deliver(opcode: opcode, payload: payload) } else { fragment = (opcode, payload) }
        case 0x8:
            var code: UInt16?
            var reason = ""
            if payload.count >= 2 {
                code = UInt16(payload[payload.startIndex]) << 8 | UInt16(payload[payload.startIndex + 1])
                reason = String(decoding: payload.dropFirst(2), as: UTF8.self)
            }
            try? Self.writeAll(fd: fd, Self.frame(opcode: 0x8, payload: payload.prefix(2)))
            shutdown(error: code == 1000 ? nil : Failure.closed(code: code, reason: reason))
        case 0x9:
            try? Self.writeAll(fd: fd, Self.frame(opcode: 0xA, payload: payload))
        case 0xA:
            break
        default:
            shutdown(error: Failure.protocolViolation("unknown opcode \(opcode)"))
        }
    }

    private func deliver(opcode: UInt8, payload: Data) {
        if opcode == 0x1 {
            continuation.yield(.text(String(decoding: payload, as: UTF8.self)))
        } else {
            continuation.yield(.binary(payload))
        }
    }

    private func shutdown(error: Error?) {
        guard !isClosed else { return }
        isClosed = true
        transport?.terminate()
        if let source = readSource {
            source.cancel() // closes fd in the cancel handler
        } else {
            Darwin.close(fd)
        }
        readSource = nil
        continuation.finish(throwing: error)
    }
}
