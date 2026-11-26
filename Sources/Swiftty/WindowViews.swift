import AppKit
import RexKit
import SwiftUI

/// One Swiftty window. It holds one Rex session per server it has tabs on; the sidebar
/// groups the tabs by server, and the toolbar shows them as Safari-style tabs.
struct SessionWindowView: View {
    @Binding var groupId: String?
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @State private var state: WindowState?
    @State private var nsWindow: NSWindow?
    @State private var addingServer = false
    @State private var claimed = false
    @State private var detailWidth: CGFloat = 800
    @State private var showingWelcome = false

    var body: some View {
        NavigationSplitView {
            if let state {
                TabsSidebar(state: state, addingServer: $addingServer)
                    .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
            }
        } detail: {
            detail
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { detailWidth = $0 }
                .toolbar {
                    if let state, !state.tabs.isEmpty {
                        ToolbarItem(placement: .principal) {
                            TabStrip(state: state, width: max(300, detailWidth - 48))
                        }
                        .sharedBackgroundVisibility(.hidden)
                    }
                }
        }
        .navigationTitle(title)
        .toolbar(removing: .title)
        .sheet(isPresented: $addingServer) { AddServerSheet() }
        .sheet(isPresented: $showingWelcome) {
            OnboardingView { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { addingServer = true } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showWelcome)) { _ in
            if nsWindow?.isKeyWindow == true || app.normalWindowCount <= 1 { showingWelcome = true }
        }
        .background(WindowAccessor { window in
            nsWindow = window
            window.tabbingMode = .disallowed
            register()
        })
        .focusedSceneValue(\.windowState, state)
        .onAppear {
            app.start()
            if state == nil { state = WindowState(app: app) }
            state?.groupId = groupId
            claimIfNeeded()
            if !app.settings.onboardingDone, app.normalWindowCount == 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { showingWelcome = true }
            }
        }
        .onChange(of: groupId) {
            state?.groupId = groupId
            state?.validate()
            register()
        }
        .onChange(of: app.connectedCount) {
            claimIfNeeded()
            state?.validate()
            #if DEBUG
            if app.local?.connection == .connected, ProcessInfo.processInfo.environment["SWIFTTY_DEBUG_NEW_SESSION"] != nil,
               !DebugFlags.newSessionDone {
                DebugFlags.newSessionDone = true
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    app.newSessionWindow(on: app.local, label: ProcessInfo.processInfo.environment["SWIFTTY_DEBUG_NEW_SESSION_LABEL"]) {
                        openWindow(value: $0)
                    }
                }
            }
            #endif
        }
        .onChange(of: state?.isEmpty) { if state?.isEmpty == true { nsWindow?.close() } }
        .onChange(of: state?.tabs) { state?.validate() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            if let w = note.object as? NSWindow, w === nsWindow { app.windowClosed(w) }
        }
    }

    private func register() {
        guard let nsWindow, let state else { return }
        app.register(nsWindow, state: state)
    }

    /// A window that opened without a group: at launch it restores saved windows,
    /// later (⌘N) it starts a new session on this Mac.
    private func claimIfNeeded() {
        guard groupId == nil, !claimed, app.anyConnected else { return }
        claimed = true
        Task {
            if let (id, others) = await app.groupForEmptyWindow() {
                groupId = id
                for other in others { openWindow(value: other) }
            } else {
                nsWindow?.close()
            }
        }
    }

    @ViewBuilder private var detail: some View {
        if let state, let tab = state.selectedTab, let server = app.server(tab.serverId), let window = app.window(tab) {
            RexWindowView(server: server, sessionId: tab.sessionId, window: window)
                .id(tab)
                .transition(.opacity)
        } else if let state, !state.refs.isEmpty, state.selectedServer?.connection ?? app.local?.connection == .connected {
            ContentUnavailableView {
                Label("No tabs", systemImage: "rectangle.dashed")
            } actions: {
                Button("New Tab") { state.newTab() }.buttonStyle(.glassProminent)
            }
        } else if !app.anyConnected, case .failed(let message)? = app.local?.connection {
            ContentUnavailableView {
                Label(app.isRexInstalledLocally ? "Can't reach Rex" : "No Rex server yet",
                      systemImage: app.isRexInstalledLocally ? "bolt.horizontal.circle" : "server.rack")
            } description: {
                Text(app.isRexInstalledLocally ? message
                     : "Install Rex to use Swiftty on this Mac, or connect to a Rex server on another machine.")
            } actions: {
                HStack {
                    Button("Add Server…") { addingServer = true }.buttonStyle(.glassProminent)
                    if app.isRexInstalledLocally {
                        Button("Try Again") { app.local?.retry() }.buttonStyle(.glass)
                    } else {
                        Link("Get Rex", destination: URL(string: "https://www.superlogical.com/rex/docs")!)
                            .buttonStyle(.glass)
                        Button("Check Again") { app.local?.retry() }.buttonStyle(.glass)
                    }
                }
            }
        } else {
            ProgressView("Connecting to Rex…").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var title: String {
        state?.selectedTab.map { app.tabTitle($0) } ?? "Swiftty"
    }
}

extension FocusedValues {
    @Entry var windowState: WindowState?
}

/// Safari-style tabs: equal widths sharing the toolbar, a soft fill on every tab, and
/// Liquid Glass on the selected one.
struct TabStrip: View {
    let state: WindowState
    /// The width the strip may use (tabs share it equally, like Safari's).
    let width: CGFloat
    @Namespace private var glass

    var body: some View {
        let count = max(state.tabs.count, 1)
        let spacing: CGFloat = 6
        let plus: CGFloat = 28 + spacing
        let tabWidth = max(110, (width - plus - CGFloat(count - 1) * spacing) / CGFloat(count))
        let stripWidth = min(width - plus, CGFloat(count) * tabWidth + CGFloat(count - 1) * spacing)
        HStack(spacing: spacing) {
            ScrollView(.horizontal) {
                GlassEffectContainer(spacing: spacing) {
                    HStack(spacing: spacing) {
                        ForEach(state.tabs, id: \.self) { tab in
                            TabChip(state: state, tab: tab, selected: tab == state.selectedTab, namespace: glass)
                                .frame(width: tabWidth)
                        }
                    }
                }
            }
            .scrollIndicators(.never)
            .frame(width: stripWidth)

            Button {
                state.newTab()
            } label: {
                Image(systemName: "plus").font(.system(size: 12, weight: .medium)).frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .help("New Tab (⌘T)")
        }
        .frame(width: width, height: 30, alignment: .leading)
        .animation(.spring(duration: 0.3, bounce: 0.15), value: state.selectedTab)
        .animation(.spring(duration: 0.3, bounce: 0.15), value: state.tabs)
    }
}

struct TabChip: View {
    let state: WindowState
    let tab: TabRef
    let selected: Bool
    let namespace: Namespace.ID
    @Environment(AppModel.self) private var app
    @State private var hovering = false
    @State private var renaming = false

    var body: some View {
        let running = app.focusedPane(in: tab)?.runningCommand != nil
        let remote = app.server(tab.serverId).flatMap { $0.isLocal ? nil : $0.name }
        ZStack {
            HStack(spacing: 5) {
                if running { ProgressView().controlSize(.mini) }
                if let remote {
                    Image(systemName: "server.rack").font(.system(size: 9)).foregroundStyle(.secondary).help(remote)
                }
                if renaming {
                    RenameField(initial: app.customName(tab) ?? "", placeholder: app.tabTitle(tab)) { name in
                        renaming = false
                        if let name { app.renameTab(tab, to: name) }
                    }
                } else {
                    Text(app.tabTitle(tab))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? .primary : .secondary)
                }
            }
            .padding(.horizontal, 24)
            HStack {
                if hovering && !renaming {
                    Button {
                        state.closeTab(tab)
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).frame(width: 18, height: 18)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .background(.quaternary.opacity(0.5), in: .circle)
                    .help("Close Tab (⌘W)")
                    .transition(.opacity)
                }
                Spacer()
            }
            .padding(.leading, 5)
        }
        .frame(height: 28)
        .frame(maxWidth: .infinity)
        .background {
            if !selected {
                Capsule().fill(.primary.opacity(hovering ? 0.10 : 0.06))
            }
        }
        .contentShape(.capsule)
        .glassEffect(selected ? .regular.interactive() : .identity, in: .capsule)
        .glassEffectID(tab, in: namespace)
        .onTapGesture(count: 2) { renaming = true }
        .onTapGesture { state.select(tab) }
        .onHover { h in withAnimation(.snappy(duration: 0.12)) { hovering = h } }
        .contextMenu {
            Button("Rename Tab…") { renaming = true }
            if app.customName(tab) != nil {
                Button("Use Automatic Name") { app.renameTab(tab, to: "") }
            }
            Divider()
            Button("Close Tab") { state.closeTab(tab) }
        }
    }
}

/// An inline text field for renaming a tab. Return saves, Escape cancels.
struct RenameField: View {
    let initial: String
    let placeholder: String
    let done: (String?) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 12, weight: .semibold))
            .multilineTextAlignment(.center)
            .focused($focused)
            .onAppear { text = initial; focused = true }
            .onSubmit { done(text) }
            .onExitCommand { done(nil) }
            .onChange(of: focused) { if !focused { done(text) } }
    }
}

