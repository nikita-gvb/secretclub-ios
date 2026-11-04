import SwiftUI
import UIKit

// SecretClub — дизайн-система в стиле мини-аппа и бота: чёрный фон, плотные карточки,
// оранжевый акцент, шрифт Onest, шкала 34/28/22/20/17/15/13. Минимализм: цвет — только у акцента и статусов.

enum Theme {
    static let tint = Color(hex: 0xFFA31A)
    static let tintStrong = Color(hex: 0xFF9500)
    static let tintTop = Color(hex: 0xFFCB45)
    static let onTint = Color(hex: 0x1F1300)
    static let tintSoft = Color(hex: 0xFFA31A, opacity: 0.16)

    static let green = Color(hex: 0x30D158)
    static let orange = Color(hex: 0xFF9F0A)
    static let red = Color(hex: 0xFF453A)
    static let yellow = Color(hex: 0xFFD60A)
    static let gray = Color(hex: 0x8E8E93)

    static let background = Color.black
    static let cell = Color(hex: 0x1C1C1E)
    static let cell2 = Color(hex: 0x2C2C2E)
    static let cellPress = Color(hex: 0x3A3A3C)
    static let fill = Color(hex: 0x787880, opacity: 0.24)
    static let fill2 = Color(hex: 0x787880, opacity: 0.16)
    static let fill3 = Color(hex: 0x767680, opacity: 0.12)
    static let separator = Color(hex: 0x545458, opacity: 0.6)
    static let border = Color.white.opacity(0.06)

    static let label = Color.white
    static let label2 = Color(hex: 0xEBEBF5, opacity: 0.62)
    static let label3 = Color(hex: 0xEBEBF5, opacity: 0.32)

    static let tintGradient = LinearGradient(colors: [tintTop, tintStrong], startPoint: .top, endPoint: .bottom)
    static let heroGradient = LinearGradient(colors: [Color(hex: 0x202023), Color(hex: 0x18181A)], startPoint: .top, endPoint: .bottom)

    static let rCell: CGFloat = 22
    static let rCard: CGFloat = 28
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

// MARK: - Типографика (Onest)

extension Font {
    static func onest(_ size: CGFloat, _ weight: Font.Weight = .regular, relativeTo style: Font.TextStyle = .body) -> Font {
        .custom(onestName(weight), size: size, relativeTo: style)
    }

    static func onestName(_ weight: Font.Weight) -> String {
        switch weight {
        case .bold, .heavy, .black: return "Onest-Bold"
        case .semibold: return "Onest-SemiBold"
        case .medium: return "Onest-Medium"
        default: return "Onest-Regular"
        }
    }

    static let scLarge = onest(34, .bold, relativeTo: .largeTitle)
    static let scTitle1 = onest(28, .bold, relativeTo: .title)
    static let scTitle2 = onest(22, .bold, relativeTo: .title2)
    static let scTitle3 = onest(20, .semibold, relativeTo: .title3)
    static let scHeadline = onest(17, .semibold, relativeTo: .headline)
    static let scBody = onest(17, relativeTo: .body)
    static let scSub = onest(15, relativeTo: .subheadline)
    static let scFoot = onest(13, relativeTo: .footnote)
    static let scCaption = onest(12, .medium, relativeTo: .caption)
}

enum Appearance {
    /// Шрифты и фон системных навбаров/сегментов — под Onest и чёрный фон.
    static func apply() {
        let nav = UINavigationBarAppearance()
        nav.configureWithTransparentBackground()
        nav.titleTextAttributes = [.font: uiFont(17, .semibold), .foregroundColor: UIColor.white]
        nav.largeTitleTextAttributes = [.font: uiFont(34, .bold), .foregroundColor: UIColor.white]
        let button = UIBarButtonItemAppearance()
        button.normal.titleTextAttributes = [.font: uiFont(17, .regular)]
        nav.buttonAppearance = button
        nav.backButtonAppearance = button
        let scrolled = UINavigationBarAppearance()
        scrolled.configureWithDefaultBackground()
        scrolled.backgroundEffect = UIBlurEffect(style: .systemUltraThinMaterialDark)
        scrolled.backgroundColor = UIColor(red: 10 / 255, green: 10 / 255, blue: 14 / 255, alpha: 0.6)
        scrolled.shadowColor = UIColor.white.withAlphaComponent(0.08)
        scrolled.titleTextAttributes = nav.titleTextAttributes
        scrolled.largeTitleTextAttributes = nav.largeTitleTextAttributes
        scrolled.buttonAppearance = button
        scrolled.backButtonAppearance = button
        UINavigationBar.appearance().standardAppearance = scrolled
        UINavigationBar.appearance().compactAppearance = scrolled
        UINavigationBar.appearance().scrollEdgeAppearance = nav

        let seg = UISegmentedControl.appearance()
        seg.setTitleTextAttributes([.font: uiFont(15, .medium), .foregroundColor: UIColor.white], for: .normal)
        seg.selectedSegmentTintColor = UIColor(red: 0x63 / 255, green: 0x63 / 255, blue: 0x66 / 255, alpha: 1)
    }

