import SwiftUI

/// Вход через Telegram: код у бэкенда → бот @secvmbot → приложение получает токен и обе подписки.
struct TelegramLoginSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    @State private var opened = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Spacer(minLength: 12)
                icon
                Text(title)
                    .font(.scTitle2)
                    .foregroundStyle(Theme.label)
                    .multilineTextAlignment(.center)
                    .padding(.top, 20)
                Text(message)
                    .font(.scSub)
                    .foregroundStyle(Theme.label2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 320)
                    .padding(.top, 8)
                if app.loginPhase == .waiting {
                    VStack(alignment: .leading, spacing: 12) {
                        StepRow(number: 1, text: "Откроется бот @\(Config.botUsername)")
                        StepRow(number: 2, text: "Нажмите «Старт» или «Запустить»")
                        StepRow(number: 3, text: "Вернитесь сюда — вход завершится сам")
                    }
                    .solidCard()
                    .padding(.top, 24)
                }
                Spacer(minLength: 24)
                buttons
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppBackground(glow: 0.18))
            .navigationTitle("Вход через Telegram")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { app.cancelLogin() }
                }
            }
        }
        .presentationDetents([.large])
        .presentationCornerRadius(34)
        .presentationBackground(Theme.background)
        .task { await begin() }
    }

    private var title: String {
        switch app.loginPhase {
        case .failed: return "Не получилось войти"
        case .waiting: return "Подтвердите вход в Telegram"
        default: return "Готовим вход…"
        }
    }

    private var message: String {
        switch app.loginPhase {
        case .failed(let text): return text
        case .waiting: return "Ссылку на подписку копировать не нужно — приложение получит всё само."
        default: return "Секунду, получаем код входа."
        }
    }

    @ViewBuilder private var icon: some View {
        switch app.loginPhase {
        case .failed:
            HeroBadge(systemName: "exclamationmark.triangle", color: Theme.orange)
        case .waiting:
            ZStack {
                HeroBadge(systemName: "paperplane.fill", color: Theme.tint)
                ProgressView()
                    .controlSize(.small)
                    .tint(Theme.tint)
                    .offset(x: 30, y: 30)
            }
        default:
            ProgressView().tint(Theme.tint).frame(width: 56, height: 56)
        }
    }

    @ViewBuilder private var buttons: some View {
        VStack(spacing: 10) {
            switch app.loginPhase {
            case .failed:
                Button {
                    Task { await begin(force: true) }
                } label: {
                    Label("Попробовать ещё раз", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.scPrimary)
            case .waiting:
                Button {
                    if let ticket = app.loginTicket { open(ticket) }
                } label: {
                    Label(opened ? "Открыть Telegram ещё раз" : "Открыть Telegram", systemImage: "paperplane.fill")
                }
                .buttonStyle(.scPrimary)
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).tint(Theme.label2)
                    Text("Ждём подтверждения…").font(.scFoot).foregroundStyle(Theme.label2)
                }
                .padding(.top, 4)
            default:
                EmptyView()
            }
        }
    }

    private func begin(force: Bool = false) async {
        if !force, app.loginPhase == .waiting, app.loginTicket != nil { return }
        if force { opened = false }
        if let ticket = await app.beginTelegramLogin(), !opened { open(ticket) }
    }

    /// Сначала tg:// (сразу в приложение Telegram), если не вышло — https://t.me.
    private func open(_ ticket: LoginTicket) {
        opened = true
        guard !app.isDemo else { return }
        if let tg = ticket.tgURL {
            openURL(tg) { accepted in
                if !accepted { openURL(ticket.botURL) }
            }
        } else {
            openURL(ticket.botURL)
        }
    }
}

private struct StepRow: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Text("\(number)")
                .font(.onest(14, .bold, relativeTo: .footnote))
                .foregroundStyle(Theme.onTint)
                .frame(width: 26, height: 26)
                .background(Theme.tint, in: Circle())
            Text(text).font(.scSub).foregroundStyle(Theme.label)
            Spacer(minLength: 0)
        }
    }
}
