import AppKit
import Observation
import RexKit
import SwiftUI

/// Identifies one Rex window (a tab) on one server.
struct TabRef: Codable, Hashable {
    var serverId: String
    var sessionId: String
    var windowId: String
}

/// One Rex server: this Mac's own, or a remote one from the host list.
@MainActor
@Observable
final class ServerModel: Identifiable {
    enum Connection: Equatable {
        case idle
        case connecting
        case connected
        case failed(String)
    }

    let id: String
    var name: String
    let address: RexServerAddress
    let isLocal: Bool
    /// The Rex host entry behind a remote server.
    let host: RexHost?

    private(set) var connection: Connection = .idle
    private(set) var sessions: [RexSessionSummary] = []
    private(set) var views: [String: RexSessionView] = [:]
    private(set) var primarySessionId: String?
    /// The home directory shells see (for "~" in titles and completion).
    private(set) var home: String?

    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored private(set) var control: RexControl?
    @ObservationIgnored private var panes: [String: PaneModel] = [:]
    @ObservationIgnored private var attached: Set<String> = []
    @ObservationIgnored private var refreshTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?

    static let localId = "local"

    init(local app: AppModel) {
        id = Self.localId
        name = Host.current().localizedName ?? "This Mac"
        address = .personal
        isLocal = true
        host = nil
        home = NSHomeDirectory()
        self.app = app
    }

    init(host: RexHost, endpoint: RexEndpoint, app: AppModel) {
        id = host.id
        name = host.label
        address = RexServerAddress(endpoint: endpoint)
        isLocal = false
        self.host = host
        self.app = app
    }

    // MARK: Connecting

    func connect() async {
        guard connection != .connecting else { return }
        connection = .connecting
        if isLocal, !RexServerLauncher.isRunning(address) {
            if RexServerLauncher.findExecutable() == nil {
                connection = .failed(String(describing: RexServerLauncher.Failure.notInstalled))
                return
            }
            do {
                try await RexServerLauncher.start(address: address)
            } catch {
                connection = .failed(String(describing: error))
                return
            }
        }
        let control = RexControl(address: address, client: RexClientInfo(label: Host.current().localizedName ?? "Mac"))
        do {
            try await control.connect()
            self.control = control
            let boot = try await control.bootstrap()
            sessions = boot.attachAll?.sessions ?? []
            if let view = boot.selectedSession?.view {
                views[view.sessionId] = view
                attached.insert(view.sessionId)
                primarySessionId = view.sessionId
            }
            if sessions.isEmpty && isLocal {
                // A fresh server: start one session with a Swiftty shell.
                let created = try await control.createSession(shellOptions: ShellIntegration.shellOptions(cwd: NSHomeDirectory()))
                await refreshSessions()
                primarySessionId = created["session_id"]?.string ?? sessions.first?.sessionId
            }
            connection = .connected
            eventTask = Task { [weak self] in
                for await event in control.events { self?.handle(event) }
            }
            for s in sessions where views[s.sessionId] == nil { await refreshView(s.sessionId) }
            app?.validateSelection()
        } catch {
            connection = .failed(String(describing: error))
        }
    }

    func disconnect() {
        reconnectTask?.cancel()
        eventTask?.cancel()
        for p in panes.values { p.stop() }
        panes.removeAll()
        Task { await control?.disconnect() }
        control = nil
        connection = .idle
    }

    func retry() {
        Task { await connect() }
    }

    private func handle(_ event: RexEvent) {
        switch event.type {
        case "swiftty_disconnected":
            connection = .failed("Lost the connection to \(name)")
            for p in panes.values { p.stop() }
            panes.removeAll()
            attached.removeAll()
            control = nil
            reconnectTask = Task {
                try? await Task.sleep(for: .seconds(isLocal ? 2 : 5))
                guard !Task.isCancelled else { return }
                await connect()
            }
        case "session_created", "session_destroyed", "session_moved":
            Task { await refreshSessions() }
        case "session_event":
            guard let e = event.sessionEvent else { return }
            switch e.type {
            case "session_view_changed", "window_created", "window_closed", "block_created", "block_closed",
                 "active_window_changed":
                scheduleRefresh(e.sessionId)
            default:
                break
            }
        default:
            break
        }
    }

