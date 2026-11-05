import SwiftUI

// MARK: - Подписка

struct SubscriptionScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    @State private var showReserveLink = false
    @State private var shownDays = 0.0

    var body: some View {
        List {
            if app.needsConsent {
                cardSection { ConsentCard() }
            } else if app.needsSubscription {
                cardSection { NoSubscriptionCard() }
            } else {
                Section { hero }
                    .listRowInsets(EdgeInsets(top: 20, leading: 20, bottom: 20, trailing: 20))
            }

            if let error = app.accountError ?? app.refreshError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.scSub)
                        .foregroundStyle(Theme.orange)
                }
            }

            if !app.needsConsent { reserveSection }

            if !app.subscription.devices.isEmpty {
                Section {
                    NavigationLink(value: SettingsRoute.devices) {
                        SettingsRow(icon: "iphone", color: Theme.blue, title: "Устройства", value: devicesValue)
                    }
                }
            }

            Section {
                Link(destination: Config.botURL) {
                    SettingsRow(icon: "paperplane.fill", color: Theme.telegram, title: "Открыть бота", external: true)
                }
                Link(destination: Config.supportURL) {
                    SettingsRow(icon: "questionmark.bubble.fill", color: Theme.gray, title: "Поддержка", external: true)
                }
            } footer: {
                Text("Продление и оплата — в Telegram-боте. После оплаты всё обновится само.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Подписка")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if app.isRefreshing {
                    ProgressView()
                } else {
                    Button { Task { await app.refreshSubscription() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Обновить")
                }
            }
        }
        .refreshable { await app.refreshSubscription() }
        .redacted(reason: isSkeleton ? .placeholder : [])
        .sheet(isPresented: $showReserveLink) { PasteLinkSheet(reserve: true) }
        .onAppear { countUp() }
        .onChange(of: app.subscription.daysLeft) { countUp() }
        .task {
            guard !app.isDemo, app.hasSession else { return }
            if (app.meta?.updatedAt ?? .distantPast) < Date().addingTimeInterval(-120) {
                await app.refreshSubscription()
            }
        }
    }

    private var isSkeleton: Bool {
        app.isRefreshing && app.meta == nil && !app.subscription.fromAccount
    }

    private func countUp() {
        let target = Double(app.subscription.isActive ? (app.subscription.daysLeft ?? 0) : 0)
        guard target != shownDays else { return }
        withAnimation(.smooth(duration: 0.7).delay(0.15)) { shownDays = target }
    }

    @ViewBuilder
    private func cardSection<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        Section { content() }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
    }

    // MARK: Главная карточка

    private var hero: some View {
        let sub = app.subscription
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                StatusPill(text: sub.status.title, color: sub.status.color)
                Spacer(minLength: 8)
                Text(sub.plan).font(.scFoot).foregroundStyle(Theme.label2).lineLimit(1)
            }
            VStack(alignment: .leading, spacing: 4) {
                if !sub.isActive {
                    Text(inactiveTitle(sub))
                        .font(.sc(30, .bold, design: .rounded, relativeTo: .title))
                        .foregroundStyle(Theme.label)
                    Text("Продлите в Telegram — VPN включится сам")
                        .font(.scSub).foregroundStyle(Theme.label2)
                } else if sub.daysLeft != nil {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        CountingText(value: shownDays)
                            .font(.sc(56, .bold, design: .rounded, relativeTo: .largeTitle))
                            .foregroundStyle(Theme.label)
                        Text(Format.plural(Int(shownDays.rounded()), "день", "дня", "дней"))
                            .font(.sc(22, .semibold, relativeTo: .title2))
                            .foregroundStyle(Theme.label2)
                    }
                    Text(tillText(sub)).font(.scSub).foregroundStyle(Theme.label2)
                } else {
                    Text("Бессрочно")
                        .font(.sc(30, .bold, design: .rounded, relativeTo: .title))
                        .foregroundStyle(Theme.label)
                    Text(trafficText(sub)).font(.scSub).foregroundStyle(Theme.label2)
                }
            }
            ProgressBar(value: sub.isActive ? sub.progress : 0, color: sub.isActive ? Theme.tint : Theme.red)
                .padding(.vertical, 2)
            Button { openURL(Config.botLink(start: "buy")) } label: {
                Label("Продлить в Telegram", systemImage: "paperplane.fill")
            }
            .buttonStyle(.scPrimary)
            .padding(.top, 4)
            Text(updatedText)
                .font(.scCaption)
                .foregroundStyle(Theme.label3)
                .frame(maxWidth: .infinity)
        }
    }

    private func inactiveTitle(_ sub: SubscriptionInfo) -> String {
        switch sub.status {
        case .limited: return "Трафик закончился"
        case .disabled: return "Подписка отключена"
        default: return "Подписка закончилась"
        }
    }

    private func tillText(_ sub: SubscriptionInfo) -> String {
        var parts: [String] = []
        if let expires = sub.expiresAt { parts.append("до \(Format.date(expires))") }
        parts.append(trafficText(sub))
        return parts.joined(separator: " · ")
    }

    private func trafficText(_ sub: SubscriptionInfo) -> String {
        if let left = sub.leftBytes { return "осталось \(Format.bytes(left))" }
        return "безлимитный трафик"
    }

    private var updatedText: String {
        guard let date = app.meta?.updatedAt else { return "Обновляется само" }
        return "Обновлено \(Format.ago(date))"
    }

    private var devicesValue: String {
        let n = app.subscription.devices.count
        return app.subscription.deviceLimit.map { "\(n) из \($0)" } ?? "\(n)"
    }

    // MARK: Обход белых списков (резервное подключение)

    private let reserveFooter = "Резервное подключение для мобильного интернета с белыми списками. Включается само, если остальное не работает; трафик тратится, только пока оно работает."

    @ViewBuilder private var reserveSection: some View {
        if let reserve = app.reserve {
            Section {
                ReserveRow(info: reserve)
                Button { openURL(Config.botLink(start: "traffic")) } label: {
                    SettingsRow(icon: "plus", color: Theme.blue, title: "Докупить трафик", external: true)
                }
                .foregroundStyle(Theme.label)
            } header: {
                Text("Обход белых списков")
            } footer: {
                Text(reserveFooter)
            }
        } else if let account = app.account, account.consentAccepted {
            Section {
                Button {
                    Task {
                        await app.createReserve()
                        if app.reserve != nil {
                            app.showToast("Обход белых списков подключён — \(account.freeReserveMB) МБ в подарок", icon: "gift.fill", tone: .good)
                        }
                    }
                } label: {
                    SettingsRow(icon: "gift.fill", color: Theme.green,
                                title: "Получить \(account.freeReserveMB) МБ бесплатно",
                                loading: app.busyAction == "reserve")
                }
                .disabled(app.busyAction != nil)
            } header: {
                Text("Обход белых списков")
            } footer: {
                Text(reserveFooter)
            }
        } else if !app.hasSession {
            Section {
                Button { showReserveLink = true } label: {
                    SettingsRow(icon: "link", color: Theme.gray, title: "Добавить ссылку")
                }
            } header: {
                Text("Обход белых списков")
            } footer: {
                Text("Ссылку резервного подключения можно взять в боте. Или войдите через Telegram — она подтянется сама.")
            }
        }
    }
}

