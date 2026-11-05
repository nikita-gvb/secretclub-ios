import SwiftUI
import UIKit

enum SettingsRoute: Hashable {
    case subscription, devices, appearance, exceptions, check, advanced, selfTest, diagnostics, widgets
}

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @AppStorage(SettingsKey.autoConnect) private var autoConnect = true
    @AppStorage(SettingsKey.reminders) private var reminders = true
    @AppStorage(SettingsKey.killSwitch) private var killSwitch = false
    @AppStorage(SettingsKey.ruDirect) private var ruDirect = true
    @AppStorage(SettingsKey.appearance) private var appearance: AppAppearance = .system
    @AppStorage(SettingsKey.vpnDomains) private var vpnRaw = ""
    @AppStorage(SettingsKey.directDomains) private var directRaw = ""
    @State private var confirmLogout = false

    var body: some View {
        @Bindable var app = app
        NavigationStack(path: $app.settingsPath) {
            List {
                accountSection

                if app.hasSession || !app.subscription.devices.isEmpty {
                    Section {
                        NavigationLink(value: SettingsRoute.subscription) {
                            SettingsRow(icon: "creditcard.fill", color: Theme.tint, foreground: Theme.onTint,
                                        title: "Подписка", value: subscriptionValue)
                        }
                        if !app.subscription.devices.isEmpty {
                            NavigationLink(value: SettingsRoute.devices) {
                                SettingsRow(icon: "iphone", color: Theme.blue, title: "Устройства", value: devicesValue)
                            }
                        }
                        if !app.subscription.lifetime {
                            Toggle(isOn: $reminders) {
                                SettingsLabel(icon: "bell.badge.fill", color: .orange, title: "Напоминать о продлении")
                            }
                        }
                    } footer: {
                        if !app.subscription.lifetime {
                            Text("Уведомим за 3 дня и за день до конца подписки — чтобы VPN не отключился внезапно.")
                        }
                    }
                } else {
                    Section {
                        NavigationLink(value: SettingsRoute.subscription) {
                            SettingsRow(icon: "creditcard.fill", color: Theme.tint, foreground: Theme.onTint,
                                        title: "Подписка", value: subscriptionValue)
                        }
                    }
                }

                Section {
                    NavigationLink(value: SettingsRoute.appearance) {
                        SettingsRow(icon: "circle.lefthalf.filled", color: .indigo, title: "Оформление", value: appearance.title)
                    }
                    Toggle(isOn: $autoConnect) {
                        SettingsLabel(icon: "bolt.fill", color: Theme.green, title: "Держать VPN включённым")
                    }
                    Toggle(isOn: $killSwitch) {
                        SettingsLabel(icon: "lock.fill", color: Theme.red, title: "Без VPN — без интернета")
                    }
                    NavigationLink(value: SettingsRoute.widgets) {
                        SettingsRow(icon: "square.grid.2x2.fill", color: Theme.blue, title: "Виджеты и Пункт управления")
                    }
                } footer: {
                    Text("Включённый VPN поднимется сам, если оборвётся, iOS выгрузит его или телефон перезагрузится. Выключить — как обычно: кнопкой, виджетом или в Пункте управления. «Без VPN — без интернета» не выпустит трафик мимо VPN — сработает со следующего подключения.")
                }

                Section {
                    Toggle(isOn: $ruDirect) {
                        SettingsLabel(icon: "arrow.triangle.branch", color: .teal, title: "Российские сайты без VPN")
                    }
                    NavigationLink(value: SettingsRoute.exceptions) {
                        SettingsRow(icon: "list.bullet", color: Theme.gray, title: "Исключения", value: exceptionsValue)
                    }
                } footer: {
                    Text("Госуслуги, банки и сайты .ru откроются напрямую — быстрее и без капчи.")
                }

                Section {
                    NavigationLink(value: SettingsRoute.check) {
                        SettingsRow(icon: "stethoscope", color: .pink, title: "Проверка соединения")
                    }
                    NavigationLink(value: SettingsRoute.diagnostics) {
                        SettingsRow(icon: "waveform.path.ecg", color: .indigo, title: "Диагностика",
                                    value: app.recentIncidents > 0 ? "сбоев: \(app.recentIncidents)" : nil)
                    }
                    Link(destination: Config.supportURL) {
                        SettingsRow(icon: "paperplane.fill", color: Theme.telegram, title: "Поддержка", external: true)
                    }
                    NavigationLink(value: SettingsRoute.advanced) {
                        SettingsRow(icon: "slider.horizontal.3", color: Theme.gray, title: "Дополнительно")
                    }
                }

                Section {
                    Button(role: .destructive) { confirmLogout = true } label: {
                        Text("Выйти").foregroundStyle(Theme.red)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Настройки")
            .toggleStyle(SwitchToggleStyle(tint: Theme.tint))
            .navigationDestination(for: SettingsRoute.self) { route in
                switch route {
                case .subscription: SubscriptionScreen()
                case .devices: DevicesScreen()
                case .appearance: AppearanceView()
                case .exceptions: ExceptionsView()
                case .check: CheckView()
                case .advanced: AdvancedView()
                case .selfTest: SelfTestView()
                case .diagnostics: DiagnosticsCenter()
                case .widgets: WidgetsHelpView()
                }
            }
            .confirmationDialog("Выйти из аккаунта?", isPresented: $confirmLogout, titleVisibility: .visible) {
                Button("Выйти", role: .destructive) { app.logout() }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text("VPN отключится. Чтобы снова пользоваться, войдите через Telegram или по ссылке.")
            }
            .onChange(of: ruDirect) { app.settingsChanged() }
            .onChange(of: autoConnect) { _, on in app.autoConnectChanged(on) }
            .onChange(of: reminders) { _, on in app.remindersChanged(on) }
            .sensoryFeedback(.selection, trigger: autoConnect)
            .sensoryFeedback(.selection, trigger: killSwitch)
            .sensoryFeedback(.selection, trigger: reminders)
            .sensoryFeedback(.selection, trigger: ruDirect)
        }
    }

    @ViewBuilder private var accountSection: some View {
        Section {
            if app.hasSession {
                NavigationLink(value: SettingsRoute.subscription) {
                    HStack(spacing: 14) {
                        Text(initial)
                            .font(.sc(24, .semibold, design: .rounded, relativeTo: .title2))
                            .foregroundStyle(Theme.onTint)
                            .frame(width: 56, height: 56)
                            .background(Circle().fill(Theme.tint))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.account?.displayName ?? "Telegram")
                                .font(.sc(20, .semibold, relativeTo: .title3))
                                .foregroundStyle(Theme.label)
                            Text(accountSubtitle)
                                .font(.scSub)
                                .foregroundStyle(app.subscriptionUsable ? Theme.label2 : Theme.red)
                        }
                        .lineLimit(1)
                    }
                    .padding(.vertical, 6)
                }
            } else {
                Button { app.showLogin = true } label: {
                    SettingsRow(icon: "paperplane.fill", color: Theme.telegram, title: "Войти через Telegram",
                                subtitle: "Подписка и резерв подтянутся сами")
                }
            }
        }
    }

    private var initial: String {
        let name = app.account?.displayName ?? "S"
        return String(name.trimmingCharacters(in: CharacterSet(charactersIn: "@")).prefix(1)).uppercased()
    }

    private var accountSubtitle: String {
        if app.needsSubscription { return "Подписки пока нет" }
        let sub = app.subscription
        if !sub.isActive { return sub.status == .limited ? "Трафик закончился" : "Подписка закончилась" }
        if let days = sub.daysLeft { return "Подписка ещё \(Format.days(days))" }
        return "Подписка бессрочная"
    }

    private var subscriptionValue: String {
        if app.needsSubscription { return "нет" }
        let sub = app.subscription
        if !sub.isActive { return sub.status == .limited ? "нет трафика" : "закончилась" }
        if let days = sub.daysLeft { return Format.days(days) }
        return "бессрочно"
    }

    private var devicesValue: String {
        let n = app.subscription.devices.count
        return app.subscription.deviceLimit.map { "\(n) из \($0)" } ?? "\(n)"
    }

    private var exceptionsValue: String? {
        let n = (vpnRaw + "\n" + directRaw).split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
        return n > 0 ? "\(n)" : nil
    }
}

