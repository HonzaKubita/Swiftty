import AppKit
import RexKit
import TerminalKit
import simd

/// Swiftty's terminal colors, one set per appearance.
enum TerminalTheme {
    static func rexTheme(dark: Bool) -> RexTheme {
        let palette = dark ? darkPalette : lightPalette
        return RexTheme(
            foreground: dark ? "#E8E8EA" : "#1D1D1F",
            background: dark ? "#1E1E20" : "#FFFFFF",
            cursor: dark ? "#E8E8EA" : "#1D1D1F",
            palette: palette.enumerated().map { "\($0.offset)=\($0.element)" },
            scheme: dark ? "dark" : "light")
    }

    // ANSI 0–15, tuned to sit with system colors.
    static let darkPalette = [
        "#3A3A3C", "#FF6B63", "#5FD37A", "#F5C15A", "#5AA7FF", "#D58BFF", "#5FD3E6", "#D1D1D6",
        "#8E8E93", "#FF8A82", "#7EE297", "#FFD57A", "#7DBBFF", "#E2A8FF", "#86E3F0", "#FFFFFF",
    ]
    static let lightPalette = [
        "#1D1D1F", "#C6302B", "#1F8A3B", "#9A6B00", "#1A5FD0", "#8A3BB8", "#0F7C8C", "#6E6E73",
        "#8E8E93", "#E0443E", "#2EA44F", "#B98500", "#2F74E8", "#A24FD3", "#1795A8", "#3A3A3C",
    ]

    static func blockFill(dark: Bool) -> SIMD4<Float> {
        dark ? SIMD4(1, 1, 1, 0.045) : SIMD4(0, 0, 0, 0.035)
    }

    static func failedStroke(dark: Bool) -> SIMD4<Float> {
        dark ? SIMD4(1, 0.42, 0.39, 0.55) : SIMD4(0.78, 0.19, 0.17, 0.45)
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}
