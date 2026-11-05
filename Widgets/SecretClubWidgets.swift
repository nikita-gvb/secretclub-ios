import AppIntents
import SwiftUI
import WidgetKit

@main
struct SecretClubWidgetBundle: WidgetBundle {
    var body: some Widget {
        StatusWidget()
        if #available(iOS 18.0, *) {
            VPNControl()
        }
    }
}

// MARK: - Данные

struct VPNEntry: TimelineEntry {
    var date: Date
    var status: VPNSwitch.Status
    var flag: String?
    var server: String?
    var since: Date?
    var pingMS: Int?
    var healthy: Bool?
    var auto = false
    /// Сети нет (по последней проверке расширения).
    var offline = false
    /// Подписка (из общей папки, если она есть): окончание и можно ли подключаться.
    var subscriptionEnds: Date?
    var lifetime = false
    var usable = true

    var isOn: Bool { status.isOn }

    /// Подписка закончилась, а VPN выключен — вместо «Включить» ведём продлевать.
    var expired: Bool {
        guard !isOn else { return false }
        if !usable { return true }
        if let end = subscriptionEnds, !lifetime { return end < date }
        return false
    }

    /// Сколько дней подписки осталось, если мало (до 5).
    var daysLeft: Int? {
        guard let end = subscriptionEnds, !lifetime, end > date else { return nil }
        let days = Int(ceil(end.timeIntervalSince(date) / 86400))
        return days <= 5 ? days : nil
    }

    var headline: String {
        if expired { return "Подписка кончилась" }
        switch status {
        case .on: return offline ? "Нет сети" : (healthy == false ? "Нет ответа" : "Защищено")
        case .connecting: return "Подключение…"
        case .off: return "Выключено"
        case .missing: return "Не настроен"
        }
    }

    var serverLine: String {
        if status == .missing { return "Откройте приложение" }
        if expired { return "Продлите в приложении" }
        let name = [flag, server].compactMap { $0 }.joined(separator: " ")
        if name.isEmpty { return auto ? "Авто" : "SecretClub" }
        return name
    }

    static let preview = VPNEntry(date: Date(), status: .on, flag: "🇫🇮", server: "Финляндия",
                                  since: Date().addingTimeInterval(-3725), pingMS: 42, healthy: true, auto: true)

    static func current() async -> VPNEntry {
        let snap = await VPNSwitch.snapshot()
        let shared = SharedStatus.load()
        // Общая папка свежее профиля: «Авто» мог сменить сервер сам.
        let fresh = shared.map { Date().timeIntervalSince($0.updatedAt) < 6 * 3600 } ?? false
        let title = (snap.status.isOn && fresh && shared?.running == true ? shared?.routeTitle : nil) ?? snap.routeTitle ?? shared?.routeTitle
        let parts = SharedStatus.split(title)
        let live = snap.status == .on && fresh && shared?.running == true
        let group = AppGroup.defaults
        let ends = group?.double(forKey: SharedKey.subscriptionEnds) ?? 0
        return VPNEntry(date: Date(), status: snap.status, flag: parts.flag, server: parts.name,
                        since: snap.status == .on ? (snap.connectedDate ?? shared?.since) : nil,
                        pingMS: live ? shared?.pingMS : nil, healthy: live ? shared?.healthy : nil,
                        auto: shared?.auto ?? false,
                        offline: live && shared?.network == "offline",
                        subscriptionEnds: ends > 0 ? Date(timeIntervalSince1970: ends) : nil,
                        lifetime: group?.bool(forKey: SharedKey.subscriptionLifetime) ?? false,
                        usable: group?.object(forKey: SharedKey.subscriptionUsable) as? Bool ?? true)
    }
}

struct VPNProvider: TimelineProvider {
    func placeholder(in context: Context) -> VPNEntry { .preview }