// MARK: - Строки

/// Строка настроек: цветная иконка, заголовок, подпись, значение.
struct SettingsRow: View {
    let icon: String
    let color: Color
    var foreground: Color = .white
    let title: String
    var subtitle: String? = nil
    var value: String? = nil
    var titleColor: Color = Theme.label
    var external = false
    var loading = false

    var body: some View {
        HStack(spacing: 14) {
            SquareIcon(systemName: icon, color: color, foreground: foreground)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).foregroundStyle(titleColor)
                if let subtitle {
                    Text(subtitle).font(.scFoot).foregroundStyle(Theme.label2)
                }
            }
            .lineLimit(1)
            Spacer(minLength: 8)
            if let value {
                Text(value).foregroundStyle(Theme.label2).monospacedDigit().lineLimit(1)
            }
            if loading { ProgressView() }
            if external {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.label3)
            }
        }
        .contentShape(Rectangle())
    }
}

struct SettingsLabel: View {
    let icon: String
    let color: Color
    let title: String
    var body: some View {
        HStack(spacing: 14) {
            SquareIcon(systemName: icon, color: color)
            Text(title).foregroundStyle(Theme.label).lineLimit(1)
        }
    }
}

// MARK: - Оформление

struct AppearanceView: View {
    @AppStorage(SettingsKey.appearance) private var appearance: AppAppearance = .system