/// Остаток трафика резервного подключения.
private struct ReserveRow: View {
    let info: SubscriptionInfo

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "lifepreserver")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(info.status.isUsable ? Theme.ink : Theme.red)
                .frame(width: 30, height: 30)
                .background(info.status.isUsable ? Theme.tintSoft : Theme.red.opacity(0.14),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.sc(17, .semibold, relativeTo: .body)).monospacedDigit()
                    Spacer(minLength: 8)
                    if let limit = info.limitBytes {
                        Text("из \(Format.bytes(limit))").font(.scFoot).foregroundStyle(Theme.label2).monospacedDigit()
                    }
                }
                if let progress = info.trafficProgress {
                    ProgressBar(value: 1 - progress, color: info.status.isUsable ? Theme.tint : Theme.red)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var title: String {
        if !info.status.isUsable { return info.status.title }
        if let left = info.leftBytes { return "\(Format.bytes(left)) осталось" }
        return "Подключено · \(Format.bytes(info.usedBytes))"
    }
}

/// Число, которое «досчитывает» до значения при анимации.
struct CountingText: View, Animatable {
    var value: Double
    var animatableData: Double {
        get { value }
        set { value = newValue }
    }
    var body: some View {
        Text("\(Int(value.rounded()))").monospacedDigit()
    }
}