    func getSnapshot(in context: Context, completion: @escaping (VPNEntry) -> Void) {
        if context.isPreview {
            completion(.preview)
            return
        }
        Task { completion(await VPNEntry.current()) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<VPNEntry>) -> Void) {
        Task {
            let entry = await VPNEntry.current()
            // Подключение идёт — заглянем скоро; иначе виджет обновят само расширение VPN и приложение
            // (при каждом изменении), а этот запас — на случай, если обновление не дошло.
            let next: TimeInterval = entry.status == .connecting ? 5 : (entry.isOn ? 20 * 60 : 60 * 60)
            var entries = [entry]
            // Подписка закончится раньше следующего обновления — заранее готовим вид «кончилась».
            if let end = entry.subscriptionEnds, !entry.lifetime, end > entry.date,
               end < entry.date.addingTimeInterval(next) {
                var after = entry
                after.date = end.addingTimeInterval(1)
                entries.append(after)
            }
            completion(Timeline(entries: entries, policy: .after(Date().addingTimeInterval(next))))
        }
    }
}

// MARK: - Оформление

enum WidgetTheme {
    static let amber = Color(.displayP3, red: 0.980, green: 0.708, blue: 0.105)
    static let onAmber = Color(red: 0x1F / 255, green: 0x14 / 255, blue: 0)
    static let top = Color(red: 0x16 / 255, green: 0x1A / 255, blue: 0x2B / 255)
    static let bottom = Color(red: 0x0D / 255, green: 0x10 / 255, blue: 0x20 / 255)
    static let green = Color(red: 0x30 / 255, green: 0xD1 / 255, blue: 0x58 / 255)
    static let red = Color(red: 1, green: 0x45 / 255, blue: 0x3A / 255)

    static var background: some View {
        ZStack {
            LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [amber.opacity(0.22), .clear], center: .topTrailing, startRadius: 4, endRadius: 150)
        }
    }

    static func dot(_ entry: VPNEntry) -> Color {
        if entry.expired { return red }
        switch entry.status {
        case .on: return entry.healthy == false || entry.offline ? red : green
        case .connecting: return amber
        case .off, .missing: return Color.white.opacity(0.35)
        }
    }
}

// MARK: - Виджет состояния

struct StatusWidget: Widget {
    let kind = "SecretClubStatus"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: VPNProvider()) { entry in
            // Маленький виджет нажимается целиком (ссылки внутри не работают): подписка кончилась — ведём продлевать.
            StatusWidgetView(entry: entry)
                .widgetURL(entry.expired ? WidgetLinks.subscription : WidgetLinks.home)
        }
        .configurationDisplayName("SecretClub")
        .description("Состояние VPN, сервер и кнопка включения.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct StatusWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: VPNEntry

    var body: some View {
        switch family {
        case .systemMedium: MediumView(entry: entry).containerBackground(for: .widget) { WidgetTheme.background }
        case .accessoryCircular: CircularView(entry: entry).containerBackground(for: .widget) { AccessoryWidgetBackground() }
        case .accessoryRectangular: RectangularView(entry: entry).containerBackground(for: .widget) { Color.clear }
        case .accessoryInline: InlineView(entry: entry).containerBackground(for: .widget) { Color.clear }
        default: SmallView(entry: entry).containerBackground(for: .widget) { WidgetTheme.background }
        }
    }
}

/// Строка «логотип + SecretClub + точка состояния».
private struct BrandHeader: View {
    let entry: VPNEntry

    var body: some View {
        HStack(spacing: 6) {
            Image("Brand")
                .resizable()
                .interpolation(.high)
                .frame(width: 20, height: 20)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            Text("SecretClub")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
            Spacer(minLength: 4)
            Circle()
                .fill(WidgetTheme.dot(entry))
                .frame(width: 8, height: 8)
                .shadow(color: WidgetTheme.dot(entry).opacity(entry.isOn ? 0.8 : 0), radius: 4)
        }
    }
}

