import AppKit
import SwiftUI

@main
struct SwifttyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        // A window holds tabs from one or more servers; the value names its group of sessions.
        WindowGroup(for: String.self) { $groupId in
            SessionWindowView(groupId: $groupId)
                .environment(model)
                .frame(minWidth: 560, minHeight: 340)
                .onAppear { appDelegate.attach(model) }
        }
        .defaultSize(width: 1080, height: 720)
        .restorationBehavior(.disabled)
        .commands {
            SwifttyCommands(model: model)
        }

        Settings {
            SettingsView().environment(model)
        }

        Window("About Swiftty", id: "about") {
            AboutView().environment(model)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var model: AppModel?
    private(set) var quick: QuickTerminalController?
    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Bundle.main.bundleIdentifier == nil {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
        }
        NSWindow.allowsAutomaticWindowTabbing = false
        // ⌘W closes the current tab (and its shell). With no tabs left, it closes the window.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags == .command, event.charactersIgnoringModifiers == "w",
                  let window = NSApp.keyWindow, !window.isSheet, window.attachedSheet == nil
            else { return event }
            let handled = MainActor.assumeIsolated { () -> Bool in
                let state = window is QuickPanel ? self?.quick?.state : self?.model?.state(for: window)
                guard let state, let tab = state.selectedTab else { return false }
                state.closeTab(tab)
                return true
            }
            return handled ? nil : event
        }
    }

    /// Called once the SwiftUI app has its model.
    @MainActor
    func attach(_ model: AppModel) {
        guard self.model == nil else { return }
        self.model = model
        model.start()
        _ = Updater.shared
        quick = QuickTerminalController(app: model)
        model.onWindowCountChange = { [weak self] count in self?.updateDockPresence(windowCount: count) }
        #if DEBUG
        if ProcessInfo.processInfo.environment["SWIFTTY_DEBUG_QUICK"] != nil {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(4))
                self.quick?.toggle()
            }
        }
        if let labels = ProcessInfo.processInfo.environment["SWIFTTY_DEBUG_CLOSE_SESSIONS"] {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(5))
                guard let local = model.local else { return }
                for s in local.sessions where labels.split(separator: ",").contains(where: { $0 == (s.label ?? "") }) {
                    model.closeSession(SessionRef(serverId: local.id, sessionId: s.sessionId))
                }
            }
        }
        if ProcessInfo.processInfo.environment["SWIFTTY_DEBUG_CLOSE_WINDOWS"] != nil {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(6))
                for w in NSApp.windows where !(w is QuickPanel) && w.isVisible { w.performClose(nil) }
            }
        }
        #endif
    }

    /// With the quick terminal on, Swiftty leaves the Dock when its last normal window closes;
    /// the hotkey keeps working, and the next window brings the Dock icon back.
    @MainActor
    private func updateDockPresence(windowCount: Int) {
        guard let model else { return }
        let hide = windowCount == 0 && model.settings.quickTerminalEnabled && model.settings.hideDockWithoutWindows
        let policy: NSApplication.ActivationPolicy = hide ? .accessory : .regular
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        if !hide { NSApp.activate() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated { model?.isTerminating = true }
        return .terminateNow
    }
}

struct SwifttyCommands: Commands {
    let model: AppModel
    @FocusedValue(\.windowState) private var state
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Swiftty") { openWindow(id: "about") }
            if Updater.shared.isAvailable {
                Button("Check for Updates…") { Updater.shared.checkForUpdates() }
                    .disabled(!Updater.shared.canCheckForUpdates)
            }
        }
        CommandGroup(replacing: .newItem) {
            Button("New Window") {
                model.newSessionWindow(on: model.local) { openWindow(value: $0) }
            }
            .keyboardShortcut("n")
            Button("New Tab") { state?.newTab() }
                .keyboardShortcut("t")
                .disabled(state == nil)
            Divider()
            Button("Show Quick Terminal") {
                (NSApp.delegate as? AppDelegate)?.quick?.toggle()
            }
            .disabled(!model.settings.quickTerminalEnabled)
        }
        CommandGroup(replacing: .help) {
            Button("Welcome to Swiftty") { NotificationCenter.default.post(name: .showWelcome, object: nil) }
            Link("Rex Documentation", destination: URL(string: "https://www.superlogical.com/rex/docs")!)
        }
        CommandMenu("Tabs") {
            Button("Close Tab") { if let t = state?.selectedTab { state?.closeTab(t) } }
                .disabled(state?.selectedTab == nil)
            Divider()
            Button("Show Next Tab") { state?.selectTab(offset: 1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Show Previous Tab") { state?.selectTab(offset: -1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Divider()
            ForEach(1..<10) { i in
                Button("Tab \(i)") { state?.selectTab(index: i - 1) }
                    .keyboardShortcut(KeyEquivalent(Character("\(i)")), modifiers: .command)
            }
        }
    }
}