// MARK: - Устройства

struct DevicesScreen: View {
    @Environment(AppModel.self) private var app
    @State private var target: UnlinkTarget?
    @State private var unlinked = 0

    struct UnlinkTarget: Identifiable {
        let device: Device
        let reserve: Bool
        var id: String { (reserve ? "r|" : "") + device.id }
    }

    var body: some View {
        List {
            deviceSection(app.subscription, reserve: false)
            if let reserve = app.reserve, reserve.fromAccount, reserve.devices.contains(where: { !$0.isCurrent }) {
                deviceSection(reserve, reserve: true)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Устройства")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await app.refreshSubscription() }
        .sensoryFeedback(.success, trigger: unlinked)
        .confirmationDialog("Отвязать устройство?",
                            isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } }),
                            titleVisibility: .visible, presenting: target) { target in
            Button("Отвязать", role: .destructive) { unlink(target) }
            Button("Отмена", role: .cancel) {}
        } message: { target in
            Text("На «\(target.device.name)» VPN выключится, а место освободится для другого устройства.")
        }
    }

    private func unlink(_ target: UnlinkTarget) {
        Task {
            await app.unlink(target.device, reserve: target.reserve)
            let list = target.reserve ? (app.reserve?.devices ?? []) : app.subscription.devices
            if app.accountError == nil, !list.contains(where: { $0.id == target.device.id }) {
                unlinked += 1
                app.showToast("\(target.device.name) отвязан — место освободилось", icon: "checkmark", tone: .good)
            }
        }
    }

    @ViewBuilder
    private func deviceSection(_ sub: SubscriptionInfo, reserve: Bool) -> some View {
        let devices = sub.devices.sorted { $0.isCurrent && !$1.isCurrent }
        Section {
            ForEach(devices) { device in
                row(device, canUnlink: sub.fromAccount && !device.isCurrent, reserve: reserve)
            }
        } header: {
            if reserve { Text("Обход белых списков") }
        } footer: {
            Text(footer(sub))
        }
    }

    private func row(_ device: Device, canUnlink: Bool, reserve: Bool) -> some View {
        HStack(spacing: 14) {
            SquareIcon(systemName: device.icon, color: device.isCurrent ? Theme.blue : Theme.gray)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.name).foregroundStyle(Theme.label)
                if let sub = subtitle(device) {
                    Text(sub).font(.scFoot).foregroundStyle(Theme.label2)
                }
            }
            .lineLimit(1)
            Spacer(minLength: 8)
            if device.isCurrent {
                Chip(text: "вы здесь")
            } else if canUnlink {
                if app.busyAction == "device:\(device.id)" {
                    ProgressView()
                } else {
                    Button("Отвязать") { target = UnlinkTarget(device: device, reserve: reserve) }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Theme.red)
                        .disabled(app.busyAction != nil)
                }
            }
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if canUnlink {
                Button("Отвязать", role: .destructive) { target = UnlinkTarget(device: device, reserve: reserve) }
            }
        }
    }

    private func subtitle(_ device: Device) -> String? {
        if device.isCurrent { return "Это устройство" }
        var parts: [String] = []
        if let seen = device.lastSeen { parts.append(Format.lastSeen(seen)) }
        if let detail = device.detail { parts.append(detail) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func footer(_ sub: SubscriptionInfo) -> String {
        guard sub.fromAccount else { return "Войдите через Telegram, чтобы видеть и отвязывать устройства." }
        let limit = sub.deviceLimit.map { "Можно подключить до \($0) \(Format.plural($0, "устройства", "устройств", "устройств")). " } ?? ""
        return limit + "Отвязанное освободит место — на нём VPN выключится."
    }
}
