import AppKit
import NavetteCore
import SwiftUI

/// The family's visual theme (shared with Mopster): a soft polychrome ground, gradient tints and a warm
/// call-to-action. Navette gives one tint to each protocol. Every color adapts to dark mode.
enum Theme {
    /// Window ground: lavender → mint → peach in light mode, night → deep teal → plum in dark mode.
    static let ground = LinearGradient(
        colors: [
            .dynamic(light: Color(hex: 0xEEF2FF), dark: Color(hex: 0x10152A)),
            .dynamic(light: Color(hex: 0xF2FBF9), dark: Color(hex: 0x0C1D21)),
            .dynamic(light: Color(hex: 0xFFF4EC), dark: Color(hex: 0x1D1519)),
        ],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    /// Primary action: orange → pink, the one gradient no protocol uses.
    static let action = LinearGradient(
        colors: [Color(hex: 0xF97316), Color(hex: 0xEC4899)], startPoint: .topLeading, endPoint: .bottomTrailing)

    static let cardFill = Color.dynamic(light: .white.opacity(0.78), dark: .white.opacity(0.06))
    static let cardStroke = Color.dynamic(light: .white.opacity(0.9), dark: .white.opacity(0.1))
    static let cardShadow = Color.dynamic(light: Color(hex: 0x1F2937).opacity(0.06), dark: .black.opacity(0.3))
    static let cardRadius: CGFloat = 14

    static let softFill = Color.dynamic(light: .white.opacity(0.8), dark: .white.opacity(0.08))
    static let softStroke = Color.dynamic(light: Color(hex: 0x1B1F2A).opacity(0.14), dark: .white.opacity(0.16))
    static let barFill = Color.dynamic(light: .white.opacity(0.55), dark: .white.opacity(0.04))
    static let divider = Color.dynamic(light: Color(hex: 0x1B1F2A).opacity(0.1), dark: .white.opacity(0.1))
}

/// One gradient per protocol, used on tabs, bookmarks and the connection sheet.
struct ProtocolTint: Hashable {
    let start: Color
    let end: Color

    var gradient: LinearGradient {
        LinearGradient(colors: [start, end], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

extension ServerProtocol {
    var tint: ProtocolTint {
        switch self {
        case .sftp: ProtocolTint(start: Color(hex: 0x14B8A6), end: Color(hex: 0x6366F1))
        case .ftp: ProtocolTint(start: Color(hex: 0xFBBF24), end: Color(hex: 0xF97316))
        case .ftps: ProtocolTint(start: Color(hex: 0xFB7185), end: Color(hex: 0xE11D48))
        case .webdav: ProtocolTint(start: Color(hex: 0x38BDF8), end: Color(hex: 0x0284C7))
        case .webdavs: ProtocolTint(start: Color(hex: 0xA78BFA), end: Color(hex: 0x7C3AED))
        }
    }

    var symbol: String {
        switch self {
        case .sftp: "terminal.fill"
        case .ftp: "arrow.left.arrow.right"
        case .ftps: "lock.fill"
        case .webdav: "globe"
        case .webdavs: "lock.icloud.fill"
        }
    }

    var displayName: String {
        switch self {
        case .sftp: "SFTP"
        case .ftp: "FTP"
        case .ftps: "FTPS"
        case .webdav: "WebDAV (HTTP)"
        case .webdavs: "WebDAV (HTTPS)"
        }
    }
}

extension BookmarkColor {
    var color: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .blue: .blue
        case .purple: .purple
        case .gray: .gray
        }
    }
}

/// A rounded gradient square holding a white SF Symbol.
struct ProtocolIcon: View {
    let proto: ServerProtocol
    var size: CGFloat = 22

    var body: some View {
        Image(systemName: proto.symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(proto.tint.gradient, in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Translucent card with a soft shadow.
struct ThemeCard: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
        content
            .clipShape(shape)
            .background(shape.fill(Theme.cardFill).shadow(color: Theme.cardShadow, radius: 12, y: 6))
            .overlay(shape.strokeBorder(Theme.cardStroke))
    }
}

extension View {
    func themeCard() -> some View { modifier(ThemeCard()) }
}

// MARK: - Buttons

/// Filled gradient button for the one primary action of a screen. `.controlSize(.small)` makes it compact.
struct GradientButtonStyle: ButtonStyle {
    var fill: LinearGradient = Theme.action
    var shadow: Color = Color(hex: 0xEC4899)

    func makeBody(configuration: Configuration) -> some View {
        GradientButton(configuration: configuration, fill: fill, shadow: shadow)
    }
}

private struct GradientButton: View {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    let configuration: ButtonStyleConfiguration
    let fill: LinearGradient
    let shadow: Color

    var body: some View {
        let compact = controlSize == .small || controlSize == .mini
        let shape = RoundedRectangle(cornerRadius: compact ? 9 : 10, style: .continuous)
        configuration.label
            .font(.system(size: compact ? 12 : 13, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, compact ? 12 : 16)
            .frame(height: compact ? 28 : 34)
            .background(fill, in: shape)
            .saturation(isEnabled ? 1 : 0.35)
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.5)
            .shadow(color: shadow.opacity(isEnabled ? 0.28 : 0), radius: 8, y: 4)
            .contentShape(shape)
    }
}

/// Secondary button: translucent, bordered. `.controlSize(.small)` makes it compact.
struct SoftButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SoftButton(configuration: configuration)
    }
}

private struct SoftButton: View {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    let configuration: ButtonStyleConfiguration

    var body: some View {
        let compact = controlSize == .small || controlSize == .mini
        let shape = RoundedRectangle(cornerRadius: compact ? 9 : 10, style: .continuous)
        configuration.label
            .font(.system(size: compact ? 12 : 13, weight: .semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .padding(.horizontal, compact ? 10 : 16)
            .frame(height: compact ? 28 : 34)
            .background(Theme.softFill, in: shape)
            .overlay(shape.strokeBorder(Theme.softStroke))
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
            .contentShape(shape)
    }
}

/// Icon-only toolbar button.
struct ToolbarIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ToolbarIconButton(configuration: configuration)
    }
}

private struct ToolbarIconButton: View {
    @Environment(\.isEnabled) private var isEnabled
    let configuration: ButtonStyleConfiguration

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .frame(width: 30, height: 26)
            .background(configuration.isPressed ? Theme.softStroke : Color.clear, in: shape)
            .opacity(isEnabled ? 1 : 0.35)
            .contentShape(shape)
    }
}

extension ButtonStyle where Self == GradientButtonStyle {
    static var gradient: GradientButtonStyle { GradientButtonStyle() }
    static func gradient(_ tint: ProtocolTint) -> GradientButtonStyle {
        GradientButtonStyle(fill: tint.gradient, shadow: tint.end)
    }
}

extension ButtonStyle where Self == SoftButtonStyle {
    static var soft: SoftButtonStyle { SoftButtonStyle() }
}

extension ButtonStyle where Self == ToolbarIconButtonStyle {
    static var toolbarIcon: ToolbarIconButtonStyle { ToolbarIconButtonStyle() }
}

// MARK: - Colors

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255)
    }

    /// A color that follows the window's appearance.
    static func dynamic(light: Color, dark: Color) -> Color {
        let light = NSColor(light)
        let dark = NSColor(dark)
        return Color(
            nsColor: NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            })
    }
}
