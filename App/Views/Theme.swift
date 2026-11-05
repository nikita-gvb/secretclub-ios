import SwiftUI
import UIKit

// SecretClub 0.6 — дизайн-система «Кнопка + сводка».
// Акцент «Янтарь» (Display P3), светлая и тёмная темы, системный шрифт SF.
// Цвет = состояние: янтарь — VPN работает, красный — только ошибки, зелёный — «проверено».

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }

    /// Цвет, который сам меняется вместе с темой.
    init(light: UIColor, dark: UIColor) {
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }

    init(light: UInt32, dark: UInt32) {
        self.init(light: UIColor(hex: light), dark: UIColor(hex: dark))
    }
}

enum Theme {
    // MARK: Акцент «Янтарь»
    static let amberP3 = UIColor(displayP3Red: 0.980, green: 0.708, blue: 0.105, alpha: 1)
    /// Основной акцент: кнопка «включено», главные кнопки, переключатели.
    static let tint = Color(uiColor: amberP3)
    /// Низ объёмной кнопки и тени свечения.
    static let tintDeep = Color(hex: 0xEA9B12)
    /// Блик сверху на янтарной кнопке.
    static let tintLight = Color(uiColor: UIColor(displayP3Red: 0.991, green: 0.839, blue: 0.508, alpha: 1))
    /// Текст и иконки на янтаре. Белый на янтаре не используем.
    static let onTint = Color(hex: 0x1F1400)
    /// Иконки, ссылки и активная вкладка: в светлой теме темнее, чтобы читались на белом.
    static let ink = Color(light: UIColor(hex: 0xBD7D11), dark: amberP3)
    static let tintSoft = Color(light: UIColor(hex: 0xFFB41B, alpha: 0.17), dark: UIColor(hex: 0xFFB41B, alpha: 0.17))

    // MARK: Статусы
    static let green = Color(light: 0x34C759, dark: 0x30D158)
    static let red = Color(light: 0xFF3B30, dark: 0xFF453A)
    static let orange = Color(light: 0xFF9500, dark: 0xFF9F0A)
    static let gray = Color(hex: 0x8E8E93)
    static let blue = Color(light: 0x007AFF, dark: 0x0A84FF)
    static let telegram = Color(hex: 0x2AABEE)

    // MARK: Поверхности
    static let background = Color(light: 0xF2F2F7, dark: 0x000000)
    static let cell = Color(light: 0xFFFFFF, dark: 0x1C1C1E)
    static let cell2 = Color(light: 0xF2F2F7, dark: 0x2C2C2E)
    static let cellPress = Color(light: 0xE5E5EA, dark: 0x3A3A3C)
    static let fill = Color(light: UIColor(hex: 0x767680, alpha: 0.12), dark: UIColor(hex: 0x767680, alpha: 0.24))
    static let fill2 = Color(light: UIColor(hex: 0x767680, alpha: 0.2), dark: UIColor(hex: 0x767680, alpha: 0.34))
    static let fill3 = fill
    static let separator = Color(light: UIColor(hex: 0x3C3C43, alpha: 0.15), dark: UIColor(hex: 0x545458, alpha: 0.5))
    static let border = Color(light: UIColor(white: 0, alpha: 0.06), dark: UIColor(white: 1, alpha: 0.07))

    // MARK: Текст
    static let label = Color(light: 0x000000, dark: 0xFFFFFF)
    static let label2 = Color(light: UIColor(hex: 0x3C3C43, alpha: 0.62), dark: UIColor(hex: 0xEBEBF5, alpha: 0.6))
    static let label3 = Color(light: UIColor(hex: 0x3C3C43, alpha: 0.3), dark: UIColor(hex: 0xEBEBF5, alpha: 0.28))

    // MARK: Главная
    static let launchTop = Color(light: 0xE8EBF1, dark: 0x101114)
    static let launchMid = Color(light: 0xEFF0F4, dark: 0x07080A)
    static let launchBottom = Color(light: 0xF4F4F7, dark: 0x000000)
    static let sphereTop = Color(light: 0xFFFFFF, dark: 0x3C3C41)
    static let sphereMid = Color(light: 0xF6F6F9, dark: 0x28282C)
    static let sphereBottom = Color(light: 0xE8E8ED, dark: 0x1A1A1D)
    static let sphereShadow = Color(light: UIColor(red: 40 / 255, green: 40 / 255, blue: 70 / 255, alpha: 0.28), dark: UIColor(white: 0, alpha: 0.9))
    static let sphereHighlight = Color(light: UIColor(white: 1, alpha: 1), dark: UIColor(white: 1, alpha: 0.13))
    static let iconOff = Color(light: 0xA1A1A8, dark: 0x7C7C84)