    static func uiFont(_ size: CGFloat, _ weight: Font.Weight) -> UIFont {
        UIFont(name: Font.onestName(weight), size: size) ?? .systemFont(ofSize: size)
    }
}

// MARK: - Фон

struct AppBackground: View {
    /// Мягкое оранжевое свечение сверху — как в мини-аппе, но одно и тихое.
    var glow: Double = 0.22
    var body: some View {
        Theme.background
            .overlay(alignment: .topLeading) {
                if glow > 0 {
                    RadialGradient(colors: [Theme.tintStrong.opacity(glow), .clear], center: .center, startRadius: 0, endRadius: 260)
                        .frame(width: 520, height: 520)
                        .offset(x: -220, y: -300)
                        .blur(radius: 30)
                        .allowsHitTesting(false)
                }
            }
            .ignoresSafeArea()
    }
}

// MARK: - Страница

struct PageHeader<Accessory: View>: View {
    let title: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 12) {
            Text(title)
                .font(.scLarge)
                .tracking(-0.8)
                .foregroundStyle(Theme.label)
            Spacer(minLength: 0)
            accessory
        }
        .padding(.horizontal, 4)
        .padding(.top, 8)
        .padding(.bottom, 14)
    }
}

extension PageHeader where Accessory == EmptyView {
    init(title: String) {
        self.title = title
        self.accessory = EmptyView()
    }
}

struct PageScroll<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(.horizontal, 16)
                .padding(.top, 8)
        }
        .scrollIndicators(.hidden)
        .contentMargins(.bottom, 110, for: .scrollContent)
        .background(AppBackground())
    }
}

// MARK: - Группированные списки

struct SCSection<Content: View>: View {
    var header: String? = nil
    var footer: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let header {
                Text(header)
                    .font(.onest(13, .medium, relativeTo: .footnote))
                    .foregroundStyle(Theme.label2)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 7)
            }
            VStack(spacing: 0) { content }
                .background(Theme.cell.opacity(0.86), in: RoundedRectangle(cornerRadius: Theme.rCell, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.rCell, style: .continuous).strokeBorder(Color.white.opacity(0.05), lineWidth: 0.5))
                .clipShape(RoundedRectangle(cornerRadius: Theme.rCell, style: .continuous))
            if let footer {
                Text(footer)
                    .font(.scFoot)
                    .foregroundStyle(Theme.label2)
                    .padding(.horizontal, 16)
                    .padding(.top, 7)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 26)
    }
}

struct SCDivider: View {
    var inset: CGFloat = 58
    var body: some View {
        Rectangle().fill(Theme.separator).frame(height: 0.5).padding(.leading, inset)
    }
}

/// Строка списка: иконка, заголовок, подпись, значение, шеврон.
struct SCRow<Leading: View, Trailing: View>: View {
    var title: String
    var subtitle: String? = nil
    var value: String? = nil
    var chevron = false
    var titleColor: Color = Theme.label
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            leading
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.scBody).foregroundStyle(titleColor).lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(.scFoot).foregroundStyle(Theme.label2).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            if let value {
                Text(value).font(.scBody).foregroundStyle(Theme.label2).lineLimit(1).monospacedDigit()
            }
            trailing
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.label3)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
    }
}

extension SCRow where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, value: String? = nil, chevron: Bool = false, titleColor: Color = Theme.label, @ViewBuilder leading: () -> Leading) {
        self.init(title: title, subtitle: subtitle, value: value, chevron: chevron, titleColor: titleColor, leading: leading, trailing: { EmptyView() })
    }
}

