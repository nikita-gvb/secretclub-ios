import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        PageScroll {
            PageHeader(title: "SecretClub") {
                NetworkChip(mode: app.networkMode)
            }
            if app.needsConsent {
                ConsentCard()
            } else if app.needsSubscription && app.routes.isEmpty {
                NoSubscriptionCard()
            } else {
                ConnectionHero()
            }
            if let error = app.vpn.lastError {
                NoticeCard(text: error, icon: "exclamationmark.triangle.fill", color: Theme.orange)
            } else if app.routes.isEmpty, let error = app.refreshError ?? app.accountError {
                NoticeCard(text: error, icon: "exclamationmark.triangle.fill", color: Theme.orange)
            }
            if let announce = app.meta?.announce ?? app.account?.announcement {
                NoticeCard(text: announce, icon: "megaphone.fill", color: Theme.tint)
            }
            if !app.routes.isEmpty || !app.needsConsent && !app.needsSubscription {
                connectionSection
                subscriptionSection
            }
        }
        .refreshable { await app.refreshSubscription() }
    }

    private var connectionSection: some View {
        SCSection(header: "Подключение") {
            Button { app.selectedTab = .locations } label: {
                if let route = app.activeRoute {
                    SCRow(title: route.title, subtitle: routeLine(route), chevron: true) {
                        Flag(emoji: route.emoji)
                    } trailing: {
                        PingLabel(ms: route.ping)
                    }
                } else {
                    SCRow(title: "Локация", value: app.routes.isEmpty ? "нет серверов" : "Авто", chevron: true) {
                        CellIcon(systemName: "globe")
                    }
                }
            }
            .buttonStyle(RowButtonStyle())
        }
    }

    private func routeLine(_ route: Route) -> String {
        app.autoMode ? "Авто · \(route.group.title)" : "\(route.group.title) · \(route.transportTitle)"
    }

    private var subscriptionSection: some View {
        let sub = app.subscription
        let value: String
        if !sub.isActive {
            value = "Продлить"
        } else if let days = sub.daysLeft {
            value = "\(days) \(Format.plural(days, "день", "дня", "дней"))"
        } else {
            value = "Бессрочно"
        }
        return SCSection(header: "Подписка") {
            Button { app.selectedTab = .subscription } label: {
                SCRow(title: sub.status.title, subtitle: sub.plan, value: value, chevron: true) {
                    CellIcon(systemName: "creditcard")
                }
            }
            .buttonStyle(RowButtonStyle())
            if let reserve = app.reserve {
                SCDivider()
                Button { app.selectedTab = .subscription } label: {
                    SCRow(title: "Резервное подключение",
                          subtitle: reserve.status.isUsable ? "включается, если остальное не работает" : reserve.status.title,
                          value: reserve.leftBytes.map(Format.bytes), chevron: true) {
                        CellIcon(systemName: "lifepreserver")
                    }
                }
                .buttonStyle(RowButtonStyle())
            }
        }
    }
}

struct NoticeCard: View {
    let text: String
    let icon: String
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(color)
            Text(text).font(.scSub).foregroundStyle(Theme.label)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.rCell, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.rCell, style: .continuous).strokeBorder(color.opacity(0.28), lineWidth: 0.5))
        .padding(.top, 12)
    }
}

/// Главная карточка: статус, время подключения, трафик и одна кнопка.
struct ConnectionHero: View {
    @Environment(AppModel.self) private var app

    private var state: VPNController.State { app.vpn.state }
    private var isOn: Bool { state == .connected }
    private var isBusy: Bool { app.vpn.isBusy }

    private var pill: (String, Color) {
        switch state {
        case .connected: return ("Защищено", Theme.green)
        case .connecting, .preparing: return ("Подключаемся", Theme.orange)
        case .disconnecting: return ("Отключаемся", Theme.orange)
        case .disconnected: return ("Выключен", Theme.gray)
        case .invalid: return ("Нужна настройка", Theme.red)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                StatusPill(text: pill.0, color: pill.1)
                Spacer()
                Text(app.autoMode ? "Авто" : "Вручную")
                    .font(.scFoot)
                    .foregroundStyle(Theme.label2)
            }
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    if isOn, let since = app.vpn.connectedSince {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            HeroNumber(text: Format.duration(context.date.timeIntervalSince(since)), size: 44)
                        }
                    } else {
                        Text(isBusy ? pill.0 + "…" : "VPN выключен")
                            .font(.scTitle1)
                            .tracking(-0.5)
                            .foregroundStyle(Theme.label)
                    }
                    Text(subline)
                        .font(.scSub)
                        .foregroundStyle(Theme.label2)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                badge
            }
            if isOn {
                HStack(spacing: 8) {
                    StatTile(label: "Получено", value: Format.bytes(app.vpn.bytesIn))
                    StatTile(label: "Отправлено", value: Format.bytes(app.vpn.bytesOut))
                    StatTile(label: "Пинг", value: Ping.text(app.activeRoute?.ping))
                }
            }
            Button {
                Task { await app.toggleConnection() }
            } label: {
                HStack(spacing: 8) {
                    if isBusy { ProgressView().tint(isOn ? Theme.label : Theme.onTint) }
                    Text(isOn || state == .connecting ? "Отключить" : (state == .preparing ? "Подключаемся" : "Подключить"))
                }
            }
            .buttonStyle(.sc(isOn || state == .connecting ? .secondary : .primary))
            .disabled(state == .preparing || state == .disconnecting)
            .sensoryFeedback(.impact(weight: .medium), trigger: state)
        }
        .heroCard()
        .animation(.spring(duration: 0.35), value: state)
    }

    private var subline: String {
        if let phase = app.phase, state == .preparing { return phase }
        guard let route = app.activeRoute else { return app.routes.isEmpty ? "Серверы не загружены" : "Выберите локацию" }
        if isOn || state == .connecting { return "\(route.emoji) \(route.title) · \(route.shortDetail)" }
        return "\(route.emoji) \(route.title) · \(app.autoMode ? "авто" : route.shortDetail)"
    }

    @ViewBuilder private var badge: some View {
        if isBusy {
            ProgressView()
                .tint(Theme.orange)
                .frame(width: 56, height: 56)
                .background(Theme.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        } else if isOn {
            HeroBadge(systemName: "checkmark.shield", color: Theme.green)
        } else {
            HeroBadge(systemName: "power", color: Theme.label2)
        }
    }
}

/// Компактный индикатор сети в шапке.
struct NetworkChip: View {
    let mode: NetworkMode
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(mode.color).frame(width: 7, height: 7)
            Text(mode.short)
        }
        .font(.onest(13, .semibold, relativeTo: .footnote))
        .foregroundStyle(Theme.label)
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(Theme.fill2, in: Capsule())
        .alignmentGuide(.lastTextBaseline) { d in d[.bottom] - 6 }
    }
}
