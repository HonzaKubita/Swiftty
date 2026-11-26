import Foundation
import Testing
@testable import TerminalKit

@MainActor
struct TerminalEngineTests {
    @Test func writesAndReadsBackText() throws {
        let t = try TerminalEngine(columns: 20, rows: 3)
        t.write(Data("hi \u{1b}[1;31mred\u{1b}[0m".utf8))
        let f = try #require(t.frame(force: true))
        #expect(f.columns == 20 && f.rows == 3)
        let line = f.cells[0].map { $0.text.isEmpty ? " " : $0.text }.joined()
        #expect(line.hasPrefix("hi red"))
        #expect(f.cells[0][3].flags & 1 == 1) // bold
    }

    @Test func reportsSemanticPrompts() throws {
        let t = try TerminalEngine(columns: 40, rows: 5)
        var events: [SemanticPromptEvent] = []
        t.onSemanticPrompt = { events.append($0) }
        t.write(Data("\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}ls\r\n\u{1b}]133;C\u{07}out\r\n\u{1b}]133;D;2\u{07}".utf8))
        #expect(events.contains(.promptStart))
        #expect(events.contains(.commandEnd(exitCode: 2)))
    }
}

import RexKit

/// Feeds a stream captured from a live Rex server, when one is provided.
@MainActor
struct CapturedStreamTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFTTY_STREAM_FIXTURE"] != nil))
    func decodesCapturedStream() throws {
        let env = ProcessInfo.processInfo.environment
        let data = try Data(contentsOf: URL(fileURLWithPath: env["SWIFTTY_STREAM_FIXTURE"]!))
        let nonce = UInt64(env["SWIFTTY_STREAM_NONCE"] ?? "0") ?? 0
        var parser = RexStreamParser(nonce: nonce)
        let t = try TerminalEngine()
        var sawSnapshot = false, sawResize = false
        for event in parser.feed(data) {
            switch event {
            case .snapshot(let s): try t.restore(snapshot: s); sawSnapshot = true
            case .output(let o): t.write(o)
            case .message(.resize(let c, let r, let w, let h, _)): t.resize(columns: c, rows: r, cellWidth: w, cellHeight: h); sawResize = true
            case .message: break
            }
        }
        #expect(sawSnapshot && sawResize)
        let f = try #require(t.frame(force: true))
        let text = f.cells.map { $0.map { $0.text.isEmpty ? " " : $0.text }.joined() }.joined(separator: "\n")
        #expect(text.contains("swiftty-probe"))
        print("columns", f.columns, "rows", f.rows)
    }
}