/// Сервер и время подключения.
private struct DetailsBlock: View {
    let entry: VPNEntry
    var large = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(entry.headline)
                .font(.system(size: large ? 22 : 19, weight: .bold, design: .rounded))
                .foregroundStyle(entry.status == .on ? WidgetTheme.amber : .white)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .invalidatableContent()
            Text(entry.serverLine)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if entry.status == .on, let since = entry.since {
                HStack(spacing: 4) {
                    Image(systemName: "clock").font(.system(size: 10, weight: .semibold))
                    Text(since, style: .timer).monospacedDigit()
                    if large, let ms = entry.pingMS {
                        Text("· \(ms) мс").monospacedDigit()
                    }
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
            }
        }
    }
}

private struct SmallView: View {
    let entry: VPNEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            BrandHeader(entry: entry)
            Spacer(minLength: 6)
            DetailsBlock(entry: entry)
            Spacer(minLength: 8)
            if entry.status == .missing {
                CapsuleLabel(title: "Открыть", icon: "arrow.up.forward.app", filled: true)
            } else if entry.expired {
                CapsuleLabel(title: "Продлить", icon: "creditcard", filled: true)
            } else {
                // Переключатель, а не кнопка: iOS сразу показывает новое положение, не дожидаясь VPN.
                Toggle(isOn: entry.isOn, intent: SetVPNIntent(value: !entry.isOn)) { Text("VPN") }
                    .toggleStyle(CapsuleToggleStyle())
            }
        }
    }
}

enum WidgetLinks {
    static let home = URL(string: "secretclub://home")!
    static let subscription = URL(string: "secretclub://subscription")!
    static let servers = URL(string: "secretclub://servers")!
}

/// Капсула «Включить / Выключить».
private struct CapsuleLabel: View {
    @Environment(\.widgetRenderingMode) private var mode
    let title: String
    let icon: String
    let filled: Bool

    var body: some View {
        let full = mode == .fullColor
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 13, weight: .bold))
            Text(title).font(.system(size: 14, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
        }
        .foregroundStyle(filled && full ? WidgetTheme.onAmber : .white)
        .frame(maxWidth: .infinity, minHeight: 34)
        .background(filled && full ? AnyShapeStyle(WidgetTheme.amber) : AnyShapeStyle(Color.white.opacity(filled ? 0.26 : 0.14)),
                    in: Capsule())
        .widgetAccentable(filled)
    }
}

private struct CapsuleToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        CapsuleLabel(title: configuration.isOn ? "Выключить" : "Включить", icon: "power", filled: !configuration.isOn)
    }
}

private struct DiscToggleStyle: ToggleStyle {
    let connecting: Bool
    func makeBody(configuration: Configuration) -> some View {
        PowerDisc(on: configuration.isOn, connecting: connecting && configuration.isOn)
    }
}

private struct MediumView: View {
    let entry: VPNEntry

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 0) {
                BrandHeader(entry: entry)
                Spacer(minLength: 6)
                DetailsBlock(entry: entry, large: true)
                Spacer(minLength: 4)
                Text(footer)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
            }
            if entry.expired {
                Link(destination: WidgetLinks.subscription) { PowerDisc(on: false, connecting: false, icon: "creditcard") }
            } else if entry.status != .missing {
                Toggle(isOn: entry.isOn, intent: SetVPNIntent(value: !entry.isOn)) { Text("VPN") }
                    .toggleStyle(DiscToggleStyle(connecting: entry.status == .connecting))
            }
        }
    }

    private var footer: String {
        if entry.expired { return "Нажмите, чтобы продлить" }
        if let days = entry.daysLeft {
            return "Подписка: ещё \(days) \(days == 1 ? "день" : (days < 5 ? "дня" : "дней"))"
        }
        switch entry.status {
        case .on: return entry.auto ? "Авто: сервер выбирается сам" : "Сервер выбран вручную"
        case .connecting: return "Ищем лучший сервер"
        case .off: return "Нажмите, чтобы включить"
        case .missing: return "Войдите и подключитесь один раз"
        }
    }
}

