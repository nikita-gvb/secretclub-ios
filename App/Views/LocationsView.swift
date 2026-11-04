import SwiftUI

struct LocationsView: View {
    @Environment(AppModel.self) private var app

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
            if app.vpn.isActive && !app.isDemo {
                Text("Пока VPN включён, пинг не обновляется — он измерялся бы через сам туннель.")
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
    }

    private var autoOption: some View {
        Button {
            app.selectAuto()
        } label: {
            HStack(spacing: 12) {
                CellIcon(systemName: "sparkles", color: Theme.tint, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Авто").font(.scHeadline).foregroundStyle(Theme.label)
                    Text("Проверит сеть и подключит к самому быстрому рабочему серверу")
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
    let selected: Bool
    var connected = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            SCRow(title: route.title, subtitle: route.detail) {
                Flag(emoji: route.emoji)
            } trailing: {
                if route.unavailable {
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
