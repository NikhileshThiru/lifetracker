import SwiftUI

/// Dark-mode-first design tokens. The timeline is the hero; chrome is minimal,
/// the dynamic category colors carry the visual interest. (Will graduate into a
/// dedicated DesignSystem module later.)
enum Theme {
    static let bg = Color.black
    static let surface = Color(white: 0.11)
    static let surfaceElevated = Color(white: 0.16)
    static let hairline = Color.white.opacity(0.10)
    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.55)
    static let now = Color(red: 1.0, green: 0.45, blue: 0.45)

    static let corner: CGFloat = 14
    static let rowSpacing: CGFloat = 12
    static let hPadding: CGFloat = 20
    static let timeColumnWidth: CGFloat = 64
}

extension Color {
    /// Parses a "#RRGGBB" hex string.
    init?(hex: String?) {
        guard let hex, hex.hasPrefix("#"), hex.count == 7,
              let v = Int(hex.dropFirst(), radix: 16) else { return nil }
        self = Color(
            red: Double((v >> 16) & 0xFF) / 255,
            green: Double((v >> 8) & 0xFF) / 255,
            blue: Double(v & 0xFF) / 255
        )
    }

    static func category(_ hex: String?) -> Color { Color(hex: hex) ?? .gray }
}
