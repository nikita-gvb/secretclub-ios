import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    header
                    ConnectButton(state: app.vpn.state) {
                        Task { await app.toggleConnection() }
                    }
                    .padding(.top, 4)
                    status
                    modeChip
                    if let route = app.activeRoute { routeCard(route) }
                    stats
                    subscriptionStrip
                    if let error = app.vpn.lastError { errorBanner(error) }
                    if !app.isDemo { testBuildNote }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
            .scrollIndicators(.hidden)
            .background(AppBackground())
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            LogoMark(size: 34)
            Text("SecretClub").font(.title3.weight(.bold))
            Spacer()
            NetworkPill(mode: app.networkMode)
        }
    }

    private var statusTitle: String {
        switch app.vpn.state {
        case .connected: return "Защищено"
        case .connecting: return "Подключаемся…"
        case .disconnecting: return "Отключаемся…"
        case .disconnected: return "Не подключено"
        case .invalid: return "Нужна настройка"
        }
    }

    private var status: some View {
        VStack(spacing: 6) {
            Text(statusTitle)
                .font(.title2.weight(.bold))
                .foregroundStyle(app.vpn.state == .connected ? Theme.accentSoft : Color.primary)
            Group {
                if app.vpn.state == .connected, let since = app.vpn.connectedSince {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(Format.duration(context.date.timeIntervalSince(since)))
                    }
                } else {
                    Text("Нажмите, чтобы подключиться")
                }
            }
            .font(.subheadline.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private var modeChip: some View {
        Button {
            app.selectedTab = .locations
        } label: {
            HStack(spacing: 8) {
                Image(systemName: app.autoMode ? "sparkles" : "hand.tap.fill")
                    .foregroundStyle(Theme.accent)
                Text(app.autoMode ? "Авто" : "Вручную").fontWeight(.semibold)
                Text("·").foregroundStyle(.secondary)
                Text(app.autoMode ? "лучший маршрут" : (app.activeRoute?.group.title ?? ""))
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(Theme.accent.opacity(0.14), in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.35)))
        }
        .buttonStyle(.plain)
    }

    private func routeCard(_ route: Route) -> some View {
        Button {
            app.selectedTab = .locations
        } label: {
            HStack(spacing: 14) {
                FlagBadge(code: route.countryCode, size: 46)
                VStack(alignment: .leading, spacing: 5) {
                    Text(route.country).font(.headline)
                    HStack(spacing: 6) {
                        GroupTag(group: route.group)
                        Text(route.transport.title).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                PingLabel(ms: route.ping)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .card()
        }
        .buttonStyle(.plain)
    }

    private var stats: some View {
        HStack(spacing: 12) {
            StatTile(icon: "arrow.down", tint: Theme.success, title: "Получено", value: Format.bytes(app.vpn.bytesIn))
            StatTile(icon: "arrow.up", tint: Theme.accentSoft, title: "Отправлено", value: Format.bytes(app.vpn.bytesOut))
        }
    }

    private var subscriptionStrip: some View {
        let sub = app.subscription
        return Button {
            app.selectedTab = .subscription
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(sub.isActive ? "Подписка активна" : "Подписка закончилась", systemImage: "crown.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(sub.isActive ? Theme.accentSoft : Theme.danger)
                    Spacer()
                    Text("ещё \(sub.daysLeft) \(Format.plural(sub.daysLeft, "день", "дня", "дней"))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: sub.progress)
                    .tint(Theme.accent)
            }
            .card()
        }
        .buttonStyle(.plain)
    }

    private func errorBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
            Text(text).font(.footnote)
        }
        .card(padding: 14)
    }

    private var testBuildNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "hammer.fill").foregroundStyle(Theme.accentSoft)
            Text("Тестовая сборка \(Config.version). Ядро Xray ещё не подключено: кнопка поднимает пробный туннель, трафик идёт как обычно.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .card(padding: 14)
    }
}

struct StatTile: View {
    let icon: String
    let tint: Color
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 12) {
            IconTile(systemName: icon, color: tint, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.headline.monospacedDigit())
            }
            Spacer(minLength: 0)
        }
        .card(padding: 14)
    }
}

struct ConnectButton: View {
    let state: VPNController.State
    let action: () -> Void
    @State private var pulse = false

    private var isOn: Bool { state == .connected }
    private var isBusy: Bool { state == .connecting || state == .disconnecting }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(Theme.accent.opacity(isOn ? 0.14 : 0.05))
                    .frame(width: 252, height: 252)
                    .scaleEffect(pulse && isOn ? 1.05 : 1)
                Circle()
                    .fill(Theme.accent.opacity(isOn ? 0.20 : 0.08))
                    .frame(width: 206, height: 206)
                Circle()
                    .fill(isOn ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Theme.card))
                    .frame(width: 160, height: 160)
                    .overlay(Circle().strokeBorder(isOn ? Color.white.opacity(0.25) : Theme.cardStroke, lineWidth: 1))
                    .shadow(color: Theme.accent.opacity(isOn ? 0.6 : 0), radius: 30, y: 10)
                if isBusy {
                    ProgressView()
                        .controlSize(.large)
                        .tint(Theme.accent)
                } else {
                    Image(systemName: "power")
                        .font(.system(size: 58, weight: .semibold))
                        .foregroundStyle(isOn ? Color.white : Theme.accent)
                }
            }
            .frame(width: 260, height: 260)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .animation(.spring(duration: 0.4), value: state)
        .sensoryFeedback(.impact(weight: .medium), trigger: state)
        .accessibilityLabel(isOn ? "Отключить VPN" : "Подключить VPN")
        .onAppear {
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}
