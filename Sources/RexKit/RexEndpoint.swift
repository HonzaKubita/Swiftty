import Darwin
import Foundation

/// How to reach a Rex server.
public enum RexEndpoint: Sendable, Hashable, Codable, CustomStringConvertible {
    /// A Unix socket on this Mac (the personal server).
    case unix(path: String)
    /// Plain TCP: a tailnet name or an address with Rex's port (7297 by default).
    case tcp(host: String, port: Int)
    /// Over ssh: runs `rex __internal dial-stdio` on the other machine.
    case ssh(destination: String)

    public static let defaultPort = 7297

    /// Parse an endpoint the way `rex -S` accepts them: `ssh://user@host`,
    /// `unix:///path`, `http://host:port`, `tailnet-name`, `host:port`.
    public init?(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if t.hasPrefix("ssh://") {
            var rest = String(t.dropFirst("ssh://".count))
            if let slash = rest.firstIndex(of: "/") { rest = String(rest[..<slash]) }
            // Never something ssh would read as an option, or more than one argument.
            guard !rest.isEmpty, !rest.hasPrefix("-"), !rest.contains(where: \.isWhitespace) else { return nil }
            self = .ssh(destination: rest)
        } else if t.hasPrefix("unix://") {
            let path = String(t.dropFirst("unix://".count)).removingPercentEncoding ?? String(t.dropFirst("unix://".count))
            self = .unix(path: path)
        } else if t.hasPrefix("/") {
            self = .unix(path: t)
        } else {
            var rest = t
            for scheme in ["http://", "tailnet://", "tcp://"] where rest.hasPrefix(scheme) { rest = String(rest.dropFirst(scheme.count)) }
            if let slash = rest.firstIndex(of: "/") { rest = String(rest[..<slash]) }
            if let colon = rest.lastIndex(of: ":"), let port = Int(rest[rest.index(after: colon)...]) {
                self = .tcp(host: String(rest[..<colon]), port: port)
            } else {
                self = .tcp(host: rest, port: Self.defaultPort)
            }
        }
    }

    public var description: String {
        switch self {
        case .unix(let p): "unix://\(p)"
        case .tcp(let h, let p): p == Self.defaultPort ? h : "\(h):\(p)"
        case .ssh(let d): "ssh://\(d)"
        }
    }

    public var isLocal: Bool { if case .unix = self { return true }; return false }
}

/// An open byte stream to a Rex server: a socket, or a socket pair wired to ssh.
final class RexTransport: @unchecked Sendable {
    let fd: Int32
    private let process: Process?

    private init(fd: Int32, process: Process?) {
        self.fd = fd
        self.process = process
    }

    deinit {
        if let process, process.isRunning { process.terminate() }
    }

    func terminate() {
        if let process, process.isRunning { process.terminate() }
    }

    static func open(_ endpoint: RexEndpoint) throws -> RexTransport {
        switch endpoint {
        case .unix(let path): return RexTransport(fd: try connectUnix(path), process: nil)
        case .tcp(let host, let port): return RexTransport(fd: try connectTCP(host: host, port: port), process: nil)
        case .ssh(let destination): return try openSSH(destination)
        }
    }

    static func connectUnix(_ path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UnixWebSocket.Failure.socket(String(cString: strerror(errno))) }
        noSigPipe(fd)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            throw UnixWebSocket.Failure.socket("socket path too long: \(path)")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else {
            let message = String(cString: strerror(errno))
            close(fd)
            throw UnixWebSocket.Failure.socket("\(message) (\(path))")
        }
        return fd
    }

    static func connectTCP(host: String, port: Int) throws -> Int32 {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, String(port), &hints, &result)
        guard rc == 0, let first = result else {
            throw UnixWebSocket.Failure.socket("Can't find \(host): \(String(cString: gai_strerror(rc)))")
        }
        defer { freeaddrinfo(result) }
        var lastError = "no addresses"
        var info: UnsafeMutablePointer<addrinfo>? = first
        while let ai = info {
            let fd = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
            if fd >= 0 {
                noSigPipe(fd)
                var timeout = timeval(tv_sec: 8, tv_usec: 0)
                setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                if connect(fd, ai.pointee.ai_addr, ai.pointee.ai_addrlen) == 0 {
                    var one: Int32 = 1
                    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
                    return fd
                }
                lastError = String(cString: strerror(errno))
                close(fd)
            }
            info = ai.pointee.ai_next
        }
        throw UnixWebSocket.Failure.socket("Can't connect to \(host):\(port): \(lastError)")
    }

    /// `ssh destination rex __internal dial-stdio`, with its stdin/stdout on one end of a socket pair.
    static func openSSH(_ destination: String) throws -> RexTransport {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Swiftty", isDirectory: true)
        try? FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        // Reuse one ssh connection for the control channel and every terminal stream.
        return try openCommand("/usr/bin/ssh", [
            "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
            "-o", "ControlMaster=auto", "-o", "ControlPath=\(caches.path)/ssh-%C", "-o", "ControlPersist=120",
            "-o", "ServerAliveInterval=30",
            // The URI form carries a port ("user@host:2222"); "--" ends ssh's options.
            "--", "ssh://" + destination,
            // Find rex the way an interactive login would, then bridge to its server.
            #"sh -lc 'R=$(command -v rex || echo "$HOME/.local/bin/rex"); exec "$R" __internal dial-stdio'"#,
        ])
    }

    /// Run a command whose stdin/stdout is the byte stream to a Rex server.
    static func openCommand(_ executable: String, _ arguments: [String]) throws -> RexTransport {
        var pair: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
            throw UnixWebSocket.Failure.socket(String(cString: strerror(errno)))
        }
        noSigPipe(pair[0])
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        let theirs = FileHandle(fileDescriptor: pair[1], closeOnDealloc: true)
        p.standardInput = theirs
        p.standardOutput = theirs
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            close(pair[0])
            throw UnixWebSocket.Failure.socket("Couldn't run \((executable as NSString).lastPathComponent): \(error.localizedDescription)")
        }
        // ssh owns its end now.
        try? theirs.close()
        return RexTransport(fd: pair[0], process: p)
    }

    private static func noSigPipe(_ fd: Int32) {
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }
}