extension SCRow where Leading == EmptyView, Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, value: String? = nil, chevron: Bool = false, titleColor: Color = Theme.label) {
        self.init(title: title, subtitle: subtitle, value: value, chevron: chevron, titleColor: titleColor, leading: { EmptyView() }, trailing: { EmptyView() })
    }
}

/// Нейтральная плитка-иконка 30×30. Цвет — только для статусов.
struct CellIcon: View {
    let systemName: String
    var color: Color? = nil
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(color ?? Theme.label)
            .frame(width: size, height: size)
            .background((color ?? .white).opacity(color == nil ? 0.1 : 0.16), in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
    }
}

struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Theme.cellPress : Color.clear)
    }
}

// MARK: - Кнопки

struct SCButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, tinted, danger }
    var kind: Kind = .primary
    var small = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(small ? .onest(15, .semibold, relativeTo: .subheadline) : .onest(17, .semibold, relativeTo: .headline))
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, small ? 16 : 22)
            .frame(maxWidth: small ? nil : .infinity, minHeight: small ? 36 : 50)
            .background { background }
            .overlay {
                if kind == .primary {
                    Capsule().strokeBorder(LinearGradient(colors: [.white.opacity(0.45), .clear], startPoint: .top, endPoint: .center), lineWidth: 1)
                }
            }
            .shadow(color: kind == .primary && isEnabled ? Theme.tintStrong.opacity(0.28) : .clear, radius: 12, y: 6)
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }

    private var foreground: Color {
        switch kind {
        case .primary: return Theme.onTint
        case .secondary: return Theme.label
        case .tinted: return Theme.tint
        case .danger: return Theme.red
        }
    }

    @ViewBuilder private var background: some View {
        switch kind {
        case .primary: Capsule().fill(Theme.tintGradient)
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

struct RoundIconButton: View {
    let systemName: String
    var size: CGFloat = 50
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(Theme.label)
                .frame(width: size, height: size)
                .background(Theme.fill, in: Circle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Карточки

struct HeroCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.heroGradient, in: RoundedRectangle(cornerRadius: Theme.rCard, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.rCard, style: .continuous).strokeBorder(Color.white.opacity(0.07), lineWidth: 0.5))
            .overlay(alignment: .top) {
                RoundedRectangle(cornerRadius: Theme.rCard, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.06), .clear], startPoint: .top, endPoint: .init(x: 0.5, y: 0.08)), lineWidth: 1)
            }
    }
}

struct SolidCard: ViewModifier {
    var padding: CGFloat = 16
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.cell.opacity(0.86), in: RoundedRectangle(cornerRadius: Theme.rCell, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.rCell, style: .continuous).strokeBorder(Theme.border, lineWidth: 0.5))
    }
}

extension View {
    func heroCard() -> some View { modifier(HeroCard()) }
    func solidCard(padding: CGFloat = 16) -> some View { modifier(SolidCard(padding: padding)) }
}

/// Плашка статуса: «● Активна».
struct StatusPill: View {
    let text: String
    let color: Color
    var dot = true
    var body: some View {
        HStack(spacing: 6) {
            if dot {
                Circle().fill(color).frame(width: 7, height: 7)
                    .background(Circle().fill(color.opacity(0.22)).frame(width: 13, height: 13))
            }
            Text(text)
        }
        .font(.onest(13, .semibold, relativeTo: .footnote))
        .foregroundStyle(color)
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(color.opacity(0.14), in: Capsule())
    }
}

/// Большое число с оранжевым градиентом — как «23 дня» в мини-аппе.
struct HeroNumber: View {
    let text: String
    var muted = false
    var size: CGFloat = 52
    var body: some View {
        Text(text)
            .font(.onest(size, .bold, relativeTo: .largeTitle))
            .tracking(-size * 0.04)
            .monospacedDigit()
            .foregroundStyle(muted ? AnyShapeStyle(Theme.label) : AnyShapeStyle(Theme.tintGradient))
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }
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

struct StatTile: View {
    let label: String
    let value: String
    var hint: String? = nil
    var progress: Double? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.scCaption).foregroundStyle(Theme.label2)
            Text(value).font(.onest(16, .semibold, relativeTo: .callout)).foregroundStyle(Theme.label).lineLimit(1).monospacedDigit()
            if let hint {
                Text(hint).font(.onest(12, relativeTo: .caption)).foregroundStyle(Theme.label3).lineLimit(1)
            }
            if let progress {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.1))
                        Capsule().fill(Theme.tint).frame(width: geo.size.width * min(1, max(0, progress)))
                    }
                }
                .frame(height: 4)
                .padding(.top, 7)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Бренд, флаги, пинг