    // MARK: Sessions and views

    func refreshSessions() async {
        guard let control else { return }
        if let list = try? await control.listSessions() {
            sessions = list
            let ids = Set(list.map(\.sessionId))
            for id in views.keys where !ids.contains(id) { views[id] = nil }
            for s in list where views[s.sessionId] == nil { await refreshView(s.sessionId) }
            app?.validateSelection()
        }
    }

    private func scheduleRefresh(_ sessionId: String) {
        refreshTasks[sessionId]?.cancel()
        refreshTasks[sessionId] = Task {
            try? await Task.sleep(for: .milliseconds(30))
            guard !Task.isCancelled else { return }
            await refreshView(sessionId)
        }
    }

    func refreshView(_ sessionId: String) async {
        guard let control else { return }
        if let view = try? await control.view(sessionId: sessionId) {
            views[sessionId] = view
            let live = Set(view.windows.flatMap { $0.allBlocks.map(\.blockId) })
            for (id, pane) in panes where pane.sessionId == sessionId && !live.contains(id) {
                pane.stop()
                panes[id] = nil
            }
            app?.validateSelection()
        }
    }

    func window(sessionId: String, windowId: String) -> RexWindow? {
        views[sessionId]?.windows.first { $0.windowId == windowId }
    }

    func tabs(for sessionId: String) -> [TabRef] {
        views[sessionId]?.windows.map { TabRef(serverId: id, sessionId: sessionId, windowId: $0.windowId) } ?? []
    }

    func defaultTab(in sessionId: String) -> TabRef? {
        guard let view = views[sessionId], let wid = view.activeWindowId ?? view.windows.first?.windowId else { return nil }
        return TabRef(serverId: id, sessionId: sessionId, windowId: wid)
    }

    func defaultTab() -> TabRef? {
        let sid = primarySessionId ?? sessions.first?.sessionId
        if let sid, let t = defaultTab(in: sid) { return t }
        return sessions.lazy.compactMap { self.defaultTab(in: $0.sessionId) }.first
    }

    // MARK: Panes

    func pane(sessionId: String, blockId: String) -> PaneModel {
        if let p = panes[blockId] { return p }
        let p = PaneModel(sessionId: sessionId, blockId: blockId, server: self)
        panes[blockId] = p
        Task {
            await ensureAttached(sessionId)
            p.start()
        }
        return p
    }

    func existingPane(blockId: String) -> PaneModel? { panes[blockId] }

    func ensureAttached(_ sessionId: String) async {
        guard !attached.contains(sessionId), let control else { return }
        try? await control.attach(sessionId: sessionId)
        attached.insert(sessionId)
    }

    func noteHome(_ path: String?) {
        if let path, !path.isEmpty, home == nil { home = path }
    }

    // MARK: Actions

    func newTab(in sessionId: String, cwd: String?) async -> TabRef? {
        guard let control else { return nil }
        await ensureAttached(sessionId)
        let before = Set(views[sessionId]?.windows.map(\.windowId) ?? [])
        do {
            let r = try await control.newWindow(sessionId: sessionId, shellOptions: ShellIntegration.shellOptions(cwd: cwd))
            await refreshView(sessionId)
            let wid = r["window_id"]?.string ?? views[sessionId]?.windows.map(\.windowId).first { !before.contains($0) }
            return wid.map { TabRef(serverId: id, sessionId: sessionId, windowId: $0) }
        } catch {
            NSLog("Swiftty: new window failed: \(error)")
            return nil
        }
    }

    func newSession(label: String? = nil) async -> TabRef? {
        guard let control else { return nil }
        do {
            let r = try await control.createSession(label: label, shellOptions: ShellIntegration.shellOptions(cwd: isLocal ? NSHomeDirectory() : nil))
            await refreshSessions()
            guard let sid = r["session_id"]?.string ?? sessions.last?.sessionId else { return nil }
            await ensureAttached(sid)
            await refreshView(sid)
            return defaultTab(in: sid)
        } catch {
            NSLog("Swiftty: new session failed: \(error)")
            return nil
        }
    }

