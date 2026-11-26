import AppKit
import RexKit
import SwiftUI

/// First-launch welcome: what Swiftty needs (Rex), whether it's here, and how to start.
struct OnboardingView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let addServer: () -> Void
    @State private var rexPath: String? = RexServerLauncher.findExecutable()
    @State private var checking = false

    private var rexFound: Bool { rexPath != nil || app.local?.connection == .connected }

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 96, height: 96)
                    .shadow(color: .black.opacity(0.2), radius: 10, y: 5)
                Text("Welcome to Swiftty")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                Text("A native Mac terminal with a real text-field prompt and command blocks.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 14) {
                Feature(symbol: "character.cursor.ibeam", title: "A prompt that edits like a Mac",
                        text: "Selection, ⌥/⌘ navigation, undo, and completions that open as you type.")
                Feature(symbol: "square.stack", title: "Command blocks",
                        text: "Every command gets its own card with selectable output, exit status and timing.")
                Feature(symbol: "server.rack", title: "Local and remote",
                        text: "Tabs on this Mac and on other machines, side by side in one window.")
                Feature(symbol: "rectangle.inset.filled.on.rectangle", title: "Quick Terminal",
                        text: "Press \(app.settings.hotkey.display) anywhere for a full-screen terminal.")
            }
            .frame(maxWidth: 420, alignment: .leading)

            rexStatus

            HStack(spacing: 10) {
                if rexFound {
                    Button("Get Started") { finish() }
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Use Remote Servers Only") {
                        finish()
                        addServer()
                    }
                    .buttonStyle(.glass)
                    Button("Check Again") { check() }
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(36)
        .frame(width: 540)
    }

    /// Swiftty is a client for Rex: say whether Rex is here, and where to get it.
    @ViewBuilder private var rexStatus: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: rexFound ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.title2)
                .foregroundStyle(rexFound ? .green : .orange)
            VStack(alignment: .leading, spacing: 4) {
                if rexFound {
                    Text("Rex is installed").font(.headline)
                    Text("Swiftty runs your shells through Rex, which keeps them alive between launches.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Rex isn't installed on this Mac").font(.headline)
                    Text("Swiftty uses Rex to run and keep your shells. Install Rex to use this Mac, or continue and connect to Rex running on another machine.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Link("Get Rex →", destination: URL(string: "https://www.superlogical.com/rex/docs")!)
                        .font(.callout.weight(.medium))
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
            if checking { ProgressView().controlSize(.small) }
        }
        .padding(16)
        .frame(maxWidth: 440)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }

    private func check() {
        checking = true
        rexPath = RexServerLauncher.findExecutable()
        Task {
            if rexPath != nil { await app.local?.connect() }
            checking = false
        }
    }

    private func finish() {
        app.settings.onboardingDone = true
        dismiss()
    }
}

private struct Feature: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
