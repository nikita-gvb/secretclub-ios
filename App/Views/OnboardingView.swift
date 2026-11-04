import SwiftUI

struct OnboardingView: View {
    @Environment(\.openURL) private var openURL
    @State private var showPaste = false
    @State private var showScanner = false

    var body: some View {
        ZStack {
            AppBackground()
            VStack(spacing: 0) {
                Spacer(minLength: 16)
                LogoMark(size: 96)
                Text("SecretClub")
                    .font(.system(size: 38, weight: .heavy, design: .rounded))
                    .padding(.top, 22)
                Text("Свободный интернет —\nдаже при белых списках")
                    .font(.title3)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)

                VStack(alignment: .leading, spacing: 20) {
                    FeatureRow(icon: "sparkles", title: "Авто-режим", text: "Сам находит рабочий маршрут в любой сети")
                    FeatureRow(icon: "shield.lefthalf.filled", title: "Обход белых списков", text: "Подключение через CDN, когда остальное не работает")
                    FeatureRow(icon: "leaf.fill", title: "Бережёт батарею", text: "Без лишних фоновых проверок")
                }
                .padding(.top, 40)
                .padding(.horizontal, 8)

                Spacer(minLength: 24)

                VStack(spacing: 12) {
                    Button {
                        openURL(Config.botLoginURL)
                    } label: {
                        Label("Войти через Telegram", systemImage: "paperplane.fill")
                    }
                    .buttonStyle(PrimaryButtonStyle())

                    HStack(spacing: 12) {
                        Button { showPaste = true } label: {
                            Label("Вставить ссылку", systemImage: "link")
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        Button { showScanner = true } label: {
                            Label("QR-код", systemImage: "qrcode.viewfinder")
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }

                    Text("Нет подписки? Оформите её в боте — это займёт минуту.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 6)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
        }
        .sheet(isPresented: $showPaste) { PasteLinkSheet() }
        .sheet(isPresented: $showScanner) { QRScannerSheet() }
    }
}

private struct FeatureRow: View {
    let icon: String
    let title: String
    let text: String

    var body: some View {
        HStack(spacing: 14) {
            IconTile(systemName: icon, color: Theme.accent, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}

struct PasteLinkSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Скопируйте ссылку на подписку в боте и вставьте её сюда.")
                    .foregroundStyle(.secondary)
                TextField("https://…", text: $text, axis: .vertical)
                    .lineLimit(1...4)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .padding(14)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.cardStroke))
                PasteButton(payloadType: String.self) { strings in
                    if let s = strings.first { text = s }
                }
                .buttonBorderShape(.capsule)
                if let error {
                    Label(error, systemImage: "exclamationmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(Theme.danger)
                }
                Spacer()
                Button("Войти") {
                    if app.login(with: text) {
                        dismiss()
                    } else {
                        error = "Это не похоже на ссылку подписки. Она начинается с https://"
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(20)
            .background(AppBackground())
            .navigationTitle("Ссылка на подписку")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