    func closeWindow(sessionId: String, windowId: String) {
        guard let control else { return }
        Task {
            await ensureAttached(sessionId)
            do {
                try await control.closeWindow(sessionId: sessionId, windowId: windowId)
            } catch {
                NSLog("Swiftty: closing window failed: \(error)")
            }
            await refreshView(sessionId)
        }
    }

    func closeSession(_ sessionId: String) {
        guard let control else { return }
        Task {
            await ensureAttached(sessionId)
            do {
                try await control.destroySession(sessionId: sessionId)
            } catch {
                NSLog("Swiftty: closing session failed: \(error)")
            }
            await refreshSessions()
        }
    }

    func renameWindow(sessionId: String, windowId: String, label: String) {
        guard let control else { return }
        Task {
            await ensureAttached(sessionId)
            _ = try? await control.call("session.set_window_label", [
                "session_id": .string(sessionId), "window_id": .string(windowId), "label": .string(label),
            ])
            await refreshView(sessionId)
        }
    }

    func focusWindow(sessionId: String, windowId: String) {
        guard let control else { return }
        Task {
            await ensureAttached(sessionId)
            try? await control.focusWindow(sessionId: sessionId, windowId: windowId)
        }
    }

    func label(for session: RexSessionSummary) -> String {
        session.label ?? String(session.sessionId.suffix(8))
    }
}

/// Identifies one Rex session on one server.
struct SessionRef: Codable, Hashable {
    var serverId: String
    var sessionId: String
}

/// Everything Swiftty knows: the servers, their sessions, and which window holds which sessions.
///
/// A window holds one Rex session per server it has tabs on (this Mac, a Linux box, …).
/// Which sessions belong to which window is Swiftty's own bookkeeping, saved across launches.
@MainActor
@Observable
final class AppModel {
    private(set) var servers: [ServerModel] = []
    var hostsError: String?
    /// Window id → the sessions it holds, in sidebar order.
    private(set) var groups: [String: [SessionRef]] = [:] { didSet { saveGroups() } }

    let history = CommandHistory()
    let completions: CompletionEngine
    let settings = AppSettings.shared

    @ObservationIgnored private var started = false
    @ObservationIgnored var isTerminating = false
    @ObservationIgnored private var restoredLaunchWindows = false
    @ObservationIgnored private var windows: [String: WeakWindow] = [:]
    @ObservationIgnored private var windowStates: [ObjectIdentifier: WindowState] = [:]
    /// Fires when the number of normal windows changes (for hiding the Dock icon).
    @ObservationIgnored var onWindowCountChange: ((Int) -> Void)?

    struct WeakWindow { weak var window: NSWindow? }

    /// The session the global-hotkey window shows; it never appears in normal windows.
    static let quickSessionLabel = "swiftty-quick"

    var local: ServerModel? { servers.first { $0.isLocal } }

    init() {
        completions = CompletionEngine(history: history)
        if let data = UserDefaults.standard.data(forKey: "windowGroups"),
           let saved = try? JSONDecoder().decode([String: [SessionRef]].self, from: data) {
            groups = saved
        }
    }

    private func saveGroups() {
        if let data = try? JSONEncoder().encode(groups) {
            UserDefaults.standard.set(data, forKey: "windowGroups")
        }
    }

    // MARK: Servers

    func start() {
        guard !started else { return }
        started = true
        let local = ServerModel(local: self)
        servers = [local]
        Task {
            await local.connect()
            await loadHosts()
        }
    }

    func server(_ id: String) -> ServerModel? { servers.first { $0.id == id } }

    /// A server Swiftty remembers itself, so remote servers work even without Rex on this Mac.
    struct SavedServer: Codable, Hashable {
        var id: String
        var label: String
        var address: String
    }

    private(set) var savedServers: [SavedServer] = {
        guard let data = UserDefaults.standard.data(forKey: "savedServers"),
              let list = try? JSONDecoder().decode([SavedServer].self, from: data) else { return [] }
        return list
    }() {
        didSet { if let data = try? JSONEncoder().encode(savedServers) { UserDefaults.standard.set(data, forKey: "savedServers") } }
    }

    /// True when a server is connected (this Mac's or a remote one).
    var anyConnected: Bool { servers.contains { $0.connection == .connected } }
    var connectedCount: Int { servers.filter { $0.connection == .connected }.count }