/// A session the user asked to close, waiting for confirmation.
struct PendingClose: Identifiable {
    let ref: SessionRef
    let label: String
    var id: SessionRef { ref }
}

/// The window's tabs, grouped by server. Each group is one Rex session.
struct TabsSidebar: View {
    let state: WindowState
    @Binding var addingServer: Bool
    @Environment(AppModel.self) private var app
    @State private var closing: PendingClose?

    var body: some View {
        List(selection: Binding<TabRef?>(get: { state.selectedTab }, set: { if let t = $0 { state.selectedTab = t } })) {
            ForEach(state.sections, id: \.ref) { section in
                Section {
                    ForEach(section.tabs, id: \.self) { tab in
                        TabRow(state: state, tab: tab).tag(tab)
                    }
                } header: {
                    SessionHeader(state: state, server: section.server, ref: section.ref) { close(section.ref, section.server) }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack {
                SessionsMenu(state: state, addingServer: $addingServer) { close($0, app.server($0.serverId)) }
                Spacer()
            }
            .padding(10)
        }
        .confirmationDialog(
            "Close “\(closing?.label ?? "")”?",
            isPresented: Binding(get: { closing != nil }, set: { if !$0 { closing = nil } }),
            titleVisibility: .visible,
            presenting: closing
        ) { c in
            Button("Close Session", role: .destructive) {
                app.closeSession(c.ref)
                closing = nil
            }
            Button("Cancel", role: .cancel) { closing = nil }
        } message: { _ in
            Text("Every tab and shell in it ends.")
        }
    }

    private func close(_ ref: SessionRef, _ server: ServerModel?) {
        let label = server?.sessions.first { $0.sessionId == ref.sessionId }.map { server!.label(for: $0) } ?? "session"
        if app.settings.confirmCloseSession {
            closing = PendingClose(ref: ref, label: label)
        } else {
            app.closeSession(ref)
        }
    }
}

/// A server group's header: where these tabs run, plus new-tab and close-session buttons.
struct SessionHeader: View {
    let state: WindowState
    let server: ServerModel
    let ref: SessionRef
    let close: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: server.isLocal ? "laptopcomputer" : "server.rack")
            Text(server.isLocal ? "This Mac" : server.name).lineLimit(1)
            if case .failed(let message) = server.connection {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(message)
            } else if server.connection == .connecting {
                ProgressView().controlSize(.mini)
            }
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                Button {
                    state.newTab(on: server)
                } label: {
                    Image(systemName: "plus").frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .help("New Tab on \(server.isLocal ? "This Mac" : server.name)")
                Button(action: close) {
                    Image(systemName: "xmark").frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .help("Close this session (ends its tabs)")
            }
            .buttonStyle(.plain)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .opacity(hovering ? 1 : 0)
        }
        .padding(.trailing, 4)
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.snappy(duration: 0.12)) { hovering = h } }
        .contextMenu {
            Button("New Tab") { state.newTab(on: server) }
            Divider()
            Button("Close Session…", role: .destructive, action: close)
        }
    }
}

