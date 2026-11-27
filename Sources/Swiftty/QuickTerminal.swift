import AppKit
import Carbon.HIToolbox
import RexKit
import SwiftUI

/// A system-wide hotkey, via Carbon's RegisterEventHotKey (no Accessibility permission needed).
@MainActor
final class GlobalHotkey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let hotkey = Unmanaged<GlobalHotkey>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { MainActor.assumeIsolated { hotkey.action() } }
            return noErr
        }, 1, &spec, me, &handlerRef)
    }

    func register(_ hotkey: Hotkey) {
        unregister()
        let id = EventHotKeyID(signature: OSType(0x5357_5459), id: 1) // 'SWTY'
        RegisterEventHotKey(hotkey.keyCode, hotkey.carbonModifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }
}

/// A panel that can take keyboard focus even though it has no title bar.
final class QuickPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// The global-hotkey terminal: one persistent session, full screen on the display under the mouse.
@MainActor
final class QuickTerminalController {
    static let groupId = "__quick__"

    private let app: AppModel
    private var panel: QuickPanel?
    private var hotkey: GlobalHotkey?
    private(set) var state: WindowState?
    private var previousApp: NSRunningApplication?
    private var hideGeneration = 0
    private var ensureTask: Task<Void, Never>?

    init(app: AppModel) {
        self.app = app
        hotkey = GlobalHotkey { [weak self] in self?.toggle() }
        app.settings.onHotkeyChange = { [weak self] in self?.applySettings() }
        applySettings()
    }

    func applySettings() {
        if app.settings.quickTerminalEnabled {
            hotkey?.register(app.settings.hotkey)
        } else {
            hotkey?.unregister()
            hide()
        }
    }

    /// Pause the hotkey while the settings window records a new one.
    func suspendHotkey(_ suspended: Bool) {
        if suspended { hotkey?.unregister() } else { applySettings() }
    }

    var isVisible: Bool { panel?.isVisible == true }

    func toggle() {
        if let panel, panel.isVisible, panel.isKeyWindow, NSApp.isActive {
            hide()
        } else {
            show()
        }
    }

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }
        hideGeneration += 1   // a fade-out still in flight must not hide the panel again
        previousApp = NSApp.isActive ? nil : NSWorkspace.shared.frontmostApplication
        panel.setFrame(screen.frame, display: true)
        panel.alphaValue = 0
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
        Task { await ensureSession() }
        state?.selectedTab.flatMap { app.focusedPane(in: $0) }?.focus()
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        hideGeneration += 1
        let generation = hideGeneration
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, generation == self.hideGeneration else { return }
                panel.orderOut(nil)
                // Give focus back to the app the hotkey was pressed in.
                self.previousApp?.activate()
                self.previousApp = nil
            }
        }
    }

    private func makePanel() -> QuickPanel {
        let panel = QuickPanel(contentRect: NSScreen.main?.frame ?? .zero,
                               styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                               backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        let state = WindowState(app: app)
        state.groupId = Self.groupId
        self.state = state
        let host = NSHostingView(rootView: QuickTerminalView(state: state, close: { [weak self] in self?.hide() })
            .environment(app))
        panel.contentView = host
        return panel
    }

    /// Find the quick session on this Mac (it persists in Rex), or create it.
    private func ensureSession() async {
        // One at a time: two overlapping runs would each create the session.
        if let running = ensureTask { return await running.value }
        let task = Task { await findOrCreateSession() }
        ensureTask = task
        await task.value
        ensureTask = nil
    }

    private func findOrCreateSession() async {
        guard let local = app.local else { return }
        if local.connection != .connected { await local.connect() }
        if let existing = local.sessions.first(where: { $0.label == AppModel.quickSessionLabel }) {
            app.setQuickSession(SessionRef(serverId: local.id, sessionId: existing.sessionId))
        } else if let control = local.control {
            let r = try? await control.createSession(label: AppModel.quickSessionLabel,
                                                    shellOptions: ShellIntegration.shellOptions(cwd: NSHomeDirectory()))
            await local.refreshSessions()
            if let sid = r?["session_id"]?.string {
                await local.ensureAttached(sid)
                await local.refreshView(sid)
                app.setQuickSession(SessionRef(serverId: local.id, sessionId: sid))
            }
        }
        state?.validate()
        try? await Task.sleep(for: .milliseconds(150))
        state?.selectedTab.flatMap { app.focusedPane(in: $0) }?.focus()
    }
}

/// The quick terminal's content: tabs on top, the terminal below, edge to edge.
struct QuickTerminalView: View {
    let state: WindowState
    let close: () -> Void
    @Environment(AppModel.self) private var app
    @State private var width: CGFloat = 1200

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if !state.tabs.isEmpty {
                    TabStrip(state: state, width: max(300, width - 80))
                } else {
                    Spacer()
                }
                Button(action: close) {
                    Image(systemName: "chevron.up").font(.system(size: 12, weight: .semibold)).frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .help("Hide (\(app.settings.hotkey.display))")
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 6)
            Group {
                if let tab = state.selectedTab, let server = app.server(tab.serverId), let window = app.window(tab) {
                    RexWindowView(server: server, sessionId: tab.sessionId, window: window).id(tab)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onChange(of: state.tabs) { state.validate() }
    }
}