    /// Whether Rex is installed (or running) on this Mac.
    var isRexInstalledLocally: Bool {
        RexServerLauncher.findExecutable() != nil || RexServerLauncher.isRunning(.personal)
    }

    /// Remote servers: the ones saved in Swiftty, plus Rex's own host list (shared with `rex hosts`)
    /// when Rex runs on this Mac.
    func loadHosts() async {
        var hosts = savedServers.map { RexHost(id: $0.id, label: $0.label, endpoints: [$0.address]) }
        if let control = local?.control, let rexHosts = try? await control.listHosts() { hosts += rexHosts }
        var seen = Set<String>()
        var wanted: [String: (RexHost, RexEndpoint)] = [:]
        for host in hosts {
            guard let endpoint = (host.endpoints ?? []).lazy.compactMap(RexEndpoint.init).first(where: { !$0.isLocal }),
                  seen.insert(endpoint.description).inserted else { continue }
            wanted[host.id] = (host, endpoint)
        }
        for (id, (host, endpoint)) in wanted.sorted(by: { $0.value.0.label < $1.value.0.label }) where server(id) == nil {
            let s = ServerModel(host: host, endpoint: endpoint, app: self)
            servers.append(s)
            Task { await s.connect() }
        }
        for s in servers where !s.isLocal && wanted[s.id] == nil { removeServerLocally(s) }
    }

    func addHost(label: String, address: String) async throws {
        guard RexEndpoint(address) != nil else { throw RexError(code: "bad_address", message: "That doesn't look like a server address") }
        savedServers.append(SavedServer(id: "saved:" + UUID().uuidString, label: label, address: address))
        // Share it with `rex hosts` too, when Rex runs on this Mac.
        if let control = local?.control { try? await control.putHost(label: label, endpoints: [address]) }
        await loadHosts()
    }

    func removeHost(_ server: ServerModel) {
        let endpoint = server.address.endpoint.description
        savedServers.removeAll { $0.id == server.id || RexEndpoint($0.address)?.description == endpoint }
        removeServerLocally(server)
        guard let control = local?.control else { return }
        Task {
            // Remove it from Rex's list as well, wherever it matches.
            if let rexHosts = try? await control.listHosts() {
                for h in rexHosts where (h.endpoints ?? []).compactMap(RexEndpoint.init).contains(where: { $0.description == endpoint }) {
                    try? await control.removeHost(id: h.id)
                }
            }
        }
    }

    private func removeServerLocally(_ server: ServerModel) {
        server.disconnect()
        servers.removeAll { $0.id == server.id }
    }

    /// Sessions that normal windows may show (not the hotkey window's).
    func visibleSessions(on server: ServerModel) -> [RexSessionSummary] {
        server.sessions.filter { !(server.isLocal && $0.label == Self.quickSessionLabel) }
    }

    /// A server's sessions or windows changed: let each window check its sessions still exist.
    func validateSelection() {
        for state in windowStates.values { state.validate() }
    }

    // MARK: Window groups

    func sessions(inGroup id: String) -> [SessionRef] { groups[id] ?? [] }

    /// The global-hotkey window's session (kept out of normal windows).
    func setQuickSession(_ ref: SessionRef) {
        if groups[QuickTerminalController.groupId] != [ref] { groups[QuickTerminalController.groupId] = [ref] }
    }

    func group(containing ref: SessionRef) -> String? {
        groups.first { $0.value.contains(ref) }?.key
    }

    /// A window opened without a group. At launch it takes a saved group (and the caller
    /// opens the others); later it starts a new session on this Mac.
    /// Returns the group id, and the other saved groups to reopen.
    func groupForEmptyWindow() async -> (String, [String])? {
        // This Mac's server if it runs, otherwise any connected remote server.
        let preferred = self.local?.connection == .connected ? self.local : servers.first { $0.connection == .connected }
        guard let local = preferred else { return nil }
        if !restoredLaunchWindows {
            restoredLaunchWindows = true
            pruneGroups()
            let saved = groups.keys.filter { $0 != QuickTerminalController.groupId }.sorted()
            if let first = saved.first { return (first, Array(saved.dropFirst())) }
            if let sid = local.primarySessionId ?? visibleSessions(on: local).first?.sessionId {
                let id = UUID().uuidString
                groups[id] = [SessionRef(serverId: local.id, sessionId: sid)]
                return (id, [])
            }
        }
        guard let tab = await local.newSession() else { return nil }
        let id = UUID().uuidString
        groups[id] = [SessionRef(serverId: tab.serverId, sessionId: tab.sessionId)]
        return (id, [])
    }

