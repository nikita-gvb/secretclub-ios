import SwiftUI

/// Условия сервиса: бэкенд не выдаёт подписки, пока их не приняли.
struct ConsentCard: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                CellIcon(systemName: "doc.text", color: Theme.tint, size: 36)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Примите условия сервиса").font(.scHeadline).foregroundStyle(Theme.label)
                    Text("Один раз — после этого подписки появятся в приложении.")
                        .font(.scSub)
                        .foregroundStyle(Theme.label2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 18) {
                if let terms = app.account?.termsURL {
                    Link(destination: terms) { Label("Условия", systemImage: "arrow.up.right") }
                }
                if let privacy = app.account?.privacyURL {
                    Link(destination: privacy) { Label("Конфиденциальность", systemImage: "arrow.up.right") }
                }
            }
            .font(.scSub)
            .labelStyle(TrailingIconLabelStyle())
            Button {
                Task { await app.acceptConsent() }
            } label: {
                HStack(spacing: 8) {
                    if app.busyAction == "consent" { ProgressView().tint(Theme.onTint) }
                    Text("Принимаю")
                }
            }
            .buttonStyle(.scPrimary)
            .disabled(app.busyAction != nil)
        }
        .heroCard()
    }
}

/// Вошли через Telegram, а подписки ещё нет: пробный период или покупка в боте.
struct NoSubscriptionCard: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL

    var body: some View {
        let account = app.account
        let trial = account?.trialAvailable == true
        let days = account?.trialDays ?? 7
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                StatusPill(text: "Нет подписки", color: Theme.gray)
                Spacer()
                if let account { Text(account.displayName).font(.scFoot).foregroundStyle(Theme.label2).lineLimit(1) }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Подписки пока нет").font(.scTitle2).foregroundStyle(Theme.label)
                Text(trial ? "Попробуйте бесплатно: \(days) \(Format.plural(days, "день", "дня", "дней")). Серверы появятся сразу."
                           : "Оформите подписку в боте — после оплаты всё появится здесь само.")
                    .font(.scSub)
                    .foregroundStyle(Theme.label2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if trial {
                Button {
                    Task { await app.startTrial() }
                } label: {
                    HStack(spacing: 8) {
                        if app.busyAction == "trial" { ProgressView().tint(Theme.onTint) }
                        Text("Попробовать бесплатно")
                    }
                }
                .buttonStyle(.scPrimary)
                .disabled(app.busyAction != nil)
                Button("Тарифы в боте") { openURL(Config.botLink(start: "buy")) }
                    .buttonStyle(.scSecondary)
            } else {
                Button("Оформить в боте") { openURL(Config.botLink(start: "buy")) }
                    .buttonStyle(.scPrimary)
            }
        }
        .heroCard()
    }
}

struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.title
            configuration.icon.font(.system(size: 11, weight: .semibold))
        }
    }
}
