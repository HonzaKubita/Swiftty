import AppKit
import RexKit
import SwiftUI

/// Swiftty → Settings… (⌘,).
struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Quick Terminal", systemImage: "rectangle.inset.filled.on.rectangle") { QuickTerminalSettings() }
            Tab("Plugins", systemImage: "puzzlepiece.extension") { PluginsSettings() }
            Tab("Servers", systemImage: "server.rack") { ServersSettings() }
        }
        .frame(width: 520)
        .scenePadding()
    }
}

struct GeneralSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section("Keyboard") {
                Toggle("Use Option as Meta key", isOn: $settings.optionIsMeta)
                Text("Option+key sends Meta (Esc) sequences to programs, like most terminals. Turn it off to type special characters with Option.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Sessions") {
                Toggle("Ask before closing a session", isOn: $settings.confirmCloseSession)
            }
            if Updater.shared.isAvailable {
                Section("Updates") {
                    UpdateSettings()
                }
            }
            Section("Shell Integration") {
                LabeledContent("Supported shells", value: "zsh, bash 4.4+")
                Text("New tabs start your login shell with Swiftty's prompt and command blocks, on this Mac and on remote servers.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(height: Updater.shared.isAvailable ? 460 : 340)
    }
}

struct QuickTerminalSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section {
                Toggle("Enable the Quick Terminal", isOn: $settings.quickTerminalEnabled)
                LabeledContent("Hotkey") {
                    HotkeyRecorder(hotkey: $settings.hotkey)
                }
                .disabled(!settings.quickTerminalEnabled)
                Toggle("Hide the Dock icon when no other window is open", isOn: $settings.hideDockWithoutWindows)
                    .disabled(!settings.quickTerminalEnabled)
            } footer: {
                Text("The hotkey shows one persistent session full screen on the display under the pointer, from any app. Press it again to hide it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(height: 260)
    }
}

/// Click, then press a key combination with at least one modifier.
struct HotkeyRecorder: View {
    @Binding var hotkey: Hotkey
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            recording ? stop() : start()
        } label: {
            Text(recording ? "Type a shortcut…" : hotkey.display)
                .font(.system(.body, design: .rounded).weight(.medium))
                .frame(minWidth: 120)
        }
        .buttonStyle(.glass)
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        (NSApp.delegate as? AppDelegate)?.quick?.suspendHotkey(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if event.keyCode == 0x35, mods.isEmpty { stop(); return nil } // Escape cancels
            guard !mods.isEmpty else { NSSound.beep(); return nil }
            hotkey = Hotkey(keyCode: UInt32(event.keyCode), modifiers: mods.rawValue)
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        (NSApp.delegate as? AppDelegate)?.quick?.suspendHotkey(false)
    }
}

/// Which plugins contribute completions and status pills.
struct PluginsSettings: View {
    @State private var registry = PluginRegistry.shared

    var body: some View {
        Form {
            Section {
                ForEach(PluginRegistry.all, id: \.id) { plugin in
                    Toggle(isOn: Binding(get: { registry.isEnabled(plugin) }, set: { registry.setEnabled(plugin, $0) })) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(plugin.name)
                                Text(plugin.summary).font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: plugin.symbol)
                        }
                    }
                    .disabled(plugin.id == CorePlugin.id)
                }
            } footer: {
                Text("Plugins add completions and the status pills above the prompt. Pills that read the shell's state (git branch, conda environment) follow a change in new tabs.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(height: 340)
    }
}

struct ServersSettings: View {
    @Environment(AppModel.self) private var app
    @State private var adding = false

    var body: some View {
        Form {
            Section {
                ForEach(app.servers) { server in
                    HStack {
                        Image(systemName: server.isLocal ? "laptopcomputer" : "server.rack").frame(width: 20)
                        VStack(alignment: .leading) {
                            Text(server.isLocal ? "This Mac" : server.name)
                            Text(server.address.endpoint.description).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        switch server.connection {
                        case .connected: Label("Connected", systemImage: "circle.fill").labelStyle(.iconOnly).foregroundStyle(.green).font(.caption)
                        case .connecting, .idle: ProgressView().controlSize(.small)
                        case .failed(let m): Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(m)
                        }
                        if !server.isLocal {
                            Button("Remove", role: .destructive) { app.removeHost(server) }.buttonStyle(.borderless)
                        }
                    }
                }
            } footer: {
                HStack {
                    Text("Servers are shared with `rex hosts`.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Add Server…") { adding = true }
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 300)
        .sheet(isPresented: $adding) { AddServerSheet() }
    }
}

/// Swiftty → About Swiftty.
struct AboutView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 128, height: 128)
                .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
            Text("Swiftty").font(.system(size: 28, weight: .bold, design: .rounded))
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1")")
                .foregroundStyle(.secondary)
            Text("A native macOS terminal for Rex, with a native prompt and command blocks.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 300)
            if let local = app.local, local.connection == .connected {
                Label("Connected to Rex on this Mac", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            }
            Divider().frame(width: 220)
            VStack(spacing: 4) {
                Link("Rex by Superlogical", destination: URL(string: "https://www.superlogical.com/rex/docs")!)
                Link("Terminal engine: libghostty-vt", destination: URL(string: "https://ghostty.org")!)
            }
            .font(.caption)
        }
        .padding(32)
        .frame(width: 380)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
        .padding(12)
    }
}

struct UpdateSettings: View {
    @State private var updater = Updater.shared
    @State private var checks = Updater.shared.automaticallyChecks
    @State private var downloads = Updater.shared.automaticallyDownloads

    var body: some View {
        Toggle("Check for updates automatically", isOn: $checks)
            .onChange(of: checks) { updater.automaticallyChecks = checks }
        Toggle("Download and install updates automatically", isOn: $downloads)
            .onChange(of: downloads) { updater.automaticallyDownloads = downloads }
            .disabled(!checks)
        HStack {
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                .foregroundStyle(.secondary)
            Spacer()
            Button("Check Now") { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
        }
    }
}
