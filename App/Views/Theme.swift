import SwiftUI
import UIKit

enum Theme {
    static let accent = Color(hex: 0x8B5CF6)
    static let accentDeep = Color(hex: 0x6D28D9)
    static let accentSoft = Color(hex: 0xA78BFA)
    static let success = Color(hex: 0x34D399)
    static let warning = Color(hex: 0xFBBF24)
    static let danger = Color(hex: 0xF87171)
    static let sky = Color(hex: 0x38BDF8)
    static let telegram = Color(hex: 0x229ED9)

    static let background = Color(light: Color(hex: 0xF5F4FA), dark: Color(hex: 0x0A0911))
    static let card = Color(light: .white, dark: Color(hex: 0x16141F))
    static let cardStroke = Color(light: Color.black.opacity(0.06), dark: Color.white.opacity(0.07))

    static let gradient = LinearGradient(colors: [accentSoft, accent, accentDeep], startPoint: .topLeading, endPoint: .bottomTrailing)
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }

    init(light: Color, dark: Color) {
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
    }
}

extension RouteGroup {
    var color: Color {
        switch self {
        case .regular: return Theme.accentSoft
        case .bridge: return Theme.warning
        case .bypass: return Theme.sky
        }
    }
}

extension NetworkMode {
    var color: Color {
        switch self {
        case .unknown: return .gray
        case .normal: return Theme.success
        case .whitelist: return Theme.warning
        case .offline: return Theme.danger
        }
    }
}

// MARK: - Modifiers & styles

struct CardStyle: ViewModifier {
    var padding: CGFloat
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Theme.cardStroke))
    }
}

extension View {
    func card(padding: CGFloat = 16) -> some View { modifier(CardStyle(padding: padding)) }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Theme.gradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: Theme.accent.opacity(0.35), radius: 14, y: 6)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.cardStroke))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: - Components

struct AppBackground: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        ZStack {
            Theme.background
            RadialGradient(colors: [Theme.accent.opacity(scheme == .dark ? 0.30 : 0.16), .clear],
                           center: .top, startRadius: 0, endRadius: 460)
        }
        .ignoresSafeArea()
    }
}

struct KeyholeShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let w = r.width, h = r.height
        let cx = r.midX
        let radius = w * 0.30
        let cy = r.minY + h * 0.30
        p.addEllipse(in: CGRect(x: cx - radius, y: cy - radius, width: radius * 2, height: radius * 2))
        p.move(to: CGPoint(x: cx - w * 0.15, y: cy + radius * 0.3))
        p.addLine(to: CGPoint(x: cx + w * 0.15, y: cy + radius * 0.3))
        p.addLine(to: CGPoint(x: cx + w * 0.27, y: r.maxY))
        p.addLine(to: CGPoint(x: cx - w * 0.27, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

struct LogoMark: View {
    var size: CGFloat
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(Theme.gradient)
            KeyholeShape()
                .fill(.white)
                .frame(width: size * 0.36, height: size * 0.5)
                .shadow(color: .black.opacity(0.25), radius: size * 0.04, y: size * 0.02)
        }
        .frame(width: size, height: size)
        .shadow(color: Theme.accent.opacity(0.4), radius: size * 0.2, y: size * 0.08)
    }
}

struct FlagBadge: View {
    let code: String
    var size: CGFloat = 40
    var body: some View {
        Text(code.flagEmoji)
            .font(.system(size: size * 0.6))
            .frame(width: size, height: size)
            .background(Circle().fill(Theme.accent.opacity(0.12)))
    }
}

struct PingLabel: View {
    let ms: Int?
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(ms.map { "\($0) мс" } ?? "—")
                .font(.caption.monospacedDigit().weight(.medium))
                .foregroundStyle(.secondary)
        }
    }
    private var color: Color {
        guard let ms else { return .gray }
        if ms < 80 { return Theme.success }
        if ms < 160 { return Theme.warning }
        return Theme.danger
    }
}

struct GroupTag: View {
    let group: RouteGroup
    var body: some View {
        Text(group.shortTitle)
            .font(.caption2.weight(.bold))
            .foregroundStyle(group.color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(group.color.opacity(0.15), in: Capsule())
    }
}

struct SelectionMark: View {
    let selected: Bool
    var body: some View {
        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
            .font(.title3)
            .foregroundStyle(selected ? Theme.accent : Color.secondary.opacity(0.35))
    }
}

struct NetworkPill: View {
    let mode: NetworkMode
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(mode.color).frame(width: 7, height: 7)
            Text(mode.short)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(Theme.card, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.cardStroke))
    }
}

struct IconTile: View {
    let systemName: String
    let color: Color
    var size: CGFloat = 40
    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
    }
}

struct SettingsLabel: View {
    let title: String
    let icon: String
    let color: Color
    init(_ title: String, icon: String, color: Color) {
        self.title = title
        self.icon = icon
        self.color = color
    }
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 29, height: 29)
                .background(color.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(title).foregroundStyle(.primary)
        }
    }
}