    static let tintGradient = LinearGradient(colors: [tint, tint], startPoint: .top, endPoint: .bottom)

    // MARK: Скругления
    static let rGroup: CGFloat = 26
    static let rTile: CGFloat = 24
    static let rCard: CGFloat = 30
    static let rCell: CGFloat = 22
}

// MARK: - Типографика (SF Pro / SF Pro Rounded)

extension Font.TextStyle {
    var uiStyle: UIFont.TextStyle {
        switch self {
        case .largeTitle: return .largeTitle
        case .title: return .title1
        case .title2: return .title2
        case .title3: return .title3
        case .headline: return .headline
        case .subheadline: return .subheadline
        case .callout: return .callout
        case .footnote: return .footnote
        case .caption: return .caption1
        case .caption2: return .caption2
        default: return .body
        }
    }
}

extension Font {
    /// Системный шрифт нужного размера, который растёт вместе с Dynamic Type.
    static func sc(_ size: CGFloat, _ weight: Font.Weight = .regular, design: Font.Design = .default, relativeTo style: Font.TextStyle = .body) -> Font {
        let scaled = UIFontMetrics(forTextStyle: style.uiStyle).scaledValue(for: size)
        return .system(size: scaled, weight: weight, design: design)
    }

    /// Цифры: SF Rounded.
    static func scNumber(_ size: CGFloat, _ weight: Font.Weight = .bold, relativeTo style: Font.TextStyle = .title) -> Font {
        sc(size, weight, design: .rounded, relativeTo: style)
    }

    static var scLarge: Font { .largeTitle.bold() }
    static var scTitle1: Font { .title.bold() }
    static var scTitle2: Font { .title2.bold() }
    static var scTitle3: Font { .title3.weight(.semibold) }
    static var scHeadline: Font { .headline }
    static var scBody: Font { .body }
    static var scSub: Font { .subheadline }
    static var scFoot: Font { .footnote }
    static var scCaption: Font { .caption.weight(.medium) }
}

// MARK: - Тема приложения

@MainActor
enum AppearanceController {
    private static var windows: [UIWindow] {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
    }

    static func apply(_ appearance: AppAppearance) {
        for window in windows where window.overrideUserInterfaceStyle != appearance.style {
            window.overrideUserInterfaceStyle = appearance.style
        }
    }

    /// Плавное перетекание всего экрана при смене темы (0,35 с).
    static func crossfade(_ change: () -> Void) {
        guard let window = windows.first(where: \.isKeyWindow) ?? windows.first,
              let snapshot = window.snapshotView(afterScreenUpdates: false) else {
            change()
            return
        }
        window.addSubview(snapshot)
        change()
        UIView.animate(withDuration: 0.35, delay: 0.03, options: [.curveEaseInOut, .allowUserInteraction]) {
            snapshot.alpha = 0
        } completion: { _ in
            snapshot.removeFromSuperview()
        }
    }
}

// MARK: - Стекло (iOS 26 — Liquid Glass, раньше — материал)

struct GlassModifier<S: Shape>: ViewModifier {
    let shape: S
    var interactive = false

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            let glass: Glass = interactive ? Glass.regular.interactive() : Glass.regular
            content.glassEffect(glass, in: shape)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(Theme.border, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.1), radius: 16, y: 8)
        }
    }
}

extension View {
    func scGlass<S: Shape>(_ shape: S, interactive: Bool = false) -> some View {
        modifier(GlassModifier(shape: shape, interactive: interactive))
    }
}

// MARK: - Фон экранов входа

struct AppBackground: View {
    /// Мягкое янтарное свечение сверху.
    var glow: Double = 0.22
    var body: some View {
        Theme.background
            .overlay(alignment: .topLeading) {
                if glow > 0 {
                    RadialGradient(colors: [Theme.tint.opacity(glow), .clear], center: .center, startRadius: 0, endRadius: 260)
                        .frame(width: 520, height: 520)
                        .offset(x: -220, y: -300)
                        .blur(radius: 30)
                        .allowsHitTesting(false)
                }
            }
            .ignoresSafeArea()
    }
}

// MARK: - Кнопки