    /// Drop sessions that no longer exist on servers we can see, and empty groups.
    private func pruneGroups() {
        var changed = groups
        for (id, refs) in groups {
            let kept = refs.filter { ref in
                guard let s = server(ref.serverId), s.connection == .connected else { return true }
                return s.sessions.contains { $0.sessionId == ref.sessionId }
            }
            changed[id] = kept.isEmpty ? nil : kept
        }
        if changed != groups { groups = changed }
    }

    func register(_ window: NSWindow, state: WindowState) {
        windowStates[ObjectIdentifier(window)] = state
        if let id = state.groupId { windows[id] = WeakWindow(window: window) }
        onWindowCountChange?(normalWindowCount)
    }

    /// A normal window closed. If the person closed it (not quitting), forget its group;
    /// its sessions keep running in Rex and stay reachable from the sessions menu.
    func windowClosed(_ window: NSWindow) {
        let state = windowStates.removeValue(forKey: ObjectIdentifier(window))
        if let id = state?.groupId {
            windows[id] = nil
            if !isTerminating { groups[id] = nil }
        }
        onWindowCountChange?(normalWindowCount)
    }

    var normalWindowCount: Int { windowStates.keys.count }

    func state(for window: NSWindow?) -> WindowState? {
        window.flatMap { windowStates[ObjectIdentifier($0)] }
    }

    /// Bring forward the window holding a session, or open a new window for it.
    func show(_ ref: SessionRef, open: (String) -> Void) {
        if let id = group(containing: ref) {
            if let w = windows[id]?.window { w.makeKeyAndOrderFront(nil) } else { open(id) }
        } else {
            let id = UUID().uuidString
            groups[id] = [ref]
            open(id)
        }
    }

    /// Start a session on a server in a new window.
    func newSessionWindow(on server: ServerModel?, label: String? = nil, open: @escaping (String) -> Void) {
        guard let server else { return }
        Task {
            if let tab = await server.newSession(label: label) {
                let id = UUID().uuidString
                groups[id] = [SessionRef(serverId: tab.serverId, sessionId: tab.sessionId)]
                open(id)
            }
        }
    }

    /// Give a window a tab on a server: in its session there, or a new session if it has none.
    func newTab(inGroup id: String, on server: ServerModel, cwd: String?) async -> TabRef? {
        if let ref = sessions(inGroup: id).first(where: { $0.serverId == server.id }) {
            return await server.newTab(in: ref.sessionId, cwd: cwd)
        }
        guard let tab = await server.newSession() else { return nil }
        groups[id, default: []].append(SessionRef(serverId: tab.serverId, sessionId: tab.sessionId))
        return tab
    }

    /// End a session everywhere: Rex closes it, and windows drop it.
    func closeSession(_ ref: SessionRef) {
        server(ref.serverId)?.closeSession(ref.sessionId)
        removeFromGroups(ref)
    }

    func removeFromGroups(_ ref: SessionRef) {
        for (id, refs) in groups where refs.contains(ref) {
            let rest = refs.filter { $0 != ref }
            groups[id] = rest
            if rest.isEmpty { windows[id]?.window?.close() }
        }
    }

    // MARK: Lookups

    func window(_ ref: TabRef) -> RexWindow? {
        server(ref.serverId)?.window(sessionId: ref.sessionId, windowId: ref.windowId)
    }

    func focusedPane(in ref: TabRef) -> PaneModel? {
        guard let s = server(ref.serverId), let w = window(ref),
              let bid = w.focusedBlockId ?? w.allBlocks.first?.blockId else { return nil }
        return s.existingPane(blockId: bid)
    }