struct BrandMark: View {
    var size: CGFloat = 88
    var glow = true
    var body: some View {
        Image("Brand")
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).strokeBorder(Color.white.opacity(0.2), lineWidth: 0.5))
            .shadow(color: glow ? Theme.tintStrong.opacity(0.38) : .clear, radius: size * 0.18, y: size * 0.1)
            .background {
                if glow {
                    Circle().fill(Theme.tintStrong.opacity(0.35)).frame(width: size * 1.5, height: size * 1.5).blur(radius: size * 0.3)
                }
            }
    }
}

struct Flag: View {
    let code: String
    var size: CGFloat = 30
    var body: some View {
        Text(code.flagEmoji)
            .font(.system(size: size * 0.74))
            .frame(width: size, height: size)
            .background(Theme.fill3, in: Circle())
            .clipShape(Circle())
    }
}

enum Ping {
    static func color(_ ms: Int?) -> Color {
        guard let ms else { return Theme.gray }
        if ms < 80 { return Theme.green }
        if ms < 160 { return Theme.orange }
        return Theme.red
    }
    static func text(_ ms: Int?) -> String { ms.map { "\($0) мс" } ?? "—" }
}

struct PingLabel: View {
    let ms: Int?
    var body: some View {
        HStack(spacing: 6) {
            Text(Ping.text(ms)).font(.scSub).foregroundStyle(Theme.label2).monospacedDigit()
            Circle().fill(Ping.color(ms)).frame(width: 8, height: 8)
        }
    }
}

struct CheckMark: View {
    let on: Bool
    var body: some View {
        ZStack {
            Circle().strokeBorder(on ? Theme.tint : Theme.label3, lineWidth: 1.5)
            if on {
                Circle().fill(Theme.tint)
                Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.onTint)
            }
        }
        .frame(width: 24, height: 24)
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

// MARK: - Поле ввода

struct SCFieldStyle: ViewModifier {
    var focused = false
    func body(content: Content) -> some View {
        content
            .font(.scBody)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(minHeight: 52)
            .background(Theme.cell, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(focused ? Theme.tint.opacity(0.7) : Color.white.opacity(0.08), lineWidth: focused ? 1 : 0.5))
    }
}

extension View {
    func scField(focused: Bool = false) -> some View { modifier(SCFieldStyle(focused: focused)) }
}

// MARK: - Таб-бар: плавающая капсула со «стеклом», как в мини-аппе

struct SCTabBar: View {
    @Binding var selection: AppTab
    @Namespace private var ns

    private struct Item: Identifiable {
        let tab: AppTab
        let title: String
        let icon: String
        var id: AppTab { tab }
    }

    private let items: [Item] = [
        Item(tab: .home, title: "Главная", icon: "house"),
        Item(tab: .locations, title: "Локации", icon: "globe"),
        Item(tab: .subscription, title: "Подписка", icon: "creditcard"),
        Item(tab: .settings, title: "Настройки", icon: "gearshape"),
    ]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items) { item in
                let tab = item.tab, title = item.title, icon = item.icon
                let on = tab == selection
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { selection = tab }
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: icon)
                            .font(.system(size: 20, weight: on ? .semibold : .regular))
                            .frame(height: 24)
                        Text(title).font(.onest(11, .semibold, relativeTo: .caption2))
                    }
                    .foregroundStyle(on ? Theme.tint : Theme.label)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background {
                        if on {
                            Capsule().fill(Color.white.opacity(0.1))
                                .overlay(Capsule().strokeBorder(LinearGradient(colors: [.white.opacity(0.18), .clear], startPoint: .top, endPoint: .center), lineWidth: 0.5))
                                .matchedGeometryEffect(id: "pill", in: ns)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(5)
        .background {
            Capsule().fill(.ultraThinMaterial)
                .overlay(Capsule().fill(Color(hex: 0x1E1E24, opacity: 0.55)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.45), radius: 20, y: 12)
        }
        .environment(\.colorScheme, .dark)
        .frame(maxWidth: 400)
        .padding(.horizontal, 20)
        .sensoryFeedback(.selection, trigger: selection)
    }
}
