import SwiftUI

struct SubscriptionView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    @State private var confirmLogout = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    planCard
                    devicesCard
                    VStack(spacing: 12) {
                        Button {
                            openURL(Config.botURL)
                        } label: {
                            Label("Продлить в Telegram-боте", systemImage: "paperplane.fill")
                        }
                        .buttonStyle(PrimaryButtonStyle())

                        Button {
                            Task { await app.refreshNetwork() }
                        } label: {
                            Label("Обновить данные", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(SecondaryButtonStyle())

                        Button(role: .destructive) {
                            confirmLogout = true
                        } label: {
                            Text("Выйти из аккаунта")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Theme.danger)
                        }
                        .padding(.top, 4)
                    }
                    .padding(.top, 4)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 28)
            }
            .scrollIndicators(.hidden)
            .background(AppBackground())
            .navigationTitle("Подписка")
            .confirmationDialog("Выйти из аккаунта?", isPresented: $confirmLogout, titleVisibility: .visible) {
                Button("Выйти", role: .destructive) { app.logout() }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text("VPN отключится, ссылку на подписку нужно будет ввести заново.")
            }
        }
    }

    private var planCard: some View {
        let sub = app.subscription
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                HStack(spacing: 8) {
                    LogoMark(size: 26).shadow(radius: 0)
                    Text("SecretClub").font(.subheadline.weight(.semibold))
                }
                Spacer()
                Text(sub.isActive ? "Активна" : "Истекла")
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.white.opacity(0.2), in: Capsule())
            }
            Text(sub.plan)
                .font(.system(size: 34, weight: .heavy, design: .rounded))
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("до \(Format.date(sub.expiresAt))")
                    Spacer()
                    Text("ещё \(sub.daysLeft) \(Format.plural(sub.daysLeft, "день", "дня", "дней"))")
                }
                .font(.subheadline.weight(.medium))
                ProgressView(value: sub.progress)
                    .tint(.white)
            }
            Rectangle().fill(.white.opacity(0.2)).frame(height: 1)
            HStack(alignment: .top) {
                stat("Трафик", value: Format.bytes(sub.usedBytes), suffix: sub.limitBytes.map { "из \(Format.bytes($0))" } ?? "безлимит")
                Spacer()
                stat("Устройства", value: "\(sub.devices.count) из \(sub.deviceLimit)", suffix: "подключено")
            }
        }
        .foregroundStyle(.white)
        .padding(20)
        .background(
            ZStack {
                Theme.gradient
                Circle().fill(.white.opacity(0.10)).frame(width: 220, height: 220).offset(x: 130, y: -90)
                Circle().fill(.white.opacity(0.06)).frame(width: 160, height: 160).offset(x: -140, y: 110)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .shadow(color: Theme.accent.opacity(0.35), radius: 22, y: 10)
    }

    private func stat(_ title: String, value: String, suffix: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).opacity(0.8)
            Text(value).font(.headline.monospacedDigit())
            Text(suffix).font(.caption2).opacity(0.75)
        }
    }

    private var devicesCard: some View {
        let sub = app.subscription
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Устройства").font(.headline)
                Spacer()
                Text("\(sub.devices.count) из \(sub.deviceLimit)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(sub.devices) { device in
                HStack(spacing: 12) {
                    IconTile(systemName: device.icon, color: Theme.accent, size: 38)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.name).font(.subheadline.weight(.medium))
                        Text(device.isCurrent ? "Это устройство" : Format.lastSeen(device.lastSeen))
                            .font(.caption)
                            .foregroundStyle(device.isCurrent ? Theme.success : Color.secondary)
                    }
                    Spacer()
                    if !device.isCurrent {
                        Button("Отвязать") {}
                            .font(.caption.weight(.semibold))
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                            .tint(.secondary)
                    }
                }
            }
        }
        .card()
    }
}
