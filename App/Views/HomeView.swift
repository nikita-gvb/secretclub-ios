import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        PageScroll {
            PageHeader(title: "SecretClub") {
                NetworkChip(mode: app.networkMode)
            }
            ConnectionHero()
            if let error = app.vpn.lastError { errorCard(error) }
            connectionSection
            subscriptionSection
            if !app.isDemo {
                Text("Тестовая сборка \(Config.version). Ядро Xray ещё не подключено — кнопка поднимает пробный туннель.")
                    .font(.scFoot)
                    .foregroundStyle(Theme.label3)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 24)
                    .padding(.horizontal, 12)
            }
        }
    }

    private var connectionSection: some View {
        SCSection(header: "Подключение") {
            Button { app.selectedTab = .locations } label: {
                if let route = app.activeRoute {
                    SCRow(title: route.country, subtitle: routeLine(route), chevron: true) {
                        Flag(code: route.countryCode)
                    } trailing: {
                        PingLabel(ms: route.ping)
                    }
                } else {
                    SCRow(title: "Локация", value: "—", chevron: true) { CellIcon(systemName: "globe") }
                }
            }
            .buttonStyle(RowButtonStyle())
        }
    }

    private func routeLine(_ route: Route) -> String {
        app.autoMode ? "Авто · \(route.group.title)" : "\(route.group.title) · \(route.transport.title)"
    }

    private var subscriptionSection: some View {
        let sub = app.subscription
        return SCSection(header: "Подписка") {
            Button { app.selectedTab = .subscription } label: {
                SCRow(title: sub.isActive ? "Активна" : "Закончилась",
                      value: sub.isActive ? "\(sub.daysLeft) \(Format.plural(sub.daysLeft, "день", "дня", "дней"))" : "Продлить",
                      chevron: true) {
                    CellIcon(systemName: "creditcard")
                }
            }
            .buttonStyle(RowButtonStyle())
        }
    }

    private func errorCard(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.orange)
            Text(text).font(.scSub).foregroundStyle(Theme.label)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.rCell, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.rCell, style: .continuous).strokeBorder(Theme.orange.opacity(0.28), lineWidth: 0.5))
        .padding(.top, 12)
    }
}

/// Главная карточка: статус, время подключения, трафик и одна кнопка.
struct ConnectionHero: View {
    @Environment(AppModel.self) private var app

    private var state: VPNController.State { app.vpn.state }
    private var isOn: Bool { state == .connected }
    private var isBusy: Bool { state == .connecting || state == .disconnecting }

    private var pill: (String, Color) {
        switch state {
        case .connected: return ("Защищено", Theme.green)
        case .connecting: return ("Подключаемся", Theme.orange)
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
                    Text(isOn || state == .connecting ? "Отключить" : "Подключить")
                }
            }
            .buttonStyle(.sc(isOn || state == .connecting ? .secondary : .primary))
            .sensoryFeedback(.impact(weight: .medium), trigger: state)
        }
        .heroCard()
        .animation(.spring(duration: 0.35), value: state)
    }

    private var subline: String {
        guard let route = app.activeRoute else { return "Выберите локацию" }
        if isOn { return "\(route.flag) \(route.country) · \(route.transport.title)" }
        return "\(route.flag) \(route.country) · \(app.autoMode ? "авто" : route.transport.title)"
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
