import SwiftUI

struct SubscriptionView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    @State private var unlinkTarget: UnlinkTarget?
    @State private var showReserveLink = false

    struct UnlinkTarget: Identifiable {
        let device: Device
        let reserve: Bool
        var id: String { (reserve ? "r|" : "") + device.id }
    }

    var body: some View {
        PageScroll {
            PageHeader(title: "Подписка") {
                if app.isRefreshing {
                    ProgressView().tint(Theme.tint).frame(width: 40, height: 40)
                        .alignmentGuide(.lastTextBaseline) { d in d[.bottom] - 8 }
                }
            }
            if app.needsConsent {
                ConsentCard()
            } else if app.needsSubscription {
                NoSubscriptionCard()
            } else {
                hero
            }
            if let error = app.accountError ?? app.refreshError {
                NoticeCard(text: error, icon: "exclamationmark.triangle.fill", color: Theme.orange)
            }
            if !app.needsConsent {
                reserveSection
                devicesSection(app.subscription, header: "Устройства", reserve: false)
            }
            SCSection(footer: "Продление и оплата — в Telegram-боте. После оплаты данные обновятся сами.") {
                Button { openURL(Config.botURL) } label: {
                    SCRow(title: "Открыть бота", chevron: true) { CellIcon(systemName: "paperplane") }
                }
                .buttonStyle(RowButtonStyle())
                SCDivider()
                Button { openURL(Config.supportURL) } label: {
                    SCRow(title: "Поддержка", chevron: true) { CellIcon(systemName: "questionmark.bubble") }
                }
                .buttonStyle(RowButtonStyle())
            }
        }
        .refreshable { await app.refreshSubscription() }
        .confirmationDialog("Отвязать устройство?",
                            isPresented: Binding(get: { unlinkTarget != nil }, set: { if !$0 { unlinkTarget = nil } }),
                            titleVisibility: .visible, presenting: unlinkTarget) { target in
            Button("Отвязать", role: .destructive) {
                Task { await app.unlink(target.device, reserve: target.reserve) }
            }
            Button("Отмена", role: .cancel) {}
        } message: { target in
            Text("«\(target.device.name)» пропадёт из списка и освободит место для другого устройства.")
        }
        .sheet(isPresented: $showReserveLink) { PasteLinkSheet(reserve: true) }
    }

    // MARK: - Основная подписка

    private var hero: some View {
        let sub = app.subscription
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                StatusPill(text: sub.status.title, color: sub.status.color)
                Spacer()
                Text(sub.plan).font(.scFoot).foregroundStyle(Theme.label2).lineLimit(1)
            }
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    if !sub.isActive {
                        Text(inactiveTitle(sub)).font(.scTitle1).foregroundStyle(Theme.label)
                        Text("Продлите в боте — VPN включится сам").font(.scSub).foregroundStyle(Theme.label2)
                    } else if let days = sub.daysLeft, let expires = sub.expiresAt {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            HeroNumber(text: "\(days)")
                            Text(Format.plural(days, "день", "дня", "дней"))
                                .font(.scTitle3)
                                .foregroundStyle(Theme.label2)
                        }
                        Text("до \(Format.date(expires))").font(.scSub).foregroundStyle(Theme.label2)
                    } else {
                        Text("Бессрочно").font(.scTitle1).foregroundStyle(Theme.label)
                        Text("Срок подписки не ограничен").font(.scSub).foregroundStyle(Theme.label2)
                    }
                }
                Spacer(minLength: 0)
                HeroBadge(systemName: sub.isActive ? "checkmark.shield" : "xmark.shield", color: sub.isActive ? Theme.green : Theme.red)
            }
            HStack(spacing: 8) {
                StatTile(label: "Трафик",
                         value: sub.leftBytes.map(Format.bytes) ?? "Безлимит",
                         hint: sub.limitBytes.map { "из \(Format.bytes($0))" } ?? "использовано \(Format.bytes(sub.usedBytes))",
                         progress: sub.trafficProgress)
                if let limit = sub.deviceLimit {
                    let used = sub.devices.count
                    let free = max(0, limit - used)
                    StatTile(label: "Устройства", value: "\(used) из \(limit)", hint: free > 0 ? "свободно \(free)" : "мест нет")
                } else {
                    StatTile(label: "Серверов", value: "\(app.routes.filter { $0.group != .reserve }.count)", hint: updatedText)
                }
            }
            HStack(spacing: 10) {
                Button("Продлить") { openURL(Config.botLink(start: "buy")) }
                    .buttonStyle(.scPrimary)
                if app.isRefreshing {
                    ProgressView().tint(Theme.tint).frame(width: 50, height: 50)
                } else {
                    RoundIconButton(systemName: "arrow.clockwise") {
                        Task { await app.refreshSubscription() }
                    }
                    .accessibilityLabel("Обновить")
                }
            }
        }
        .heroCard()
    }

    private func inactiveTitle(_ sub: SubscriptionInfo) -> String {
        switch sub.status {
        case .limited: return "Трафик закончился"
        case .disabled: return "Подписка отключена"
        default: return "Подписка закончилась"
        }
    }

    private var updatedText: String {
        guard let date = app.meta?.updatedAt else { return "не обновлялась" }
        return "обновлено \(Format.ago(date))"
    }

    // MARK: - Резервное подключение

    private let reserveFooter = "Выручит, когда обычные серверы недоступны. Трафик ограничен, поэтому «Авто» включает его только в крайнем случае."

    @ViewBuilder private var reserveSection: some View {
        if let reserve = app.reserve {
            SCSection(header: "Резервное подключение", footer: reserveFooter) {
                ReserveSummary(info: reserve)
                SCDivider()
                Button { openURL(Config.botLink(start: "traffic")) } label: {
                    SCRow(title: "Докупить трафик", chevron: true) { CellIcon(systemName: "plus") }
                }
                .buttonStyle(RowButtonStyle())
            }
        } else if let account = app.account, account.consentAccepted {
            SCSection(header: "Резервное подключение", footer: reserveFooter) {
                Button {
                    Task { await app.createReserve() }
                } label: {
                    SCRow(title: "Подключить бесплатно", subtitle: "\(account.freeReserveMB) МБ в подарок") {
                        CellIcon(systemName: "gift", color: Theme.tint)
                    } trailing: {
                        if app.busyAction == "reserve" { ProgressView() }
                    }
                }
                .buttonStyle(RowButtonStyle())
                .disabled(app.busyAction != nil)
            }
        } else if !app.hasSession {
            SCSection(header: "Резервное подключение",
                      footer: "Ссылку резервного подключения можно взять в боте. Или войдите через Telegram — она подтянется сама.") {
                Button { showReserveLink = true } label: {
                    SCRow(title: "Добавить ссылку", chevron: true) { CellIcon(systemName: "link") }
                }
                .buttonStyle(RowButtonStyle())
            }
        }
    }

    // MARK: - Устройства

    @ViewBuilder
    private func devicesSection(_ sub: SubscriptionInfo, header: String, reserve: Bool) -> some View {
        let devices = sub.devices.sorted { $0.isCurrent && !$1.isCurrent }
        if !devices.isEmpty {
            let title = sub.deviceLimit.map { "\(header) · \(devices.count) из \($0)" } ?? header
            SCSection(header: title,
                      footer: sub.fromAccount ? "Отвязанное устройство освободит место для нового." : "Войдите через Telegram, чтобы видеть и отвязывать устройства.") {
                ForEach(Array(devices.enumerated()), id: \.element.id) { index, device in
                    if index > 0 { SCDivider() }
                    SCRow(title: device.name, subtitle: subtitle(device)) {
                        CellIcon(systemName: device.icon)
                    } trailing: {
                        if device.isCurrent {
                            Text("Это устройство").font(.scFoot).foregroundStyle(Theme.tint)
                        } else if sub.fromAccount {
                            if app.busyAction == "device:\(device.id)" {
                                ProgressView()
                            } else {
                                Button("Отвязать") { unlinkTarget = UnlinkTarget(device: device, reserve: reserve) }
                                    .buttonStyle(.sc(.secondary, small: true))
                                    .fixedSize()
                                    .disabled(app.busyAction != nil)
                            }
                        }
                    }
                }
            }
        }
    }

    private func subtitle(_ device: Device) -> String? {
        var parts: [String] = []
        if let detail = device.detail { parts.append(detail) }
        if !device.isCurrent, let seen = device.lastSeen { parts.append(Format.lastSeen(seen)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Остаток трафика резервного подключения.
struct ReserveSummary: View {
    let info: SubscriptionInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                CellIcon(systemName: "lifepreserver", color: info.status.isUsable ? Theme.tint : Theme.red)
                VStack(alignment: .leading, spacing: 1) {
                    Text(info.status.isUsable ? "Подключено" : info.status.title)
                        .font(.scBody).foregroundStyle(Theme.label)
                    Text(detail).font(.scFoot).foregroundStyle(Theme.label2)
                }
                Spacer(minLength: 8)
                if let left = info.leftBytes {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(Format.bytes(left)).font(.onest(17, .semibold, relativeTo: .body)).foregroundStyle(Theme.label).monospacedDigit()
                        Text("осталось").font(.scFoot).foregroundStyle(Theme.label3)
                    }
                }
            }
            if let progress = info.trafficProgress {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.1))
                        Capsule().fill(info.status.isUsable ? Theme.tint : Theme.red)
                            .frame(width: geo.size.width * min(1, max(0, 1 - progress)))
                    }
                }
                .frame(height: 5)
                .padding(.leading, 42)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var detail: String {
        if let limit = info.limitBytes { return "использовано \(Format.bytes(info.usedBytes)) из \(Format.bytes(limit))" }
        return "использовано \(Format.bytes(info.usedBytes))"
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