/// Add tabs from other servers, open other sessions in their own windows, manage servers.
struct SessionsMenu: View {
    let state: WindowState
    @Binding var addingServer: Bool
    let close: (SessionRef) -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Menu {
            Section("New Tab On") {
                ForEach(app.servers) { server in
                    Button(server.isLocal ? "This Mac" : server.name,
                           systemImage: server.isLocal ? "laptopcomputer" : "server.rack") {
                        state.newTab(on: server)
                    }
                    .disabled(server.connection != .connected)
                }
            }
            Menu("Open Session in New Window") {
                ForEach(app.servers) { server in
                    Section(server.isLocal ? "This Mac" : server.name) {
                        ForEach(app.visibleSessions(on: server)) { session in
                            let ref = SessionRef(serverId: server.id, sessionId: session.sessionId)
                            Button(server.label(for: session)) { app.show(ref) { openWindow(value: $0) } }
                                .disabled(state.refs.contains(ref))
                        }
                        Button("New Session", systemImage: "plus") {
                            app.newSessionWindow(on: server) { openWindow(value: $0) }
                        }
                        .disabled(server.connection != .connected)
                    }
                }
            }
            Divider()
            Button("Add Server…", systemImage: "server.rack") { addingServer = true }
            ForEach(app.servers.filter { !$0.isLocal }) { server in
                Button("Remove \(server.name)", systemImage: "trash", role: .destructive) { app.removeHost(server) }
            }
        } label: {
            Label("Servers", systemImage: "rectangle.stack")
        }
        .menuIndicator(.hidden)
        .buttonStyle(.glass)
        .fixedSize()
        .help("Tabs on other servers, other sessions, and servers")
    }
}

