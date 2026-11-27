import Foundation

/// A session as `session.list` / bootstrap describe it.
public struct RexSessionSummary: Sendable, Codable, Hashable, Identifiable {
    public var sessionId: String
    public var label: String?
    public var id: String { sessionId }
}

/// `session.view`: everything needed to draw one session.
public struct RexSessionView: Sendable, Codable, Hashable {
    public var revision: Int
    public var sessionId: String
    public var label: String?
    public var activeWindowId: String?
    public var windows: [RexWindow]
}

public struct RexWindow: Sendable, Codable, Hashable, Identifiable {
    public var windowId: String
    public var label: String?
    public var focusedBlockId: String?
    public var zoomedBlockId: String?
    public var tiledZoomedBlockId: String?
    public var layers: [RexLayer]
    public var id: String { windowId }

    /// The tiled layer, which holds the window's layout.
    public var tiledLayer: RexLayer? { layers.first { $0.kind == "tiled" } ?? layers.first }

    /// Every block in every layer.
    public var allBlocks: [RexBlock] { layers.flatMap(\.blocks) }
}

public struct RexLayer: Sendable, Codable, Hashable, Identifiable {
    public var layerId: String
    public var kind: String?
    public var bounds: [Double]?
    public var state: String?
    public var layout: RexLayoutNode?
    public var blocks: [RexBlock]
    public var id: String { layerId }
}

public struct RexBlock: Sendable, Codable, Hashable, Identifiable {
    public var blockId: String
    public var label: String?
    public var creatorName: String?
    public var flavor: String?
    public var hostId: String?
    public var owner: String?
    public var id: String { blockId }

    public var isTerminal: Bool { creatorName == "com.superlogical.terminal" }
}

/// A node of a layer's split tree.
public indirect enum RexLayoutNode: Sendable, Hashable, Codable {
    case block(id: String, rect: [Double])
    case split(Split, rect: [Double])

    public struct Split: Sendable, Hashable, Codable {
        public var splitId: String?
        public var direction: String
        public var ratio: Double?
        public var before: RexLayoutNode
        public var after: RexLayoutNode

        public var isVertical: Bool { direction == "vertical" }
    }

    private enum CodingKeys: String, CodingKey { case rect, blockId, split }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rect = try c.decodeIfPresent([Double].self, forKey: .rect) ?? [0, 0, 1, 1]
        if let id = try c.decodeIfPresent(String.self, forKey: .blockId) {
            self = .block(id: id, rect: rect)
        } else {
            self = .split(try c.decode(Split.self, forKey: .split), rect: rect)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .block(let id, let rect):
            try c.encode(id, forKey: .blockId)
            try c.encode(rect, forKey: .rect)
        case .split(let s, let rect):
            try c.encode(s, forKey: .split)
            try c.encode(rect, forKey: .rect)
        }
    }

    public var blockIds: [String] {
        switch self {
        case .block(let id, _): [id]
        case .split(let s, _): s.before.blockIds + s.after.blockIds
        }
    }
}

/// The parts of `session.bootstrap`'s response Swiftty uses.
public struct RexBootstrap: Sendable, Decodable {
    public struct AttachAll: Sendable, Decodable { public var sessions: [RexSessionSummary] }
    public struct Selected: Sendable, Decodable {
        public var session: RexSessionSummary?
        public var view: RexSessionView?
    }

    public var clientId: String
    public var attachAll: AttachAll?
    public var selectedSession: Selected?
}

public struct RexDataTicket: Sendable, Decodable {
    public var ticket: String
    public var expiresInMs: Int
}

/// Terminal colors, as Rex reports and accepts them (hex RRGGBB).
public struct RexTheme: Sendable, Codable, Hashable {
    public var foreground: String?
    public var background: String?
    public var cursor: String?
    public var palette: [String]?
    public var scheme: String?

    public init(foreground: String? = nil, background: String? = nil, cursor: String? = nil,
                palette: [String]? = nil, scheme: String? = nil) {
        self.foreground = foreground
        self.background = background
        self.cursor = cursor
        self.palette = palette
        self.scheme = scheme
    }
}

// MARK: - Typed calls

extension RexControl {
    public func bootstrap(preferredSessionId: String? = nil) async throws -> RexBootstrap {
        var p: [String: JSONValue] = ["event_scope": "all"]
        if let preferredSessionId { p["preferred_session_id"] = .string(preferredSessionId) }
        return try await call("session.bootstrap", .object(p), as: RexBootstrap.self)
    }

    public func listSessions() async throws -> [RexSessionSummary] {
        let r = try await call("session.list")
        return try (r["sessions"] ?? .array([])).decode([RexSessionSummary].self)
    }

    public func attach(sessionId: String) async throws {
        try await call("session.attach", ["session_id": .string(sessionId)])
    }

    public func view(sessionId: String) async throws -> RexSessionView {
        try await call("session.view", ["session_id": .string(sessionId)], as: RexSessionView.self)
    }

    public func dataTicket(sessionId: String, blockId: String) async throws -> RexDataTicket {
        try await call("data.connect", [
            "session_id": .string(sessionId),
            "block_id": .string(blockId),
            "data_ref_id": "terminal",
            "subprotocol": .string(RexTerminalStream.subprotocol),
        ], as: RexDataTicket.self)
    }

    public func own(sessionId: String, blockIds: [String]) async throws {
        try await call("session.own_block", [
            "session_id": .string(sessionId),
            "block_ids": .array(blockIds.map { .string($0) }),
            "mode": "take",
        ])
    }

    @discardableResult
    public func blockMethod(sessionId: String, blockId: String, _ method: String, _ args: JSONValue = [:]) async throws -> JSONValue {
        try await call("block.method", [
            "session_id": .string(sessionId),
            "block_id": .string(blockId),
            "method": .string(method),
            "args": args,
        ])
    }

