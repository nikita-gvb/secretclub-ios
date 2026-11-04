import SwiftUI

struct DiagnosticsView: View {
    @Environment(AppModel.self) private var app
    @State private var isProbing = false
    @State private var isTesting = false
    @State private var steps: [DiagnosticStep] = []

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                networkCard
                permissionCard
                routesCard
                ShareLink(item: report) {
                    Label("Поделиться отчётом", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(SecondaryButtonStyle())
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .scrollIndicators(.hidden)
        .background(AppBackground())
        .navigationTitle("Диагностика")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if app.isDemo && steps.isEmpty { steps = DemoData.permissionSteps }
        }
    }

    private var networkCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                IconTile(systemName: app.networkMode.icon, color: app.networkMode.color, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Состояние сети").font(.caption).foregroundStyle(.secondary)
                    Text(app.networkMode.title).font(.headline)
                }
                Spacer()
                if isProbing { ProgressView() }
            }
            Text(app.networkMode.explanation)
                .font(.footnote)
                .foregroundStyle(.secondary)
            VStack(spacing: 10) {
                ForEach(app.probes) { p in
                    HStack(spacing: 8) {
                        Image(systemName: p.ms != nil ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(p.ms != nil ? Theme.success : Theme.danger)
                        Text(p.title).font(.subheadline)
                        Text(p.isDomestic ? "РФ" : "зарубеж")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                        Spacer()
                        Text(p.ms.map { "\($0) мс" } ?? "нет ответа")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Button {
                Task {
                    isProbing = true
                    await app.refreshNetwork()
                    isProbing = false
                }
            } label: {
                Label("Проверить снова", systemImage: "arrow.clockwise")
                    .font(.subheadline.weight(.semibold))
            }
            .disabled(isProbing)
        }
        .card()
    }

    private var permissionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                IconTile(systemName: "checkmark.shield.fill", color: Theme.accent, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Разрешение VPN").font(.headline)
                    Text("Проверка подписи приложения").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if isTesting { ProgressView() }
            }
            Text("Создаёт VPN-профиль и запускает пробный туннель без перенаправления трафика. Так видно, поддерживает ли ваш сертификат VPN.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            ForEach(steps) { s in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: s.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(s.ok ? Theme.success : Theme.danger)
                    Text(s.text).font(.subheadline)
                }
            }
            Button {
                Task {
                    isTesting = true
                    steps = []
                    steps = await app.vpn.permissionTest()
                    isTesting = false
                }
            } label: {
                Label("Запустить тест", systemImage: "play.fill")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(isTesting)
        }
        .card()
    }

    private var routesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Задержка до серверов").font(.headline)
            ForEach(app.routes.prefix(6)) { r in
                HStack(spacing: 10) {
                    Text(r.flag)
                    Text(r.country).font(.subheadline)
                    GroupTag(group: r.group)
                    Text(r.transport.title).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    PingLabel(ms: r.ping)
                }
            }
        }
        .card()
    }

    private var report: String {
        var lines = ["SecretClub \(Config.version)", "Сеть: \(app.networkMode.title)"]
        lines += app.probes.map { "  \($0.title): \($0.ms.map { "\($0) мс" } ?? "нет ответа")" }
        lines.append("VPN: \(String(describing: app.vpn.state))")
        lines += steps.map { "  \($0.ok ? "✓" : "✗") \($0.text)" }
        if let e = app.vpn.lastError { lines.append("Ошибка: \(e)") }
        return lines.joined(separator: "\n")
    }
}
