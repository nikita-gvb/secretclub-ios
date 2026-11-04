import SwiftUI

struct LocationsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    @State private var showReserveLink = false

    var body: some View {
        PageScroll {
            PageHeader(title: "Локации") {
                Group {
                    if app.isPinging {
                        ProgressView().tint(Theme.tint).frame(width: 40, height: 40)
                    } else {
                        RoundIconButton(systemName: "speedometer", size: 40) {
                            Task { await app.pingAll() }
                        }
                        .disabled(!app.canPing)
                        .opacity(app.canPing ? 1 : 0.4)
                        .accessibilityLabel("Проверить пинг")
                    }
                }
                .alignmentGuide(.lastTextBaseline) { d in d[.bottom] - 8 }
            }
            autoOption
            if app.routes.isEmpty {
                emptyState
            }
            ForEach(RouteGroup.allCases) { group in
                if app.routes.contains(where: { $0.group == group }) {
                    section(group)
                }
            }
            if !app.routes.isEmpty && !app.hasReserveRoutes {
                reservePlaceholder
            }
            if app.vpn.state == .connected && !app.isDemo {
                Text("Пока VPN включён, пинг показывает время до самого сервера — замер идёт мимо туннеля.")
                    .font(.scFoot)
                    .foregroundStyle(Theme.label3)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 18)
                    .padding(.horizontal, 12)
            }
        }
        .refreshable {
            await app.refreshSubscription()
            await app.pingAll()
        }
        .task { await app.pingIfStale() }
        .sheet(isPresented: $showReserveLink) { PasteLinkSheet(reserve: true) }
    }

    /// Резервного подключения ещё нет или в нём закончился трафик.
    @ViewBuilder private var reservePlaceholder: some View {
        let group = RouteGroup.reserve
        if let reserve = app.reserve {
            SCSection(header: group.title, footer: group.subtitle) {
                Button { openURL(Config.botURL(start: "traffic")) } label: {
                    SCRow(title: reserve.status.isUsable ? "Серверы не загрузились" : reserve.status.title,
                          subtitle: reserve.status.isUsable ? app.reserveError : "Докупите трафик в боте", chevron: true) {
                        CellIcon(systemName: group.icon, color: Theme.orange)
                    }
                }
                .buttonStyle(RowButtonStyle())
            }
        } else if let account = app.account, account.consentAccepted {
            SCSection(header: group.title, footer: group.subtitle) {
                Button { Task { await app.createReserve() } } label: {
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
            SCSection(header: group.title, footer: group.subtitle) {
                Button { showReserveLink = true } label: {
                    SCRow(title: "Добавить ссылку", chevron: true) { CellIcon(systemName: "link") }
                }
                .buttonStyle(RowButtonStyle())
            }
        }
    }

    private var autoOption: some View {
        Button {
            app.selectAuto()
        } label: {
            HStack(spacing: 12) {
                CellIcon(systemName: "sparkles", color: Theme.tint, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Авто").font(.scHeadline).foregroundStyle(Theme.label)
                    Text("Проверит сеть и подключит к самому быстрому рабочему серверу. Резерв — только если остальное не работает.")
                        .font(.scFoot)
                        .foregroundStyle(Theme.label2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                CheckMark(on: app.autoMode)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(app.autoMode ? Theme.tint.opacity(0.1) : Theme.cell.opacity(0.9), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(app.autoMode ? Theme.tint.opacity(0.75) : Theme.border, lineWidth: app.autoMode ? 1 : 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.2), value: app.autoMode)
    }

    private var emptyState: some View {
        SCSection(footer: app.refreshError ?? "Потяните вниз, чтобы обновить подписку.") {
            SCRow(title: app.isRefreshing ? "Загружаем серверы…" : "Серверы не загружены") {
                CellIcon(systemName: "tray")
            } trailing: {
                if app.isRefreshing { ProgressView() }
            }
        }
    }

    private func section(_ group: RouteGroup) -> some View {
        let items = app.routes.filter { $0.group == group }
        return SCSection(header: group.title, footer: group.subtitle) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, route in
                if index > 0 { SCDivider(inset: 58) }
                RouteRow(route: route,
                         pinging: app.pingingIDs.contains(route.id),
                         selected: !app.autoMode && app.selectedRouteID == route.id,
                         connected: app.vpn.state == .connected && app.connectedRouteID == route.id) {
                    app.select(route)
                }
            }
        }
    }
}

struct RouteRow: View {
    let route: Route
    var pinging = false
    let selected: Bool
    var connected = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            SCRow(title: route.title, subtitle: route.detail) {
                Flag(emoji: route.emoji)
            } trailing: {
                if pinging {
                    ProgressView().controlSize(.small).tint(Theme.label2).frame(minWidth: 40, alignment: .trailing)
                } else if route.unavailable {
                    Text("нет ответа").font(.scSub).foregroundStyle(Theme.label3)
                } else {
                    PingLabel(ms: route.ping)
                }
                Image(systemName: connected ? "checkmark.shield.fill" : "checkmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(connected ? Theme.green : Theme.tint)
                    .opacity(selected || connected ? 1 : 0)
                    .frame(width: 18)
            }
        }
        .buttonStyle(RowButtonStyle())
    }
}