    var body: some View {
        List {
            Section {
                HStack(spacing: 10) {
                    ForEach([AppAppearance.light, .dark, .system]) { option in
                        ThemeCard(option: option, selected: appearance == option) { set(option) }
                    }
                }
                .padding(.vertical, 10)
            } footer: {
                Text("«Как в системе» — светлое днём и тёмное вечером, как настроено в iPhone.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Оформление")
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.selection, trigger: appearance)
    }

    private func set(_ option: AppAppearance) {
        guard option != appearance else { return }
        AppearanceController.crossfade {
            appearance = option
            AppearanceController.apply(option)
        }
    }
}

private struct ThemeCard: View {
    let option: AppAppearance
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                preview
                    .frame(width: 74, height: 116)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.separator, lineWidth: 0.5))
                    .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous)
                        .strokeBorder(Theme.tint, lineWidth: 2.5)
                        .padding(-4)
                        .opacity(selected ? 1 : 0))
                Text(option.title)
                    .font(.sc(13, .medium, relativeTo: .footnote))
                    .foregroundStyle(Theme.label)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                ZStack {
                    Circle().strokeBorder(selected ? Theme.tint : Theme.label3, lineWidth: 1.5)
                    if selected {
                        Circle().fill(Theme.tint)
                        Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.onTint)
                    }
                }
                .frame(width: 22, height: 22)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle(scale: 0.95))
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: selected)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var preview: some View {
        switch option {
        case .light: MiniScreen(dark: false)
        case .dark: MiniScreen(dark: true)
        case .system:
            ZStack {
                MiniScreen(dark: false)
                MiniScreen(dark: true)
                    .mask(HStack(spacing: 0) { Color.clear; Color.black })
            }
        }
    }
}

/// Маленький экран-образец темы.
private struct MiniScreen: View {
    let dark: Bool
    var body: some View {
        ZStack {
            (dark ? Color.black : Color(hex: 0xF2F2F7))
            VStack(spacing: 10) {
                Circle()
                    .fill(dark ? Color(hex: 0x2C2C2E) : .white)
                    .frame(width: 32, height: 32)
                    .shadow(color: .black.opacity(dark ? 0.5 : 0.12), radius: 4, y: 2)
                    .overlay(Image(systemName: "power").font(.system(size: 12, weight: .bold)).foregroundStyle(Color(hex: 0x8E8E93)))
                Capsule().fill(dark ? Color(hex: 0x3A3A3C) : Color(hex: 0xD1D1D6)).frame(width: 34, height: 4)
                Capsule().fill(dark ? Color(hex: 0x1C1C1E) : .white).frame(width: 52, height: 12)
            }
        }
    }
}

// MARK: - Дополнительно

struct AdvancedView: View {
    @Environment(AppModel.self) private var app
    @AppStorage(SettingsKey.transport) private var transport: TransportPreference = .auto
    @AppStorage(SettingsKey.energySaver) private var energySaver = true

