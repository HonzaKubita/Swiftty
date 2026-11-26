import Foundation
import Testing
@testable import RexKit

struct TransportTests {
    static let rex = "/Applications/Rex.app/Contents/Helpers/Rex Server.rex/Contents/MacOS/rex"

    /// The stdio bridge that ssh endpoints use, run locally against the real server.
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: rex) && ProcessInfo.processInfo.environment["SWIFTTY_LIVE_TESTS"] != nil))
    func stdioBridgeSpeaksControlProtocol() async throws {
        let transport = try RexTransport.openCommand(Self.rex, ["__internal", "dial-stdio"])
        let ws = try UnixWebSocket.handshake(transport: transport, path: "/api/control", subprotocol: "rex.control.v1")
        ws.send(text: #"{"type":"hello","client":{"name":"SwifttyTest","version":"0","kind":"app","label":"test"}}"#)
        var it = ws.messages.makeAsyncIterator()
        guard case .text(let welcome)? = try await it.next() else { Issue.record("no welcome"); return }
        #expect(welcome.contains(#""type":"welcome""#))
        ws.close()
    }

    @Test func parsesEndpoints() {
        #expect(RexEndpoint("ssh://me@devbox") == .ssh(destination: "me@devbox"))
        #expect(RexEndpoint("studio.tail1234.ts.net") == .tcp(host: "studio.tail1234.ts.net", port: 7297))
        #expect(RexEndpoint("192.168.1.20:7000") == .tcp(host: "192.168.1.20", port: 7000))
        #expect(RexEndpoint("unix:///tmp/rex.sock") == .unix(path: "/tmp/rex.sock"))
    }
}