/// Сжатие при нажатии и отпускание пружиной с лёгким перелётом.
struct PressScaleStyle: ButtonStyle {
    var scale: CGFloat = 0.96
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(configuration.isPressed ? .easeOut(duration: 0.14) : .spring(response: 0.35, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

struct SCButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, tinted, danger }
    var kind: Kind = .primary
    var small = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(small ? .sc(15, .semibold, relativeTo: .subheadline) : .sc(17, .semibold, relativeTo: .headline))
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, small ? 16 : 22)
            .frame(maxWidth: small ? nil : .infinity, minHeight: small ? 36 : 52)
            .background { background }
            .overlay {
                if kind == .primary {
                    Capsule().strokeBorder(LinearGradient(colors: [.white.opacity(0.5), .clear], startPoint: .top, endPoint: .center), lineWidth: 1)
                }
            }
            .shadow(color: kind == .primary && isEnabled ? Theme.tintDeep.opacity(0.3) : .clear, radius: 12, y: 6)
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(configuration.isPressed ? .easeOut(duration: 0.14) : .spring(response: 0.35, dampingFraction: 0.6), value: configuration.isPressed)
    }

    private var foreground: Color {
        switch kind {
        case .primary: return Theme.onTint
        case .secondary: return Theme.label
        case .tinted: return Theme.ink
        case .danger: return Theme.red
        }
    }

    @ViewBuilder private var background: some View {
        switch kind {
        case .primary: Capsule().fill(Theme.tint)
        case .secondary: Capsule().fill(Theme.fill)
        case .tinted: Capsule().fill(Theme.tintSoft)
        case .danger: Capsule().fill(Theme.red.opacity(0.14))
        }
    }
}

extension ButtonStyle where Self == SCButtonStyle {
    static var scPrimary: SCButtonStyle { SCButtonStyle(kind: .primary) }
    static var scSecondary: SCButtonStyle { SCButtonStyle(kind: .secondary) }
    static var scTinted: SCButtonStyle { SCButtonStyle(kind: .tinted) }
    static func sc(_ kind: SCButtonStyle.Kind, small: Bool = false) -> SCButtonStyle { SCButtonStyle(kind: kind, small: small) }
}

/// Подпись кнопки с индикатором: ширина не меняется, текст уходит, крутится индикатор.
struct LoadingLabel: View {
    let title: String
    var icon: String? = nil
    var loading = false
    var spinnerTint: Color = Theme.onTint

    var body: some View {
        ZStack {
            HStack(spacing: 8) {
                if let icon { Image(systemName: icon).font(.system(size: 16, weight: .semibold)) }
                Text(title)
            }
            .opacity(loading ? 0 : 1)
            if loading {
                ProgressView().tint(spinnerTint)
            }
        }
        .animation(.easeOut(duration: 0.2), value: loading)
    }
}

// MARK: - Карточки и поля (экраны входа)

struct SolidCard: ViewModifier {
    var padding: CGFloat = 16
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.cell, in: RoundedRectangle(cornerRadius: Theme.rCell, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.rCell, style: .continuous).strokeBorder(Theme.border, lineWidth: 0.5))
    }
}

struct HeroCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.cell, in: RoundedRectangle(cornerRadius: Theme.rCard, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.rCard, style: .continuous).strokeBorder(Theme.border, lineWidth: 0.5))
    }
}

extension View {
    func solidCard(padding: CGFloat = 16) -> some View { modifier(SolidCard(padding: padding)) }
    func heroCard() -> some View { modifier(HeroCard()) }
}

struct SCFieldStyle: ViewModifier {
    var focused = false
    func body(content: Content) -> some View {
        content
            .font(.scBody)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(minHeight: 52)
            .background(Theme.cell, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(focused ? Theme.ink.opacity(0.8) : Theme.border, lineWidth: focused ? 1 : 0.5))
    }
}

extension View {
    func scField(focused: Bool = false) -> some View { modifier(SCFieldStyle(focused: focused)) }
}

struct HeroBadge: View {
    let systemName: String
    let color: Color
    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 26, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 56, height: 56)
            .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// Нейтральная плитка-иконка для экранов входа.
struct CellIcon: View {
    let systemName: String
    var color: Color? = nil
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(color ?? Theme.label)
            .frame(width: size, height: size)
            .background((color ?? Theme.label).opacity(color == nil ? 0.08 : 0.16), in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
    }
}

