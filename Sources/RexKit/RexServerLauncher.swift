import Foundation

/// Finds an installed Rex and starts a personal server when none is running.
public enum RexServerLauncher {
    public enum Failure: Error, CustomStringConvertible {
        case notInstalled
        case startFailed(String)
        case timedOut

        public var description: String {
            switch self {
            case .notInstalled: "Rex isn't installed. Install Rex from superlogical.com/rex, then try again."
            case .startFailed(let s): "Couldn't start a Rex server: \(s)"
            case .timedOut: "Started Rex, but its server didn't come up in time."
            }
        }
    }

    /// Where the `rex` command might be.
    static var candidates: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var list = [
            "/Applications/Rex.app/Contents/Helpers/Rex Server.rex/Contents/MacOS/rex",
            "\(home)/Applications/Rex.app/Contents/Helpers/Rex Server.rex/Contents/MacOS/rex",
            "/opt/homebrew/bin/rex", "/usr/local/bin/rex", "\(home)/.local/bin/rex",
        ]
        for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            list.append("\(dir)/rex")
        }
        return list
    }

    public static func findExecutable() -> String? {
        if simulateMissing { return nil }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Testing aid: SWIFTTY_SIMULATE_NO_REX=1 behaves as if Rex weren't on this Mac.
    static var simulateMissing: Bool { ProcessInfo.processInfo.environment["SWIFTTY_SIMULATE_NO_REX"] != nil }

    /// True if something accepts connections on the socket.
    public static func isRunning(_ address: RexServerAddress) -> Bool {
        if simulateMissing { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(address.socketPath.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return false }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return rc == 0
    }

    /// Run `rex server start` (idempotent) and wait for the socket to accept connections.
    public static func start(address: RexServerAddress) async throws {
        guard let rex = findExecutable() else { throw Failure.notInstalled }
        let output: (status: Int32, text: String) = try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: rex)
                p.arguments = ["server", "start"]
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = pipe
                do {
                    try p.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    p.waitUntilExit()
                    cont.resume(returning: (p.terminationStatus, String(decoding: data, as: UTF8.self)))
                } catch {
                    cont.resume(throwing: Failure.startFailed(error.localizedDescription))
                }
            }
        }
        guard output.status == 0 else {
            throw Failure.startFailed(output.text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        for _ in 0..<50 {
            if isRunning(address) { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw Failure.timedOut
    }
}