    public func resize(sessionId: String, blockId: String, columns: Int, rows: Int, cellWidth: Int, cellHeight: Int) async throws {
        try await blockMethod(sessionId: sessionId, blockId: blockId, "resize", [
            "columns": .int(Int64(columns)),
            "rows": .int(Int64(rows)),
            "cell_width_px": .int(Int64(cellWidth)),
            "cell_height_px": .int(Int64(cellHeight)),
        ])
    }

    /// Type text into a terminal, as if the user typed it.
    public func write(sessionId: String, blockId: String, _ text: String) async throws {
        try await blockMethod(sessionId: sessionId, blockId: blockId, "write", ["data": .string(text)])
    }

    public func paste(sessionId: String, blockId: String, _ text: String) async throws {
        try await call("block.event", [
            "session_id": .string(sessionId),
            "block_id": .string(blockId),
            "event": ["type": "paste", "payload": ["text": .string(text)]],
        ])
    }

    public func sendKey(sessionId: String, blockId: String, _ key: RexKeyEvent) async throws {
        try await call("block.event", [
            "session_id": .string(sessionId),
            "block_id": .string(blockId),
            "event": ["type": "key", "payload": try JSONValue.from(key)],
        ])
    }

    public func sendFocus(sessionId: String, blockId: String, focused: Bool) async throws {
        try await call("block.event", [
            "session_id": .string(sessionId),
            "block_id": .string(blockId),
            "event": ["type": "focus", "payload": ["action": .string(focused ? "in" : "out")]],
        ])
    }

    public func setTheme(sessionId: String, blockId: String, _ theme: RexTheme) async throws {
        try await blockMethod(sessionId: sessionId, blockId: blockId, "set_theme", try JSONValue.from(theme))
    }

    /// Create a window holding one Swiftty shell. Returns the new window's ID if Rex reports it.
    @discardableResult
    public func newWindow(sessionId: String, label: String? = nil, shellOptions: JSONValue) async throws -> JSONValue {
        var p: [String: JSONValue] = [
            "session_id": .string(sessionId),
            "layout": ["block": ["flavor": "com.superlogical.terminal.shell", "options": shellOptions]],
        ]
        if let label { p["window_label"] = .string(label) }
        return try await call("session.new_window", .object(p))
    }

    public func createSession(label: String? = nil, shellOptions: JSONValue) async throws -> JSONValue {
        var p: [String: JSONValue] = [
            "initial_windows": [["layout": ["block": ["flavor": "com.superlogical.terminal.shell", "options": shellOptions]]]],
        ]
        if let label { p["label"] = .string(label) }
        return try await call("session.create", .object(p))
    }

    /// End a session and every shell in it.
    public func destroySession(sessionId: String) async throws {
        try await call("session.destroy", ["session_id": .string(sessionId), "undoable": true])
    }

    public func listHosts() async throws -> [RexHost] {
        let r = try await call("hosts.list")
        return try (r["hosts"] ?? .array([])).decode([RexHost].self)
    }

    public func putHost(label: String, endpoints: [String]) async throws {
        try await call("hosts.put", ["host": [
            "label": .string(label),
            "endpoints": .array(endpoints.map { .string($0) }),
            "added_from": "Swiftty",
        ]])
    }

    public func removeHost(id: String) async throws {
        try await call("hosts.remove", ["id": .string(id)])
    }

    /// List a directory on the terminal's machine (for path completion on remote servers).
    public func listDir(sessionId: String, blockId: String, path: String, prefix: String,
                        limit: Int = 300) async throws -> RexDirListing {
        try await blockMethod(sessionId: sessionId, blockId: blockId, "list_dir", [
            "path": .string(path), "prefix": .string(prefix), "files": true, "limit": .int(Int64(limit)),
        ]).decode(RexDirListing.self)
    }

    public func closeWindow(sessionId: String, windowId: String) async throws {
        try await call("session.close_window", ["session_id": .string(sessionId), "window_id": .string(windowId)])
    }

    public func focusWindow(sessionId: String, windowId: String) async throws {
        try await call("session.focus_window", ["session_id": .string(sessionId), "window_id": .string(windowId)])
    }
}

/// A key event in Rex's format (W3C code names in snake_case).
public struct RexKeyEvent: Sendable, Codable, Hashable {
    public var key: String
    public var mods: String
    public var consumedMods: String
    public var text: String
    public var unshiftedCodepoint: Int
    public var composing: Bool
    public var action: String

    public init(key: String, mods: String, consumedMods: String, text: String,
                unshiftedCodepoint: Int, composing: Bool = false, action: String = "press") {
        self.key = key
        self.mods = mods
        self.consumedMods = consumedMods
        self.text = text
        self.unshiftedCodepoint = unshiftedCodepoint
        self.composing = composing
        self.action = action
    }
}

/// A Rex server in your host list (shared with `rex hosts`).
public struct RexHost: Sendable, Codable, Hashable, Identifiable {
    public var id: String
    public var label: String
    public var endpoints: [String]?
    public var icon: String?
    public var hostId: String?

    public init(id: String, label: String, endpoints: [String]?, icon: String? = nil, hostId: String? = nil) {
        self.id = id
        self.label = label
        self.endpoints = endpoints
        self.icon = icon
        self.hostId = hostId
    }
}

public struct RexDirListing: Sendable, Decodable {
    public struct Entry: Sendable, Decodable {
        public var name: String
        public var file: Bool?
        public var symlink: Bool?
    }
    public var path: String
    public var home: String?
    public var status: String?
    public var entries: [Entry]?
}