    /// A name the person gave the tab, if any (Rex's defaults look like "Window 1a2b3c4d").
    func customName(_ ref: TabRef) -> String? {
        guard let label = window(ref)?.label, !label.isEmpty else { return nil }
        if label.range(of: #"^Window [0-9a-f]{8}$"#, options: .regularExpression) != nil { return nil }
        return label
    }

    /// What a tab is called: its custom name, else the running command, the folder, or the title.
    func tabTitle(_ ref: TabRef) -> String {
        if let name = customName(ref) { return name }
        guard let w = window(ref) else { return "Shell" }
        if let pane = focusedPane(in: ref) {
            if let cmd = pane.runningCommand?.command, !cmd.isEmpty { return cmd }
            if !pane.cwd.isEmpty {
                if let home = server(ref.serverId)?.home, pane.cwd == home { return "~" }
                return (pane.cwd as NSString).lastPathComponent
            }
            if !pane.title.isEmpty { return pane.title }
        }
        _ = w
        return "Shell"
    }

    func renameTab(_ ref: TabRef, to name: String) {
        server(ref.serverId)?.renameWindow(sessionId: ref.sessionId, windowId: ref.windowId, label: name)
    }
}

/// One Swiftty window: the sessions it holds (one per server) and which tab is selected.
@MainActor
@Observable
final class WindowState {
    var groupId: String?
    var selectedTab: TabRef? {
        didSet {
            guard let tab = selectedTab, selectedTab != oldValue else { return }
            app?.server(tab.serverId)?.focusWindow(sessionId: tab.sessionId, windowId: tab.windowId)
        }
    }
    /// Set when the window has nothing left to show: it should close.
    private(set) var isEmpty = false

    @ObservationIgnored weak var app: AppModel?

    init(app: AppModel) { self.app = app }

    var refs: [SessionRef] { groupId.map { app?.sessions(inGroup: $0) ?? [] } ?? [] }

    /// The sidebar's sections: each session with its server and tabs.
    var sections: [(ref: SessionRef, server: ServerModel, tabs: [TabRef])] {
        refs.compactMap { ref in
            guard let server = app?.server(ref.serverId) else { return nil }
            return (ref, server, server.tabs(for: ref.sessionId))
        }
    }

    var tabs: [TabRef] { sections.flatMap(\.tabs) }

    var selectedServer: ServerModel? { selectedTab.flatMap { app?.server($0.serverId) } }

    /// Drop sessions that ended, keep a valid tab selected, and notice when nothing is left.
    func validate() {
        guard let app, let groupId else { return }
        for ref in refs {
            guard let s = app.server(ref.serverId), s.connection == .connected else { continue }
            if !s.sessions.contains(where: { $0.sessionId == ref.sessionId }) { app.removeFromGroups(ref) }
        }
        if app.sessions(inGroup: groupId).isEmpty, app.anyConnected {
            isEmpty = true
            return
        }
        let all = tabs
        if let sel = selectedTab, all.contains(sel) { return }
        selectedTab = all.first
    }

    func select(_ tab: TabRef) { selectedTab = tab }

    func selectTab(offset: Int) {
        let t = tabs
        guard let sel = selectedTab, let i = t.firstIndex(of: sel), !t.isEmpty else { return }
        selectedTab = t[(i + offset + t.count) % t.count]
    }

    func selectTab(index: Int) {
        let t = tabs
        if t.indices.contains(index) { selectedTab = t[index] }
    }

    /// New tab on the selected tab's server (or this Mac).
    func newTab() {
        newTab(on: selectedServer ?? app?.local)
    }

    func newTab(on server: ServerModel?) {
        guard let app, let groupId, let server else { return }
        let cwd = selectedTab.flatMap { $0.serverId == server.id ? app.focusedPane(in: $0)?.cwd : nil }
        Task { if let t = await app.newTab(inGroup: groupId, on: server, cwd: cwd) { selectedTab = t } }
    }

    /// Close a tab (its Rex window ends).
    func closeTab(_ tab: TabRef) {
        let t = tabs
        if selectedTab == tab, let i = t.firstIndex(of: tab) {
            let rest = t.filter { $0 != tab }
            selectedTab = rest.isEmpty ? nil : rest[min(i, rest.count - 1)]
        }
        app?.server(tab.serverId)?.closeWindow(sessionId: tab.sessionId, windowId: tab.windowId)
    }
}
