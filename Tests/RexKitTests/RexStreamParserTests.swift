import Foundation
import Testing
@testable import RexKit

struct RexStreamParserTests {
    /// A minimal snapshot: envelope, one record, FINISH.
    func snapshot(payload: [UInt8] = [1, 2, 3]) -> Data {
        var d = Data("GHOSTSNP".utf8) + Data([1, 0])
        func record(_ tag: UInt16, _ p: [UInt8]) {
            d.append(contentsOf: [UInt8(tag & 0xff), UInt8(tag >> 8)])
            let n = UInt32(p.count)
            d.append(contentsOf: [UInt8(n & 0xff), UInt8((n >> 8) & 0xff), UInt8((n >> 16) & 0xff), UInt8(n >> 24)])
            d.append(contentsOf: [0, 0, 0, 0])
            d.append(contentsOf: p)
        }
        record(1, payload)
        record(6, [])
        return d
    }

    func apc(_ nonce: UInt64, _ json: String) -> Data {
        Data("\u{1b}_rex1;\(nonce);\(json)\u{1b}\\".utf8)
    }

    func collect(_ events: [RexStreamEvent]) -> (snap: [Data], out: Data, msgs: [RexStreamMessage]) {
        var snaps: [Data] = [], out = Data(), msgs: [RexStreamMessage] = []
        for e in events {
            switch e {
            case .snapshot(let d): snaps.append(d)
            case .output(let d): out.append(d)
            case .message(let m): msgs.append(m)
            }
        }
        return (snaps, out, msgs)
    }

    @Test func snapshotThenMessagesThenOutput() {
        var p = RexStreamParser(nonce: 42)
        let snap = snapshot()
        let stream = snap + apc(42, #"{"type":"resize","cols":80,"rows":24,"cell_width_px":8,"cell_height_px":16,"owner":null}"#)
            + Data("hello".utf8) + apc(42, #"{"type":"child_exited","exit_code":3}"#) + Data("!".utf8)
        let r = collect(p.feed(stream))
        #expect(r.snap == [snap])
        #expect(r.out == Data("hello!".utf8))
        #expect(r.msgs == [.resize(columns: 80, rows: 24, cellWidth: 8, cellHeight: 16, owner: nil), .childExited(code: 3)])
    }

    @Test func everySplitPointGivesTheSameResult() {
        let snap = snapshot(payload: Array(repeating: 7, count: 50))
        let stream = snap + Data("ab".utf8) + apc(9, #"{"type":"child_exited","exit_code":0}"#) + Data("cd\u{1b}[0m".utf8)
        for cut in 1..<stream.count {
            var p = RexStreamParser(nonce: 9)
            let r = collect(p.feed(stream.prefix(cut)) + p.feed(stream.dropFirst(cut)))
            #expect(r.snap == [snap], "cut \(cut)")
            #expect(r.out == Data("abcd\u{1b}[0m".utf8), "cut \(cut)")
            #expect(r.msgs == [.childExited(code: 0)], "cut \(cut)")
        }
    }

    @Test func forgedNonceStaysInOutput() {
        var p = RexStreamParser(nonce: 1)
        let forged = apc(2, #"{"type":"child_exited","exit_code":0}"#)
        let r = collect(p.feed(snapshot()) + p.feed(forged))
        #expect(r.msgs.isEmpty)
        #expect(r.out == forged)
    }

    @Test func ticketDecodes() throws {
        let d = try RexTerminalStream.decodeTicket("VsDmErYMCD79K3CxtL-pMQ")
        #expect(d.count == 16)
    }

    @Test func layoutDecodesSplits() throws {
        let json = #"{"rect":[0,0,1,1],"split":{"split_id":"s1","direction":"horizontal","ratio":0.5,"before":{"rect":[0,0,0.5,1],"block_id":"block:a"},"after":{"rect":[0.5,0,0.5,1],"block_id":"block:b"}}}"#
        let v = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        let node = try v.decode(RexLayoutNode.self)
        #expect(node.blockIds == ["block:a", "block:b"])
    }
}