private struct PowerDisc: View {
    @Environment(\.widgetRenderingMode) private var mode
    let on: Bool
    let connecting: Bool
    var icon = "power"

    var body: some View {
        let full = mode == .fullColor
        ZStack {
            Circle()
                .fill(on && !connecting ? AnyShapeStyle(full ? WidgetTheme.amber : Color.white.opacity(0.3)) : AnyShapeStyle(Color.white.opacity(0.1)))
            Circle()
                .strokeBorder(WidgetTheme.amber.opacity(on ? 0.0 : 0.55), lineWidth: 2)
            if connecting {
                Circle()
                    .trim(from: 0, to: 0.7)
                    .stroke(WidgetTheme.amber, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(3)
            }
            Image(systemName: icon)
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(full ? (on && !connecting ? WidgetTheme.onAmber : WidgetTheme.amber) : Color.white)
                .widgetAccentable()
        }
        .frame(width: 92, height: 92)
        .shadow(color: WidgetTheme.amber.opacity(on ? 0.45 : 0), radius: 14)
    }
}

private struct CircularView: View {
    let entry: VPNEntry

    var body: some View {
        if entry.expired {
            // Нажатие откроет продление (widgetURL).
            VStack(spacing: 1) {
                Image(systemName: "exclamationmark.shield")
                    .font(.system(size: 20, weight: .semibold))
                    .widgetAccentable()
                Text("Срок").font(.system(size: 11, weight: .semibold))
            }
        } else {
            Toggle(isOn: entry.isOn, intent: SetVPNIntent(value: !entry.isOn)) { Text("VPN") }
                .toggleStyle(CircularToggleStyle(connecting: entry.status == .connecting))
                .disabled(entry.status == .missing)
        }
    }
}

private struct CircularToggleStyle: ToggleStyle {
    let connecting: Bool
    func makeBody(configuration: Configuration) -> some View {
        let on = configuration.isOn
        VStack(spacing: 1) {
            Image(systemName: on ? "lock.shield.fill" : "shield.slash")
                .font(.system(size: 20, weight: .semibold))
                .widgetAccentable()
            Text(on ? (connecting ? "…" : "Вкл") : "Выкл")
                .font(.system(size: 11, weight: .semibold))
        }
    }
}

private struct RectangularView: View {
    let entry: VPNEntry

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: entry.isOn ? "lock.shield.fill" : "shield.slash")
                .font(.system(size: 22, weight: .semibold))
                .widgetAccentable()
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.status == .on ? "SecretClub · вкл" : "SecretClub").font(.headline).lineLimit(1)
                Text(entry.status == .on || entry.status == .connecting ? entry.serverLine : entry.headline)
                    .font(.caption).lineLimit(1)
                if entry.status == .on, let since = entry.since {
                    Text(since, style: .timer).font(.caption2).monospacedDigit().lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

private struct InlineView: View {
    let entry: VPNEntry

    var body: some View {
        switch entry.status {
        case .on: Label("VPN · \(entry.serverLine)", systemImage: "lock.shield.fill")
        case .connecting: Label("VPN подключается", systemImage: "shield")
        case .off, .missing: Label("VPN выключен", systemImage: "shield.slash")
        }
    }
}

// MARK: - Пункт управления (iOS 18)

@available(iOS 18.0, *)
struct VPNControl: ControlWidget {
    static let kind = "com.secretclub.app.vpn-toggle"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind, provider: Provider()) { isOn in
            ControlWidgetToggle("SecretClub", isOn: isOn, action: SetVPNIntent()) { on in
                Label(on ? "Включён" : "Выключен", systemImage: on ? "lock.shield.fill" : "shield.slash")
            }
            .tint(WidgetTheme.amber)
        }
        .displayName("VPN SecretClub")
        .description("Включает и выключает SecretClub.")
    }

    struct Provider: ControlValueProvider {
        var previewValue: Bool { false }

        func currentValue() async throws -> Bool {
            await VPNSwitch.status().isOn
        }
    }
}
