import SwiftUI

struct DiagnosticsView: View {
    @Environment(AppModel.self) private var app
    @State private var isProbing = false
    @State private var isTesting = false
    @State private var steps: [DiagnosticStep] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                permissionHero
                networkSection
                routesSection
                ShareLink(item: report) {
                    Label("Поделиться отчётом", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.scSecondary)
                .padding(.top, 26)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
        }
        .scrollIndicators(.hidden)
        .contentMargins(.bottom, 110, for: .scrollContent)
        .background(AppBackground(glow: 0))
        .navigationTitle("Диагностика")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if app.isDemo && steps.isEmpty { steps = DemoData.permissionSteps }
        }
    }

    private var allOK: Bool { !steps.isEmpty && steps.allSatisfy(\.ok) }

    private var permissionHero: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Разрешение VPN").font(.scTitle3).foregroundStyle(Theme.label)
                    Text("Проверяет, поддерживает ли сертификат VPN: создаёт профиль и поднимает пробный туннель без перенаправления трафика.")
                        .font(.scSub)
                        .foregroundStyle(Theme.label2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if isTesting {
                    ProgressView().tint(Theme.tint).frame(width: 56, height: 56)
                } else if !steps.isEmpty {
                    HeroBadge(systemName: allOK ? "checkmark.shield" : "xmark.shield", color: allOK ? Theme.green : Theme.red)
                }
            }
            if !steps.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(steps) { s in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: s.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(s.ok ? Theme.green : Theme.red)
                            Text(s.text).font(.scSub).foregroundStyle(Theme.label)
                        }
                    }
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
                Text(steps.isEmpty ? "Запустить тест" : "Повторить тест")
            }
            .buttonStyle(.scPrimary)
            .disabled(isTesting)
        }
        .heroCard()
    }

    private var networkSection: some View {
        SCSection(header: "Сеть", footer: app.networkMode.explanation) {
            SCRow(title: app.networkMode.title) {
                CellIcon(systemName: app.networkMode.icon, color: app.networkMode.color)
            } trailing: {
                if isProbing { ProgressView() }
            }
            ForEach(app.probes) { p in
                SCDivider()
                SCRow(title: p.title, subtitle: p.isDomestic ? "Россия" : "Зарубежный", value: p.ms.map { "\($0) мс" } ?? "нет ответа") {
                    Image(systemName: p.ms != nil ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(p.ms != nil ? Theme.green : Theme.red)
                        .frame(width: 30, height: 30)
                }
            }
            SCDivider()
            Button {
                Task {
                    isProbing = true
                    await app.refreshNetwork()
                    isProbing = false
                }
            } label: {
                SCRow(title: "Проверить снова", titleColor: Theme.tint) {
                    CellIcon(systemName: "arrow.clockwise", color: Theme.tint)
                }
            }
            .buttonStyle(RowButtonStyle())
            .disabled(isProbing)
        }
    }

    private var routesSection: some View {
        SCSection(header: "Задержка до серверов") {
            ForEach(Array(app.routes.prefix(6).enumerated()), id: \.element.id) { index, r in
                if index > 0 { SCDivider() }
                SCRow(title: r.country, subtitle: "\(r.group.shortTitle) · \(r.transport.title)") {
                    Flag(code: r.countryCode)
                } trailing: {
                    PingLabel(ms: r.ping)
                }
            }
        }
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