/// Цветная иконка 30×30 со скруглением 8 — как в «Настройках» iPhone.
struct SquareIcon: View {
    let systemName: String
    let color: Color
    var foreground: Color = .white

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(foreground)
            .frame(width: 30, height: 30)
            .background(color, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// Плашка статуса: «● Активна».
struct StatusPill: View {
    let text: String
    let color: Color
    var dot = true
    var body: some View {
        HStack(spacing: 6) {
            if dot { Circle().fill(color).frame(width: 7, height: 7) }
            Text(text)
        }
        .font(.sc(13, .semibold, relativeTo: .footnote))
        .foregroundStyle(color)
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(color.opacity(0.15), in: Capsule())
    }
}

/// Маленькая плашка «быстрее всех», «вы здесь».
struct Chip: View {
    let text: String
    var color: Color = Theme.ink
    var body: some View {
        Text(text)
            .font(.sc(11.5, .semibold, relativeTo: .caption))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(color.opacity(0.14), in: Capsule())
            .fixedSize()
    }
}

// MARK: - Бренд, флаги, качество связи

struct BrandMark: View {
    var size: CGFloat = 88
    var glow = true
    var body: some View {
        Image("Brand")
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).strokeBorder(Theme.border, lineWidth: 0.5))
            .shadow(color: glow ? Theme.tintDeep.opacity(0.35) : .clear, radius: size * 0.18, y: size * 0.1)
            .background {
                if glow {
                    Circle().fill(Theme.tint.opacity(0.3)).frame(width: size * 1.5, height: size * 1.5).blur(radius: size * 0.3)
                }
            }
    }
}

struct Flag: View {
    let emoji: String
    var size: CGFloat = 30
    init(code: String, size: CGFloat = 30) {
        self.emoji = code.flagEmoji
        self.size = size
    }
    init(emoji: String, size: CGFloat = 30) {
        self.emoji = emoji
        self.size = size
    }
    var body: some View {
        Text(emoji)
            .font(.system(size: size * 0.74))
            .frame(width: size, height: size)
            .background(Theme.fill, in: Circle())
            .clipShape(Circle())
    }
}

/// Качество связи — 4 полоски вместо миллисекунд. measuring — «волна», пока меряем.
struct QualityBars: View {
    let level: Int?
    var measuring = false
    var tint: Color = Theme.label

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.033, paused: !measuring)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(!measuring && i < (level ?? 0) ? tint : Theme.label3)
                        .frame(width: 3.5, height: CGFloat(5 + 3 * i))
                        .opacity(measuring ? wave(t, i) : 1)
                }
            }
        }
        .frame(height: 14)
        .animation(.easeOut(duration: 0.3), value: level)
        .accessibilityLabel(measuring ? "Меряем связь" : "Связь: \(Quality.word(level))")
    }

    private func wave(_ t: TimeInterval, _ i: Int) -> Double {
        let phase = (t - Double(i) * 0.12).truncatingRemainder(dividingBy: 1.0)
        return 0.35 + 0.65 * max(0, sin(phase * .pi))
    }
}

/// Плавно мерцает, пока активно (значок «подключаемся»).
struct PulseModifier: ViewModifier {
    let active: Bool
    var period: Double = 1.2
    func body(content: Content) -> some View {
        TimelineView(.animation(minimumInterval: 0.033, paused: !active)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            content.opacity(active ? 0.725 + 0.275 * cos(2 * .pi * t / period) : 1)
        }
    }
}

// MARK: - Плашка-уведомление

struct ToastMessage: Equatable, Identifiable {
    enum Tone { case neutral, good, bad }
    let id = UUID()
    let text: String
    var icon: String = "arrow.triangle.2.circlepath"
    var tone: Tone = .neutral
}

struct ToastView: View {
    let toast: ToastMessage

    private var color: Color {
        switch toast.tone {
        case .neutral: return Theme.ink
        case .good: return Theme.green
        case .bad: return Theme.red
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: toast.icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(color)
            Text(toast.text)
                .font(.sc(15, .medium, relativeTo: .subheadline))
                .foregroundStyle(Theme.label)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .scGlass(Capsule())
        .padding(.horizontal, 16)
        .accessibilityElement(children: .combine)
    }
}

extension NetworkMode {
    var color: Color {
        switch self {
        case .unknown: return Theme.gray
        case .normal: return Theme.green
        case .whitelist: return Theme.orange
        case .offline: return Theme.red
        }
    }
}

extension SubscriptionStatus {
    var color: Color {
        switch self {
        case .active: return Theme.green
        case .expiring: return Theme.orange
        case .expired, .limited, .disabled: return Theme.red
        }
    }
}

struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.title
            configuration.icon.font(.system(size: 11, weight: .semibold))
        }
    }
}
