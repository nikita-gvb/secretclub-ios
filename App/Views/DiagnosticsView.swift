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
        .contentMargins(.bottom, 28, for: .scrollContent)
        .background(AppBackground(glow: 0))
        .navigationTitle("Диагностика")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if app.isDemo && steps.isEmpty { steps = DemoData.permissionSteps }
        }
    }

    private var allOK: Bool { !steps.isEmpty && steps.allSatisfy(\.ok) }

    private var heroText: String {
        app.vpn.state == .connected
            ? "VPN включён: проверим ядро Xray, память расширения и выход в интернет через туннель."
            : "Проверит, поддерживает ли сертификат VPN: создаст профиль и поднимет пробный туннель без перехвата трафика."
    }

    private var permissionHero: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Проверка VPN").font(.scTitle3).foregroundStyle(Theme.label)
                    Text(heroText)
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
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            Button {
                Task {
                    isTesting = true
                    steps = []
                    steps = await app.vpn.selfTest()
                    isTesting = false
                }
            } label: {
                Text(steps.isEmpty ? "Запустить проверку" : "Проверить ещё раз")
            }
            .buttonStyle(.scPrimary)
            .disabled(isTesting || app.vpn.isBusy)
        }
        .heroCard()
    }

    private var networkSection: some View {
        SCSection(header: app.vpn.isActive ? "Сеть (сейчас через VPN)" : "Сеть", footer: app.networkMode.explanation) {
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

    private var fastest: [Route] {
        let sorted = app.routes.sorted { ($0.ping ?? Int.max) < ($1.ping ?? Int.max) }
        return Array(sorted.prefix(8))
    }

    private var routesSection: some View {
        SCSection(header: "Задержка до серверов", footer: app.pingedAt.map { "Замер \(Format.ago($0)). Пинг идёт через само ядро Xray." }) {
            ForEach(Array(fastest.enumerated()), id: \.element.id) { index, r in
                if index > 0 { SCDivider() }
                SCRow(title: r.title, subtitle: "\(r.group.shortTitle) · \(r.transportTitle)") {
                    Flag(emoji: r.emoji)
                } trailing: {
                    if r.unavailable {
                        Text("нет ответа").font(.scSub).foregroundStyle(Theme.label3)
                    } else {
                        PingLabel(ms: r.ping)
                    }
                }
            }
            if !fastest.isEmpty { SCDivider() }
            Button {
                Task { await app.pingAll() }
            } label: {
                SCRow(title: app.isPinging ? "Проверяем…" : "Обновить пинг", titleColor: app.canPing ? Theme.tint : Theme.label3) {
                    CellIcon(systemName: "speedometer", color: app.canPing ? Theme.tint : Theme.label3)
                } trailing: {
                    if app.isPinging { ProgressView() }
                }
            }
            .buttonStyle(RowButtonStyle())
            .disabled(!app.canPing || app.isPinging)
        }
    }

    private var report: String {
        var lines = ["SecretClub \(Config.version)", "Сеть: \(app.networkMode.title)"]
        lines += app.probes.map { "  \($0.title): \($0.ms.map { "\($0) мс" } ?? "нет ответа")" }
        lines.append("VPN: \(String(describing: app.vpn.state))")
        if let r = app.vpn.report {
            lines.append("Ядро: \(r.coreVersion), работает: \(r.running ? "да" : "нет")\(r.memoryMB.map { ", память \(Int($0)) МБ" } ?? "")")
            if let e = r.error { lines.append("Ошибка ядра: \(e)") }
        }
        if let route = app.activeRoute { lines.append("Маршрут: \(route.remarks) [\(route.group.rawValue), \(route.transportTitle)]") }
        lines.append("Серверов: \(app.routes.count), подписка: \(app.subscription.plan)")
        lines += steps.map { "  \($0.ok ? "✓" : "✗") \($0.text)" }
        lines += app.routes.prefix(20).map { "  \($0.remarks): \($0.unavailable ? "нет ответа" : Ping.text($0.ping))" }
        if let e = app.vpn.lastError { lines.append("Ошибка: \(e)") }
        if let e = app.refreshError { lines.append("Подписка: \(e)") }
        return lines.joined(separator: "\n")
    }
}
