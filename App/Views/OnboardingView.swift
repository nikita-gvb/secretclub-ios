import SwiftUI

struct OnboardingView: View {
    @Environment(AppModel.self) private var app
    @State private var showPaste = false
    @State private var showScanner = false

    var body: some View {
        VStack(spacing: 0) {
                Spacer(minLength: 24)
                BrandMark(size: 88)
                Text("SecretClub")
                    .font(.scLarge)
                    .tracking(-0.8)
                    .foregroundStyle(Theme.label)
                    .padding(.top, 22)
                Text("Свободный интернет — даже когда сеть ограничена")
                    .font(.scBody)
                    .foregroundStyle(Theme.label2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
                    .padding(.top, 8)

                VStack(alignment: .leading, spacing: 18) {
                    FeatureRow(icon: "sparkles", title: "Авто-режим", text: "Сам находит рабочий маршрут в любой сети")
                    FeatureRow(icon: "lifepreserver", title: "Обход белых списков", text: "Когда мобильный интернет пускает только на разрешённые сайты")
                    FeatureRow(icon: "leaf", title: "Бережёт батарею", text: "Без лишних фоновых проверок")
                }
                .padding(.top, 40)
                .padding(.horizontal, 12)

                Spacer(minLength: 24)

                VStack(spacing: 10) {
                    Button {
                        app.showLogin = true
                    } label: {
                        Label("Войти через Telegram", systemImage: "paperplane.fill")
                    }
                    .buttonStyle(.scPrimary)

                    HStack(spacing: 10) {
                        Button { showPaste = true } label: { Label("Ссылка", systemImage: "link") }
                            .buttonStyle(.scSecondary)
                        Button { showScanner = true } label: { Label("QR-код", systemImage: "qrcode.viewfinder") }
                            .buttonStyle(.scSecondary)
                    }

                    Text("Вход через бота @\(Config.botUsername) — подписки подтянутся сами.")
                        .font(.scFoot)
                        .foregroundStyle(Theme.label2)
                        .multilineTextAlignment(.center)
                        .padding(.top, 2)
                }
                .padding(14)
                .background {
                    RoundedRectangle(cornerRadius: 32, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay(RoundedRectangle(cornerRadius: 32, style: .continuous).fill(Theme.cell.opacity(0.7)))
                        .overlay(RoundedRectangle(cornerRadius: 32, style: .continuous).strokeBorder(Theme.border, lineWidth: 0.5))
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppBackground(glow: 0.3))
        .sheet(isPresented: $showPaste) { PasteLinkSheet() }
        .sheet(isPresented: $showScanner) { QRScannerSheet() }
    }
}

private struct FeatureRow: View {
    let icon: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .frame(width: 44, height: 44)
                .background(Theme.tintSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.scHeadline).foregroundStyle(Theme.label)
                Text(text).font(.scSub).foregroundStyle(Theme.label2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

struct PasteLinkSheet: View {
    /// true — добавляем ссылку резервного подключения, а не основную.
    var reserve = false
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var error: String?
    @State private var busy = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text(reserve ? "Скопируйте в боте ссылку резервного подключения (обход белых списков) и вставьте её сюда." : "Скопируйте ссылку на подписку в боте и вставьте её сюда.")
                    .font(.scSub)
                    .foregroundStyle(Theme.label2)
                    .padding(.horizontal, 4)
                TextField("", text: $text, prompt: Text("https://…").foregroundStyle(Theme.label3), axis: .vertical)
                    .lineLimit(1...4)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .focused($focused)
                    .scField(focused: focused)
                PasteButton(payloadType: String.self) { strings in
                    if let s = strings.first { text = s }
                }
                .buttonBorderShape(.capsule)
                .tint(Theme.fill)
                if let error {
                    Label(error, systemImage: "exclamationmark.circle.fill")
                        .font(.scFoot)
                        .foregroundStyle(Theme.red)
                        .padding(.horizontal, 4)
                }
                Spacer()
                Button {
                    busy = true
                    error = nil
                    Task {
                        let problem: String?
                        if reserve {
                            problem = await app.addReserve(with: text)
                        } else {
                            problem = await app.login(with: text)
                        }
                        if let problem {
                            error = problem
                            busy = false
                        } else {
                            dismiss()
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        if busy { ProgressView().tint(Theme.onTint) }
                        Text(busy ? "Проверяем подписку…" : (reserve ? "Добавить" : "Войти"))
                    }
                }
                .buttonStyle(.scPrimary)
                .disabled(busy || text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(16)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle(reserve ? "Обход белых списков" : "Ссылка на подписку")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationCornerRadius(34)
        .presentationBackground(Theme.background)
    }
}
