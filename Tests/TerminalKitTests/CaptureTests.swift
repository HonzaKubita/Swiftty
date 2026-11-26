import Foundation
import Testing
@testable import TerminalKit

@MainActor
struct CaptureTests {
    let A = "\u{1b}]133;A\u{07}", B = "\u{1b}]133;B\u{07}", C = "\u{1b}]133;C\u{07}"
    func D(_ c: Int) -> String { "\u{1b}]133;D;\(c)\u{07}" }

    @Test func capturesOutputAtCommandEnd() throws {
        let t = try TerminalEngine(columns: 40, rows: 10)
        var captured: [StyledText] = []
        t.onSemanticPrompt = { e in if case .commandEnd = e { captured.append(t.captureFinishedOutput()) } }
        t.write(Data("\(A)\(B)ls\r\n\(C)one \u{1b}[31mred\u{1b}[0m\r\ntwo\r\n\(D(0))\r\n\(A)\(B)".utf8))
        let out = try #require(captured.first)
        #expect(out.plainText == "one red\ntwo")
        #expect(out.runs.contains { $0.text == "red" && $0.style.fg == .palette(1) })
    }

    @Test func rebuildsHistory() throws {
        let t = try TerminalEngine(columns: 40, rows: 10)
        t.write(Data("Last login\r\n\(A)\(B)echo a\r\n\(C)a\r\n\(D(0))\r\n\(A)\(B)false\r\n\(C)\(D(1))\r\n\(A)\(B)".utf8))
        let (pre, cmds) = t.capturedHistory()
        #expect(pre.plainText == "Last login")
        #expect(cmds.map(\.command) == ["echo a", "false"])
        #expect(cmds.first?.output.plainText == "a")
        #expect(cmds.last?.output.isEmpty == true)
    }

    @Test func parsesSGR() {
        let s = StyledText.parse(vt: "a\u{1b}[1;38;2;1;2;3mb\u{1b}[0mc\r\n")
        #expect(s.plainText == "abc")
        #expect(s.runs[1].style.bold && s.runs[1].style.fg == .rgb(1, 2, 3))
    }
}

@MainActor
struct ColumnTests {
    @Test func keepsGapsBetweenColumns() throws {
        let t = try TerminalEngine(columns: 40, rows: 10)
        var captured: StyledText?
        t.onSemanticPrompt = { e in if case .commandEnd = e { captured = t.captureFinishedOutput() } }
        t.write(Data("\u{1b}]133;A\u{07}\u{1b}]133;B\u{07}ls\r\n\u{1b}]133;C\u{07}bin\todin\r\ngo\u{1b}[20Gtools\r\n\u{1b}]133;D;0\u{07}\r\n".utf8))
        let out = try #require(captured)
        print("CAPTURED:", out.plainText.debugDescription)
        #expect(out.plainText == "bin     odin\ngo                 tools")
    }
}
