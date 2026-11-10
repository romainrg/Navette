import AppKit
import NavetteCore
import SwiftUI
import UniformTypeIdentifiers

/// The family's visual theme (shared with Mopster): soft color glows behind translucent panels, one gradient per
/// protocol and per kind of file, and a warm call-to-action. Every color adapts to dark mode.
enum Theme {
    // MARK: Ground and panels

    static let base = Color.dynamic(light: Color(hex: 0xF3F4FA), dark: Color(hex: 0x070A1F))
    static let glowIndigo = Color.dynamic(light: Color(hex: 0xD9E0FF), dark: Color(hex: 0x6366F1).opacity(0.5))
    static let glowPink = Color.dynamic(light: Color(hex: 0xFFE0EC), dark: Color(hex: 0xEC4899).opacity(0.3))
    static let glowTeal = Color.dynamic(light: Color(hex: 0xCFF6EC), dark: Color(hex: 0x14B8A6).opacity(0.38))

    static let panelFill = Color.dynamic(light: .white.opacity(0.66), dark: .white.opacity(0.05))
    static let panelStroke = Color.dynamic(light: .white.opacity(0.9), dark: .white.opacity(0.1))
    static let panelShadow = Color.dynamic(light: Color(hex: 0x1F2955).opacity(0.08), dark: .black.opacity(0.35))
    static let panelRadius: CGFloat = 18

    static let cardFill = Color.dynamic(light: .white.opacity(0.85), dark: .white.opacity(0.06))
    static let cardStroke = Color.dynamic(light: Color(hex: 0x1B1F2A).opacity(0.08), dark: .white.opacity(0.1))
    static let cardShadow = Color.dynamic(light: Color(hex: 0x1F2937).opacity(0.05), dark: .black.opacity(0.3))
    static let cardRadius: CGFloat = 14

    static let softFill = Color.dynamic(light: .white.opacity(0.9), dark: .white.opacity(0.07))
    static let softStroke = Color.dynamic(light: Color(hex: 0x1B1F2A).opacity(0.12), dark: .white.opacity(0.14))
    static let divider = Color.dynamic(light: Color(hex: 0x1B1F2A).opacity(0.08), dark: .white.opacity(0.08))
    static let track = Color.dynamic(light: Color(hex: 0x1B1F2A).opacity(0.08), dark: .white.opacity(0.1))

    // MARK: Gradients

    /// Primary action: orange → pink, the one gradient no protocol uses.
    static let action = LinearGradient(
        colors: [Color(hex: 0xFFA24C), Color(hex: 0xFF5FA2)], startPoint: .topLeading, endPoint: .bottomTrailing)
    /// Text on `action`. White on orange is not readable.
    static let actionInk = Color(hex: 0x1A1240)
    /// Deleting on a server.
    static let danger = LinearGradient(
        colors: [Color(hex: 0xE11D48), Color(hex: 0xBE123C)], startPoint: .topLeading, endPoint: .bottomTrailing)
    /// Selected rows and toggles that are on, with white content.
    static let selection = LinearGradient(
        colors: [Color(hex: 0x4F46E5), Color(hex: 0x0E7490)], startPoint: .leading, endPoint: .trailing)
    /// Large titles.
    static let title = LinearGradient(
        colors: [
            .dynamic(light: Color(hex: 0x14183A), dark: .white),
            .dynamic(light: Color(hex: 0x4338CA), dark: Color(hex: 0xC7D2FE)),
            .dynamic(light: Color(hex: 0x0F766E), dark: Color(hex: 0x5EEAD4)),
        ],
        startPoint: .leading, endPoint: .trailing)
    /// The card at the top of the inspector, with white text.
    static let hero = LinearGradient(
        colors: [Color(hex: 0x0E7490), Color(hex: 0x4338CA)], startPoint: .topLeading, endPoint: .bottomTrailing)
    /// Overall progress.
    static let progress = AngularGradient(
        colors: [Color(hex: 0x2DD4BF), Color(hex: 0x818CF8), Color(hex: 0xF472B6), Color(hex: 0x2DD4BF)], center: .center)

