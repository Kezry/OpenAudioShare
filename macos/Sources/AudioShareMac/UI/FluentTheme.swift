import SwiftUI

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

struct FluentTheme {
    let colorScheme: ColorScheme

    var isDark: Bool { colorScheme == .dark }

    var accent: Color { isDark ? Color(hex: 0x60CDFF) : Color(hex: 0x0078D4) }
    var accentPressed: Color { isDark ? Color(hex: 0x4FB8E8) : Color(hex: 0x0067B8) }
    var success: Color { isDark ? Color(hex: 0x6CCB5F) : Color(hex: 0x0F7B0F) }
    var caution: Color { isDark ? Color(hex: 0xFFB900) : Color(hex: 0xF7630C) }
    var danger: Color { isDark ? Color(hex: 0xFF99A4) : Color(hex: 0xC42B1C) }
    var info: Color { accent }

    var textPrimary: Color {
        isDark ? Color.white.opacity(0.94) : Color(hex: 0x1A1A1A)
    }
    var textSecondary: Color {
        isDark ? Color.white.opacity(0.62) : Color(hex: 0x5C5C5C)
    }
    var textDisabled: Color {
        isDark ? Color.white.opacity(0.32) : Color(hex: 0x9A9A9A)
    }
    var fieldBackground: Color {
        isDark ? Color.white.opacity(0.065) : Color.white.opacity(0.72)
    }
    var fieldBorder: Color {
        isDark ? Color.white.opacity(0.09) : Color.black.opacity(0.10)
    }
    var fieldHoverBorder: Color {
        isDark ? Color.white.opacity(0.20) : Color.black.opacity(0.20)
    }
    var toggleOff: Color {
        isDark ? Color.white.opacity(0.26) : Color.black.opacity(0.28)
    }
    var listBackground: Color {
        isDark ? Color.white.opacity(0.03) : Color.white.opacity(0.32)
    }
    var titlebar: Color {
        isDark ? Color.white.opacity(0.035) : Color.white.opacity(0.42)
    }

    var windowGradient: LinearGradient {
        if isDark {
            return LinearGradient(colors: [Color(hex: 0x202226), Color(hex: 0x17181B)],
                                  startPoint: .top, endPoint: .bottom)
        }
        return LinearGradient(colors: [Color(hex: 0xF7F8FA), Color(hex: 0xEBEDF0)],
                              startPoint: .top, endPoint: .bottom)
    }

    var buttonDisabled: Color {
        isDark ? Color.white.opacity(0.10) : Color.black.opacity(0.10)
    }
}
