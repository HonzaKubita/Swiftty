import AppKit
import SwiftUI
import TerminalKit

/// Hosts the pane's TerminalView (created once, owned by the pane).
struct TerminalHost: NSViewRepresentable {
    let pane: PaneModel
    func makeNSView(context: Context) -> TerminalView { pane.terminalView }
    func updateNSView(_ nsView: TerminalView, context: Context) {}
}

/// One terminal pane: native command blocks (or the full terminal), plus the floating prompt.
struct PaneView: View {
    let pane: PaneModel
    let isFocused: Bool
    @Environment(AppModel.self) private var app
    @State private var controller: PromptController?
    @State private var barHeight: CGFloat = 70
    @State private var size: CGSize = .zero

    var body: some View {
        ZStack(alignment: .bottom) {
            switch pane.displayMode {
            case .blocks:
                BlockList(pane: pane, bottomInset: barHeight + BlockList.spacing)
            case .terminal:
                TerminalHost(pane: pane)
            }

            if pane.usesNativePrompt, let controller {
                PromptBar(pane: pane, controller: controller)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { barHeight = $0 }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            statusOverlay
        }
        .background(Color(nsColor: .textBackgroundColor))
        .animation(.spring(duration: 0.35, bounce: 0.15), value: pane.usesNativePrompt)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0; relayout() }
        .onChange(of: barHeight) { relayout() }
        .onChange(of: pane.usesNativePrompt) { relayout() }
        .onAppear {
            if controller == nil {
                controller = PromptController(pane: pane, engine: app.completions, history: app.history)
            }
            relayout()
            if isFocused { DispatchQueue.main.async { pane.focus() } }
        }
    }

    private func relayout() {
        pane.layout(size: size, promptHeight: barHeight)
    }

    @ViewBuilder private var statusOverlay: some View {
        switch pane.status {
        case .connecting:
            ProgressView().controlSize(.small)
                .padding(10)
                .glassEffect(.regular, in: .capsule)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView("Can't show this terminal", systemImage: "exclamationmark.triangle", description: Text(message))
                .padding()
                .glassEffect(.regular, in: .rect(cornerRadius: 20))
                .padding(40)
        case .exited(let code):
            Label("Shell exited with code \(code)", systemImage: "power")
                .font(.callout)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .glassEffect(.regular, in: .capsule)
                .padding(.bottom, 16)
        case .live:
            EmptyView()
        }
    }
}

/// Finished commands as native cards in a native scroll view, then the running command.
struct BlockList: View {
    let pane: PaneModel
    let bottomInset: CGFloat

    /// Space between blocks, and between the newest block and the prompt.
    static let spacing: CGFloat = 10

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Self.spacing) {
                if !pane.preamble.isEmpty {
                    OutputText(text: pane.preamble)
                        .padding(.horizontal, PaneModel.outputInset)
                        .foregroundStyle(.secondary)
                }
                ForEach(pane.blocks) { block in
                    BlockCard(pane: pane, block: block)
                        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 8)), removal: .opacity))
                }
                if let running = pane.running {
                    LiveBlockCard(pane: pane, record: running)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .animation(.snappy(duration: 0.25), value: pane.blocks.map(\.id))
        }
        .scrollIndicators(.automatic)
        .defaultScrollAnchor(.bottom)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .contentMargins(.bottom, bottomInset, for: .scrollContent)
    }
}

/// The card background every block shares.
struct BlockCardStyle: ViewModifier {
    var failed = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(failed ? Color.red.opacity(0.55) : Color.primary.opacity(0.06), lineWidth: failed ? 1.5 : 1)
            }
    }
}

/// One finished command: its command line, status, and selectable output.
struct BlockCard: View {
    let pane: PaneModel
    let block: CommandBlock

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(block.command.isEmpty ? "—" : block.command)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(4)
                Spacer(minLength: 12)
                BlockBadge(exitCode: block.exitCode, duration: block.duration)
            }
            if !block.output.isEmpty {
                OutputText(text: block.output)
            }
        }
        .modifier(BlockCardStyle(failed: block.failed))
        .contextMenu {
            Button("Copy Command") { copy(block.command) }
            Button("Copy Output") { copy(block.output.plainText) }
            Button("Copy Command and Output") { copy(block.command + "\n" + block.output.plainText) }
            Divider()
            Button("Run Again") { pane.rerun(block) }
                .disabled(pane.shellState != .prompt)
        }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

/// The running command: a live view of the terminal rows it has written so far.
struct LiveBlockCard: View {
    let pane: PaneModel
    let record: CommandRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(record.command.isEmpty ? "Running" : record.command)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .lineLimit(2)
                Spacer(minLength: 12)
                ProgressView().controlSize(.mini)
            }
            TerminalHost(pane: pane)
                .frame(height: CGFloat(pane.liveRows) * pane.terminalView.cellSize.height)
                .animation(nil, value: pane.liveRows)
        }
        .modifier(BlockCardStyle())
    }
}