    static let download = Tint(0x2DD4BF, 0x6366F1)
    static let upload = Tint(0xFFA24C, 0xFF5FA2)
    static let idle = Tint(0x94A3B8, 0x475569)
    static let failure = Tint(0xFB7185, 0xE11D48)
    static let success = Tint(0x34D399, 0x059669)
}

/// A pair of colors drawn as a gradient: protocols, kinds of file, transfer states.
struct Tint: Hashable {
    let start: Color
    let end: Color

    init(_ start: UInt32, _ end: UInt32) {
        self.start = Color(hex: start)
        self.end = Color(hex: end)
    }

    var gradient: LinearGradient {
        LinearGradient(colors: [start, end], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var horizontal: LinearGradient {
        LinearGradient(colors: [start, end], startPoint: .leading, endPoint: .trailing)
    }

    /// A light wash of the tint, behind the active row of a list.
    var wash: LinearGradient {
        LinearGradient(colors: [start.opacity(0.26), end.opacity(0.22)], startPoint: .leading, endPoint: .trailing)
    }
}

// MARK: - Protocols

extension ServerProtocol {
    var tint: Tint {
        switch self {
        case .sftp: Tint(0x14B8A6, 0x6366F1)
        case .ftp: Tint(0xFBBF24, 0xF97316)
        case .ftps: Tint(0xFB7185, 0xE11D48)
        case .webdav: Tint(0x38BDF8, 0x0284C7)
        case .webdavs: Tint(0xA78BFA, 0x7C3AED)
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

// MARK: - Kinds of file

/// The family a file belongs to, for its tile in lists.
enum FileKind: Hashable {
    case folder, link, web, code, archive, image, pdf, media, data, document

    private static let webExtensions: Set<String> = ["html", "htm", "xhtml", "css", "scss", "js", "mjs", "ts", "jsx", "tsx", "vue", "php"]
    private static let dataExtensions: Set<String> = ["sql", "sqlite", "sqlite3", "db", "csv"]
    private static let archiveExtensions: Set<String> = ["zip", "gz", "tgz", "tar", "bz2", "xz", "zst", "7z", "rar", "dmg"]

    init(_ item: RemoteItem) {
        switch item.kind {
        case .directory: self = .folder
        case .symlink: self = .link
        case .other: self = .document
        case .file: self = FileKind(extension: (item.name as NSString).pathExtension.lowercased())
        }
    }

    init(extension ext: String) {
        if Self.webExtensions.contains(ext) {
            self = .web
        } else if Self.dataExtensions.contains(ext) {
            self = .data
        } else if Self.archiveExtensions.contains(ext) {
            self = .archive
        } else if let type = UTType(filenameExtension: ext) {
            if type.conforms(to: .pdf) {
                self = .pdf
            } else if type.conforms(to: .image) {
                self = .image
            } else if type.conforms(to: .archive) || type.conforms(to: .diskImage) {
                self = .archive
            } else if type.conforms(to: .audiovisualContent) {
                self = .media
            } else if type.conforms(to: .sourceCode) || type.conforms(to: .script) {
                self = .code
            } else {
                self = .document
            }
        } else {
            self = .document
        }
    }

    var tint: Tint {
        switch self {
        case .folder: Tint(0x38BDF8, 0x6366F1)
        case .link: Tint(0x22D3EE, 0x0284C7)
        case .web: Tint(0xFB923C, 0xEC4899)
        case .code: Tint(0x2DD4BF, 0x0EA5E9)
        case .archive: Tint(0xA78BFA, 0x7C3AED)
        case .image: Tint(0x34D399, 0x059669)
        case .pdf: Tint(0xFB7185, 0xE11D48)
        case .media: Tint(0xF472B6, 0xA855F7)
        case .data: Tint(0xFBBF24, 0xF97316)
        case .document: Tint(0x94A3B8, 0x64748B)
        }
    }

    var symbol: String {
        switch self {
        case .folder: "folder.fill"
        case .link: "arrow.up.right"
        case .web: "globe"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .archive: "archivebox.fill"
        case .image: "photo.fill"
        case .pdf: "doc.richtext.fill"
        case .media: "play.fill"
        case .data: "cylinder.fill"
        case .document: "doc.text.fill"
        }
    }
}

// MARK: - Tiles

/// A rounded gradient square holding a white SF Symbol.
struct GradientTile: View {
    let tint: Tint
    let symbol: String
    var size: CGFloat = 22
    var glows = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.48, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: size * 0.32, style: .continuous))
            .shadow(color: glows ? tint.end.opacity(0.45) : .clear, radius: size * 0.3, y: size * 0.12)
            .accessibilityHidden(true)
    }
}

struct ProtocolIcon: View {
    let proto: ServerProtocol
    var size: CGFloat = 22
    var glows = false

    var body: some View {
        GradientTile(tint: proto.tint, symbol: proto.symbol, size: size, glows: glows)
    }
}

struct FileKindIcon: View {
    let item: RemoteItem
    var size: CGFloat = 22

    var body: some View {
        let kind = FileKind(item)
        GradientTile(tint: kind.tint, symbol: kind.symbol, size: size)
    }
}

// MARK: - Ground, panels and cards

/// The window ground: three soft glows over a tinted base.
struct ThemeGround: View {
    var body: some View {
        GeometryReader { proxy in
            let reach = max(proxy.size.width, proxy.size.height)
            ZStack {
                Theme.base
                glow(Theme.glowIndigo, at: UnitPoint(x: 0.04, y: -0.04), radius: reach * 0.62)
                glow(Theme.glowPink, at: UnitPoint(x: 1, y: 0.04), radius: reach * 0.5)
                glow(Theme.glowTeal, at: UnitPoint(x: 0.62, y: 1.1), radius: reach * 0.65)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private func glow(_ color: Color, at center: UnitPoint, radius: CGFloat) -> RadialGradient {
        RadialGradient(colors: [color, color.opacity(0)], center: center, startRadius: 0, endRadius: max(radius, 1))
    }
}

/// A translucent panel laid on the ground.
struct GlassPanel: ViewModifier {
    var radius: CGFloat = Theme.panelRadius

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .clipShape(shape)
            .background(shape.fill(Theme.panelFill).shadow(color: Theme.panelShadow, radius: 24, y: 12))
            .overlay(shape.strokeBorder(Theme.panelStroke))
    }
}

/// A card inside a panel or a sheet.
struct ThemeCard: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
        content
            .clipShape(shape)
            .background(shape.fill(Theme.cardFill).shadow(color: Theme.cardShadow, radius: 10, y: 4))
            .overlay(shape.strokeBorder(Theme.cardStroke))
    }
}

extension View {
    func glassPanel(radius: CGFloat = Theme.panelRadius) -> some View { modifier(GlassPanel(radius: radius)) }
    func themeCard() -> some View { modifier(ThemeCard()) }
}

/// Icon buttons grouped in one capsule.
struct ToolbarGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
        HStack(spacing: 0) { content }
            .padding(3)
            .background(Theme.softFill, in: shape)
            .overlay(shape.strokeBorder(Theme.softStroke))
    }
}

