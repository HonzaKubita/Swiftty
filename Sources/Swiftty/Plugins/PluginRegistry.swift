import Foundation
import Observation

/// The plugins built into Swiftty, and which of them are switched on.
@MainActor
@Observable
final class PluginRegistry {
    /// Every plugin, in the order their pills appear. Add yours here.
    nonisolated static let all: [any SwifttyPlugin] = [
        CorePlugin(),
        GitPlugin(),
        CondaPlugin(),
    ]

    static let shared = PluginRegistry()
    private static let defaultsKey = "disabledPlugins"

    private(set) var disabled: Set<String> {
        didSet {
            UserDefaults.standard.set(disabled.sorted(), forKey: Self.defaultsKey)
            engine = CompletionEngine(specs: enabled.flatMap(\.commands))
        }
    }
    /// Completion for the enabled plugins' commands.
    private(set) var engine: CompletionEngine

    private init() {
        let off = Set(UserDefaults.standard.stringArray(forKey: Self.defaultsKey) ?? [])
        disabled = off
        engine = CompletionEngine(specs: Self.all.filter { !off.contains($0.id) }.flatMap(\.commands))
    }

    var enabled: [any SwifttyPlugin] { Self.all.filter { isEnabled($0) } }

    func isEnabled(_ plugin: any SwifttyPlugin) -> Bool {
        plugin.id == CorePlugin.id || !disabled.contains(plugin.id)
    }

    func setEnabled(_ plugin: any SwifttyPlugin, _ on: Bool) {
        guard plugin.id != CorePlugin.id else { return }
        if on { disabled.remove(plugin.id) } else { disabled.insert(plugin.id) }
    }

    /// What new shells report before each prompt.
    var probes: [ShellProbe] { enabled.flatMap(\.probes) }

    func pills(for shell: ShellSnapshot) -> [StatusPill] {
        var seen = Set<String>()
        return enabled.flatMap { $0.pills(for: shell) }.filter { seen.insert($0.id).inserted }
    }
}