/// Exit status and duration of a finished command.
struct BlockBadge: View {
    let exitCode: Int32?
    let duration: TimeInterval?

    var body: some View {
        if exitCode != nil || duration != nil {
            HStack(spacing: 5) {
                if let code = exitCode, code != 0 {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                    Text("\(code)").monospacedDigit()
                } else if exitCode != nil {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                if let duration {
                    Text(Self.format(duration)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 10.5, weight: .medium))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .glassEffect(.regular, in: .capsule)
        }
    }

    static func format(_ t: TimeInterval) -> String {
        if t < 1 { return String(format: "%.0f ms", t * 1000) }
        if t < 60 { return String(format: "%.1f s", t) }
        return String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
    }
}

/// The floating glass prompt: context chips over a native text field.
struct PromptBar: View {
    let pane: PaneModel
    @Bindable var controller: PromptController
    @State private var barWidth: CGFloat = 600

    /// Where the text field starts inside the bar: padding + chevron + spacing.
    static let fieldInset: CGFloat = 14 + 11 + 8

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ContextChips(pane: pane)
            if let running = pane.runningCommand, pane.shellState == .running {
                RunningRow(command: running)
            } else {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tint)
                        .frame(height: 19)
                    PromptField(pane: pane, controller: controller)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { barWidth = $0 }
        .overlay(alignment: .topLeading) {
            if controller.isShowingCompletions {
                // Above the bar, starting at the caret, kept inside the bar's width.
                let x = min(max(0, Self.fieldInset + controller.caretX - 14), max(0, barWidth - CompletionList.width))
                CompletionList(controller: controller)
                    .offset(x: x, y: -CompletionList.height(for: controller.items.count) - 8)
                    .transition(.scale(scale: 0.96, anchor: .bottomLeading).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.2), value: controller.isShowingCompletions)
        .animation(.snappy(duration: 0.25), value: pane.shellState)
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }
}

/// Folder, git branch and last exit status above the prompt.
struct ContextChips: View {
    let pane: PaneModel

    var body: some View {
        HStack(spacing: 6) {
            if !pane.cwd.isEmpty {
                Chip(symbol: "folder", text: abbreviate(pane.cwd))
            }
            if let branch = pane.gitBranch {
                Chip(symbol: "arrow.triangle.branch", text: branch)
            }
            if let last = pane.lastFinished, let code = last.exitCode, code != 0 {
                Chip(symbol: "xmark.circle", text: "exit \(code)", tint: .red)
            }
            Spacer(minLength: 0)
        }
        .animation(.snappy, value: pane.cwd)
        .animation(.snappy, value: pane.gitBranch)
    }

    private func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

struct Chip: View {
    let symbol: String
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(tint)
            .lineLimit(1)
            .truncationMode(.head)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(.quaternary.opacity(0.6), in: .capsule)
            .contentTransition(.opacity)
    }
}

/// Shown in place of the field while a command runs.
struct RunningRow: View {
    let command: CommandRecord

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.mini)
            Text(command.command.isEmpty ? "Running…" : command.command)
                .font(.system(size: 13, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            Text("⌃C to stop")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(minHeight: 18)
    }
}

/// The completion list: a glass panel anchored at the caret.
struct CompletionList: View {
    @Bindable var controller: PromptController

    static let width: CGFloat = 300
    static func height(for count: Int) -> CGFloat { min(CGFloat(count) * 26 + 10, 260) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(controller.items.enumerated()), id: \.offset) { i, item in
                        CompletionRow(item: item, selected: i == controller.selection)
                            .id(i)
                            .transaction { $0.animation = nil }
                            .contentShape(Rectangle())
                            .onTapGesture { controller.apply(item) }
                    }
                }
                .padding(5)
            }
            .scrollIndicators(.never)
            .onChange(of: controller.selection) { _, i in
                guard let i else { return }
                withAnimation(.snappy(duration: 0.15)) { proxy.scrollTo(i, anchor: .center) }
            }
        }
        .frame(width: Self.width, height: Self.height(for: controller.items.count))
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }
}

struct CompletionRow: View {
    let item: Completion
    let selected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: item.kind.symbol)
                .font(.system(size: 11))
                .frame(width: 16)
                .foregroundStyle(selected ? .white : .secondary)
            Text(item.display)
                .font(.system(size: 12.5, design: .monospaced))
                .lineLimit(1)
            Spacer(minLength: 0)
            if let detail = item.detail {
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 25)
        .foregroundStyle(selected ? .white : .primary)
        .background(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 7))
    }
}