    var body: some View {
        List {
            Section {
                ForEach(TransportPreference.allCases) { option in
                    Button { transport = option } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.title).foregroundStyle(Theme.label)
                                Text(option.subtitle).font(.scFoot).foregroundStyle(Theme.label2)
                            }
                            Spacer()
                            CheckIcon(on: transport == option)
                        }
                        .contentShape(Rectangle())
                    }
                }
            } header: {
                Text("Способ подключения")
            } footer: {
                Text("Применится при следующем подключении или смене сервера.")
            }

            Section {
                Toggle(isOn: $energySaver) {
                    SettingsLabel(icon: "leaf.fill", color: Theme.green, title: "Экономия заряда")
                }
            } footer: {
                Text("Реже проверяет связь и обновляет подписку в фоне. Переключение при смене сети может занять чуть дольше.")
            }

            Section {
                SettingsRow(icon: "info", color: Theme.gray, title: "Версия", value: Config.version)
                NavigationLink(value: SettingsRoute.diagnostics) {
                    SettingsRow(icon: "waveform.path.ecg", color: Theme.gray, title: "Диагностика и журналы")
                }
                Button {
                    UIPasteboard.general.string = app.supportReport()
                    app.showToast("Отчёт скопирован — отправьте его в поддержку", icon: "doc.on.doc.fill", tone: .good)
                } label: {
                    SettingsRow(icon: "doc.on.doc.fill", color: Theme.gray, title: "Скопировать отчёт")
                }
                NavigationLink(value: SettingsRoute.selfTest) {
                    SettingsRow(icon: "checkmark.shield.fill", color: Theme.gray, title: "Проверка VPN-профиля")
                }
            } footer: {
                Text("Отчёт — технические подробности для поддержки. Личные данные и история сайтов в него не попадают.")
            }
        }
        .listStyle(.insetGrouped)
        .toggleStyle(SwitchToggleStyle(tint: Theme.tint))
        .navigationTitle("Дополнительно")
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.selection, trigger: transport)
    }
}

// MARK: - Исключения

enum ExceptionTarget: String, CaseIterable, Identifiable {
    case direct, vpn
    var id: String { rawValue }
}

struct ExceptionsView: View {
    @Environment(AppModel.self) private var app
    @AppStorage(SettingsKey.vpnDomains) private var vpnRaw = ""
    @AppStorage(SettingsKey.directDomains) private var directRaw = ""
    @State private var adding: ExceptionTarget?
    @State private var newDomain = ""

    var body: some View {
        List {
            section(.direct, header: "Всегда без VPN",
                    footer: "Эти сайты всегда открываются напрямую — например, банк, который не любит зарубежные адреса. Поддомены тоже.")
            section(.vpn, header: "Всегда через VPN",
                    footer: "Эти сайты всегда открываются через VPN, даже если они российские.")
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Исключения")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Добавить сайт", isPresented: Binding(get: { adding != nil }, set: { if !$0 { adding = nil } })) {
            TextField("example.com", text: $newDomain)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            Button("Добавить") { add() }
            Button("Отмена", role: .cancel) { newDomain = "" }
        } message: {
            Text(adding == .vpn ? "Будет открываться только через VPN." : "Будет открываться без VPN.")
        }
        .onChange(of: vpnRaw) { app.settingsChanged() }
        .onChange(of: directRaw) { app.settingsChanged() }
    }

    private func section(_ target: ExceptionTarget, header: String, footer: String) -> some View {
        Section {
            ForEach(domains(target), id: \.self) { domain in
                Text(domain).foregroundStyle(Theme.label)
            }
            .onDelete { offsets in
                var list = domains(target)
                list.remove(atOffsets: offsets)
                setDomains(list, for: target)
            }
            Button {
                newDomain = ""
                adding = target
            } label: {
                Label("Добавить сайт", systemImage: "plus.circle.fill")
                    .foregroundStyle(Theme.ink)
            }
        } header: {
            Text(header)
        } footer: {
            Text(footer)
        }
    }

    private func domains(_ t: ExceptionTarget) -> [String] {
        (t == .vpn ? vpnRaw : directRaw).split(separator: "\n").map(String.init)
    }

    private func setDomains(_ list: [String], for t: ExceptionTarget) {
        let raw = list.joined(separator: "\n")
        if t == .vpn { vpnRaw = raw } else { directRaw = raw }
    }

    private func normalized(_ s: String) -> String? {
        var d = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let r = d.range(of: "://") { d = String(d[r.upperBound...]) }
        if let slash = d.firstIndex(of: "/") { d = String(d[..<slash]) }
        guard d.contains("."), !d.contains(" "), d.count >= 3 else { return nil }
        return d
    }

    private func add() {
        defer { newDomain = "" }
        guard let target = adding, let d = normalized(newDomain) else {
            if !newDomain.trimmingCharacters(in: .whitespaces).isEmpty {
                app.showToast("Не похоже на адрес сайта — например, sberbank.ru", icon: "exclamationmark.circle.fill", tone: .bad)
            }
            return
        }
        var list = domains(target)
        if !list.contains(d) { list.append(d) }
        withAnimation { setDomains(list, for: target) }
    }
}
