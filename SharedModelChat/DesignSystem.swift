import SwiftUI

// MARK: - Color Palette
// A warm, muted palette inspired by stone, linen, and ink.

extension Color {
    enum Chat {
        // Backgrounds
        static let canvas      = Color(hex: "F5F1EB")   // warm off-white
        static let surface     = Color(hex: "EDEAE4")   // slightly darker surface
        static let card        = Color(hex: "FFFFFF")    // white cards (user bubbles)
        
        // Bubble colors
        static let userBubble  = Color(hex: "3C3A36")   // warm charcoal
        static let aiBubble    = Color(hex: "E8E4DD")   // warm light grey
        
        // Text
        static let textPrimary   = Color(hex: "2C2A26")
        static let textSecondary = Color(hex: "8A857D")
        static let textOnDark    = Color(hex: "F5F1EB")
        static let textOnLight   = Color(hex: "3C3A36")
        
        // Accents
        static let accent      = Color(hex: "9B8B7A")   // warm taupe accent
        static let accentSoft  = Color(hex: "C4B8A9")   // lighter taupe
        static let border      = Color(hex: "DDD8D0")
        
        // Status
        static let success     = Color(hex: "7A9B7E")   // muted sage
        static let warning     = Color(hex: "C4A265")   // muted gold
        static let error       = Color(hex: "B07A7A")   // muted rose
    }
}

// MARK: - Hex Color Init

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: .alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: Double
        switch hex.count {
        case 6:
            r = Double((int >> 16) & 0xFF) / 255
            g = Double((int >> 8) & 0xFF) / 255
            b = Double(int & 0xFF) / 255
        default:
            r = 1; g = 1; b = 1
        }
        self.init(red: r, green: g, blue: b)
    }
}

// MARK: - Typography

extension Font {
    enum Chat {
        static let title       = Font.system(size: 18, weight: .semibold, design: .rounded)
        static let heading     = Font.system(size: 15, weight: .medium, design: .rounded)
        static let body        = Font.system(size: 15, weight: .regular, design: .default)
        static let caption     = Font.system(size: 12, weight: .regular, design: .default)
        static let inputField  = Font.system(size: 16, weight: .regular, design: .default)
        static let modelLabel  = Font.system(size: 11, weight: .medium, design: .monospaced)
    }
}

// MARK: - Shared Styles

struct MutedButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.Chat.accent.opacity(configuration.isPressed ? 0.25 : 0.15))
            .foregroundStyle(Color.Chat.accent)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Color.Chat.userBubble.opacity(configuration.isPressed ? 0.8 : 1))
            .foregroundStyle(Color.Chat.textOnDark)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