/// One tab in the sidebar: its title, folder, and a close button on hover.
struct TabRow: View {
    let state: WindowState
    let tab: TabRef
    @Environment(AppModel.self) private var app
    @State private var hovering = false
    @State private var renaming = false

    var body: some View {
        let pane = app.focusedPane(in: tab)
        let title = app.tabTitle(tab)
        let path = pane.map { abbreviated($0.cwd) } ?? ""
        HStack(spacing: 8) {
            Group {
                if pane?.runningCommand != nil {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "terminal").foregroundStyle(.secondary)
                }
            }
            .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                if renaming {
                    RenameField(initial: app.customName(tab) ?? "", placeholder: title) { name in
                        renaming = false
                        if let name { app.renameTab(tab, to: name) }
                    }
                    .multilineTextAlignment(.leading)
                } else {
                    Text(title).lineLimit(1)
                }
                if !path.isEmpty, path != title {
                    Text(path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
            }
            Spacer(minLength: 4)
            if hovering && !renaming {
                Button {
                    state.closeTab(tab)
                } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Close Tab (⌘W)")
                .transition(.opacity)
            }
        }
        .onHover { h in withAnimation(.snappy(duration: 0.12)) { hovering = h } }
        .contextMenu {
            Button("Rename Tab…") { renaming = true }
            if app.customName(tab) != nil {
                Button("Use Automatic Name") { app.renameTab(tab, to: "") }
            }
            Divider()
            Button("Close Tab", role: .destructive) { state.closeTab(tab) }
        }
    }

    private func abbreviated(_ cwd: String) -> String {
        guard !cwd.isEmpty else { return "" }
        if let home = app.server(tab.serverId)?.home, cwd == home || cwd.hasPrefix(home + "/") {
            return "~" + cwd.dropFirst(home.count)
        }
        return cwd
    }
}

/// Hands the hosting NSWindow to SwiftUI code.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = AccessorView()
        v.onWindow = onWindow
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class AccessorView: NSView {
        var onWindow: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }
}

