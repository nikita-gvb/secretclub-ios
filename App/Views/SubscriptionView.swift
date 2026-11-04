import SwiftUI

struct SubscriptionView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    @State private var confirmLogout = false

    var body: some View {
        PageScroll {
            PageHeader(title: "Подписка")
            hero
            if let error = app.refreshError {
                NoticeCard(text: error, icon: "exclamationmark.triangle.fill", color: Theme.orange)
            }
            devicesSection
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
            SCSection {
                Button { confirmLogout = true } label: {
                    SCRow(title: "Выйти из аккаунта", titleColor: Theme.red)
                }
                .buttonStyle(RowButtonStyle())
            }
        }
        .refreshable { await app.refreshSubscription() }
        .confirmationDialog("Выйти из аккаунта?", isPresented: $confirmLogout, titleVisibility: .visible) {
            Button("Выйти", role: .destructive) { app.logout() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("VPN отключится, ссылку на подписку нужно будет ввести заново.")
        }
    }

    private var hero: some View {
        let sub = app.subscription
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                StatusPill(text: sub.isActive ? "Активна" : "Закончилась", color: sub.isActive ? Theme.green : Theme.red)
                Spacer()
                Text(sub.plan).font(.scFoot).foregroundStyle(Theme.label2).lineLimit(1)
            }
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    if !sub.isActive {
                        Text("Подписка закончилась").font(.scTitle1).foregroundStyle(Theme.label)
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
                         value: sub.limitBytes.map { Format.bytes(max(0, $0 - sub.usedBytes)) } ?? "Безлимит",
                         hint: sub.limitBytes.map { "из \(Format.bytes($0))" } ?? "использовано \(Format.bytes(sub.usedBytes))",
                         progress: sub.limitBytes.map { Double(sub.usedBytes) / Double(max(1, $0)) })
                if let limit = sub.deviceLimit {
                    let free = max(0, limit - sub.devices.count)
                    StatTile(label: "Устройства", value: "\(sub.devices.count) из \(limit)", hint: free > 0 ? "свободно \(free)" : "мест нет")
                } else {
                    StatTile(label: "Серверов", value: "\(app.routes.count)", hint: updatedText)
                }
            }
            HStack(spacing: 10) {
                Button("Продлить") { openURL(Config.botURL) }
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

    private var updatedText: String {
        guard let date = app.meta?.updatedAt else { return "не обновлялась" }
        return "обновлено \(Format.ago(date))"
    }

    private var devicesSection: some View {
        let sub = app.subscription
        return SCSection(header: "Устройства", footer: "Отвязать устройство можно в боте.") {
            ForEach(Array(sub.devices.enumerated()), id: \.element.id) { index, device in
                if index > 0 { SCDivider() }
                SCRow(title: device.name, subtitle: device.isCurrent ? "Это устройство" : Format.lastSeen(device.lastSeen)) {
                    CellIcon(systemName: device.icon)
                }
            }
        }
    }
}