// MARK: - Progress

/// Progress as a ring drawn with the progress gradient.
struct ProgressRing: View {
    let fraction: Double
    var lineWidth: CGFloat = 6

    var body: some View {
        ZStack {
            Circle().stroke(Theme.track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(1, max(0.001, fraction)))
                .stroke(Theme.progress, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(lineWidth / 2)
        .accessibilityHidden(true)
    }
}

/// A thin progress bar filled with a gradient, glowing while it moves.
struct GradientBar: View {
    let fraction: Double
    let tint: Tint
    var glows = false

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule()
                    .fill(tint.horizontal)
                    .frame(width: max(6, proxy.size.width * min(1, max(0, fraction))))
                    .shadow(color: glows ? tint.end.opacity(0.6) : .clear, radius: 5)
            }
        }
        .frame(height: 6)
        .accessibilityElement()
        .accessibilityValue(Text(fraction, format: .percent.precision(.fractionLength(0))))
    }
}

// MARK: - Buttons

/// Filled gradient button for the one primary action of a screen. `.controlSize(.small)` makes it compact.
struct GradientButtonStyle: ButtonStyle {
    var fill: LinearGradient = Theme.action
    var shadow: Color = Color(hex: 0xFF5FA2)
    var ink: Color = Theme.actionInk