/// Add a remote Rex server to the host list shared with `rex hosts`.
struct AddServerSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @State private var address = ""
    @State private var error: String?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Add Remote Server", systemImage: "server.rack").font(.title2.weight(.semibold))
            Text("Connect to a Rex server on another machine. Swiftty adds it to your Rex hosts, so `rex -S` can use it too.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Form {
                TextField("Name", text: $label, prompt: Text("devbox"))
                TextField("Address", text: $address, prompt: Text("ssh://you@devbox"))
            }
            .formStyle(.grouped)
            VStack(alignment: .leading, spacing: 4) {
                Text("**ssh://user@host** connects over ssh with your keys and ssh config. Rex must be installed there.")
                Text("**host.tailnet.ts.net** or **host:7297** connects straight to a server that listens on the network.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button {
                    add()
                } label: {
                    if working { ProgressView().controlSize(.small) } else { Text("Add Server") }
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(label.trimmingCharacters(in: .whitespaces).isEmpty || address.isEmpty || working)
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    private func add() {
        working = true
        error = nil
        let label = self.label.trimmingCharacters(in: .whitespaces)
        var address = self.address.trimmingCharacters(in: .whitespaces)
        // A bare user@host means ssh.
        if !address.contains("://"), address.contains("@") { address = "ssh://" + address }
        Task {
            do {
                try await app.addHost(label: label, address: address)
                dismiss()
            } catch {
                self.error = (error as? RexError)?.message ?? String(describing: error)
            }
            working = false
        }
    }
}

/// Lays out a Rex window's blocks (splits) and floating layers.
struct RexWindowView: View {
    let server: ServerModel
    let sessionId: String
    let window: RexWindow

    var body: some View {
        Group {
            if let zoomed = window.zoomedBlockId ?? window.tiledZoomedBlockId {
                BlockView(server: server, sessionId: sessionId, blockId: zoomed, focused: true)
            } else if let layout = window.tiledLayer?.layout {
                LayoutNodeView(server: server, node: layout, sessionId: sessionId, focusedId: window.focusedBlockId)
            } else {
                ContentUnavailableView("Empty window", systemImage: "rectangle.dashed")
            }
        }
    }
}

struct LayoutNodeView: View {
    let server: ServerModel
    let node: RexLayoutNode
    let sessionId: String
    let focusedId: String?

    var body: some View {
        switch node {
        case .block(let id, _):
            BlockView(server: server, sessionId: sessionId, blockId: id, focused: id == focusedId)
        case .split(let split, _):
            GeometryReader { geo in
                let ratio = CGFloat(split.ratio ?? 0.5)
                if split.isVertical {
                    VStack(spacing: 0) {
                        LayoutNodeView(server: server, node: split.before, sessionId: sessionId, focusedId: focusedId)
                            .frame(height: geo.size.height * ratio)
                        Divider()
                        LayoutNodeView(server: server, node: split.after, sessionId: sessionId, focusedId: focusedId)
                    }
                } else {
                    HStack(spacing: 0) {
                        LayoutNodeView(server: server, node: split.before, sessionId: sessionId, focusedId: focusedId)
                            .frame(width: geo.size.width * ratio)
                        Divider()
                        LayoutNodeView(server: server, node: split.after, sessionId: sessionId, focusedId: focusedId)
                    }
                }
            }
        }
    }
}

struct BlockView: View {
    let server: ServerModel
    let sessionId: String
    let blockId: String
    let focused: Bool

    var body: some View {
        let block = server.views[sessionId]?.windows.flatMap(\.allBlocks).first { $0.blockId == blockId }
        if block?.isTerminal ?? true {
            PaneView(pane: server.pane(sessionId: sessionId, blockId: blockId), isFocused: focused)
        } else {
            ContentUnavailableView(block?.label ?? "Block", systemImage: "square.dashed",
                                   description: Text("Swiftty doesn't show \(block?.flavor ?? "this kind of") block yet."))
        }
    }
}

#if DEBUG
@MainActor enum DebugFlags { static var newSessionDone = false; static var closeDone = false }
#endif

extension Notification.Name {
    static let showWelcome = Notification.Name("SwifttyShowWelcome")
}
