import SwiftUI

/// Условия сервиса: бэкенд не выдаёт подписки, пока их не приняли.
struct ConsentCard: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Один раз примите условия сервиса — после этого серверы появятся сами.")
                .font(.scSub)
                .foregroundStyle(Theme.label2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 18) {
                if let terms = app.account?.termsURL {
                    Link(destination: terms) { Label("Условия", systemImage: "arrow.up.right") }
                }
                if let privacy = app.account?.privacyURL {
                    Link(destination: privacy) { Label("Конфиденциальность", systemImage: "arrow.up.right") }
                }
            }
            .font(.sc(15, .medium, relativeTo: .subheadline))
            .foregroundStyle(Theme.ink)
            .labelStyle(TrailingIconLabelStyle())
            Button {
                Task { await app.acceptConsent() }
            } label: {
                LoadingLabel(title: "Принимаю", loading: app.busyAction == "consent")
            }
            .buttonStyle(.scPrimary)
            .disabled(app.busyAction != nil)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.cell, in: RoundedRectangle(cornerRadius: Theme.rCard, style: .continuous))
    }
}

/// Вошли через Telegram, а подписки ещё нет: пробный период или покупка в боте.
struct NoSubscriptionCard: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL

    var body: some View {
        let trial = app.account?.trialAvailable == true
        let days = app.account?.trialDays ?? 7
        VStack(alignment: .leading, spacing: 10) {
            Text(trial ? "Бесплатно \(Format.days(days)) — серверы появятся сразу, без оплаты."
                       : "Оформите подписку в боте — после оплаты всё появится здесь само.")
                .font(.scSub)
                .foregroundStyle(Theme.label2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 2)
            if trial {
                Button {
                    Task { await app.startTrial() }
                } label: {
                    LoadingLabel(title: "Попробовать бесплатно", loading: app.busyAction == "trial")
                }
                .buttonStyle(.scPrimary)
                .disabled(app.busyAction != nil)
                Button("Тарифы в боте") { openURL(Config.botLink(start: "buy")) }
                    .buttonStyle(.scSecondary)
            } else {
                Button { openURL(Config.botLink(start: "buy")) } label: {
                    Label("Оформить в Telegram", systemImage: "paperplane.fill")
                }
                .buttonStyle(.scPrimary)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.cell, in: RoundedRectangle(cornerRadius: Theme.rCard, style: .continuous))
    }
}