    func makeBody(configuration: Configuration) -> some View {
        GradientButton(configuration: configuration, fill: fill, shadow: shadow, ink: ink)
    }
}

private struct GradientButton: View {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    let configuration: ButtonStyleConfiguration
    let fill: LinearGradient
    let shadow: Color
    let ink: Color

    var body: some View {
        let compact = controlSize == .small || controlSize == .mini
        let shape = RoundedRectangle(cornerRadius: compact ? 9 : 11, style: .continuous)
        configuration.label
            .font(.system(size: compact ? 12 : 13, weight: .semibold))
            .foregroundStyle(ink)
            .lineLimit(1)
            .padding(.horizontal, compact ? 12 : 16)
            .frame(height: compact ? 28 : 34)
            .background(fill, in: shape)
            .saturation(isEnabled ? 1 : 0.35)
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.5)
            .shadow(color: shadow.opacity(isEnabled ? 0.32 : 0), radius: 10, y: 5)
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
        let shape = RoundedRectangle(cornerRadius: compact ? 9 : 11, style: .continuous)
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

/// Icon-only toolbar button. `isOn` fills it with the selection gradient, for toggles such as the inspector.
struct ToolbarIconButtonStyle: ButtonStyle {
    var isOn = false

    func makeBody(configuration: Configuration) -> some View {
        ToolbarIconButton(configuration: configuration, isOn: isOn)
    }
}

private struct ToolbarIconButton: View {
    @Environment(\.isEnabled) private var isEnabled
    let configuration: ButtonStyleConfiguration
    let isOn: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(isOn ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
            .frame(width: 32, height: 28)
            .background {
                if isOn {
                    shape.fill(Theme.selection)
                } else if configuration.isPressed {
                    shape.fill(Theme.softStroke)
                }
            }
            .opacity(isEnabled ? 1 : 0.35)
            .contentShape(shape)
    }
}

/// A permission bit: a gradient square with a check when it is on, a dashed outline when it is off.
struct PermissionToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        Button { configuration.isOn.toggle() } label: {
            ZStack {
                if configuration.isOn {
                    shape.fill(Theme.selection)
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                } else {
                    shape.fill(Theme.softFill)
                    shape.strokeBorder(Theme.softStroke, style: StrokeStyle(lineWidth: 1.2, dash: [3, 2]))
                }
            }
            .frame(width: 40, height: 26)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}

extension ButtonStyle where Self == GradientButtonStyle {
    static var gradient: GradientButtonStyle { GradientButtonStyle() }
}

extension ButtonStyle where Self == SoftButtonStyle {
    static var soft: SoftButtonStyle { SoftButtonStyle() }
}

extension ButtonStyle where Self == ToolbarIconButtonStyle {
    static var toolbarIcon: ToolbarIconButtonStyle { ToolbarIconButtonStyle() }
    static func toolbarIcon(isOn: Bool) -> ToolbarIconButtonStyle { ToolbarIconButtonStyle(isOn: isOn) }
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
