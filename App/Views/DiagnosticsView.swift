import SwiftUI

// MARK: - Проверка соединения

struct CheckView: View {
    @Environment(AppModel.self) private var app
    @AppStorage(SettingsKey.ruDirect) private var ruDirect = true
    @State private var steps = CheckStep.initial
    @State private var running = false
    @State private var outcome: Outcome?

    enum StepState: Equatable { case waiting, running, ok, skipped, failed }

    struct CheckStep: Identifiable, Equatable {
        let id: Int
        let title: String
        var state: StepState = .waiting
        var detail = "ждёт проверки"

        static let initial = [
            CheckStep(id: 0, title: "Интернет на iPhone"),
            CheckStep(id: 1, title: "Сервер SecretClub"),
            CheckStep(id: 2, title: "Зарубежные сайты"),
            CheckStep(id: 3, title: "Российские сайты"),
        ]
    }

    enum Outcome: Equatable { case good, offline, vpnOff, problem }

    var body: some View {
        List {
            Section { hero }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 24, bottom: 8, trailing: 24))

            Section {
                ForEach(steps) { StepRow(step: $0) }
            }

            Section {
                VStack(spacing: 10) {
                    if outcome == .vpnOff {
                        Button {
                            app.selectedTab = .home
                            app.tapPower()
                        } label: {
                            Label("Включить VPN", systemImage: "power")
                        }
                        .buttonStyle(.scPrimary)
                    }
                    Button { Task { await run() } } label: {
                        LoadingLabel(title: "Проверить снова", icon: "arrow.clockwise", loading: running, spinnerTint: Theme.ink)
                    }
                    .buttonStyle(.scTinted)
                    .disabled(running)
                    ShareLink(item: report) {
                        Text("Отправить отчёт в поддержку")
                    }
                    .buttonStyle(.scSecondary)
                }
            } footer: {
                Text("В отчёте — технические подробности для поддержки. Личные данные и история сайтов не отправляются.")
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 6)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Проверка соединения")
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(trigger: outcome) { _, new in
            switch new {
            case .good: return .success
            case .none: return nil
            default: return .warning
            }
        }
        .task {
            if outcome == nil, !running { await run() }
        }
    }

    // MARK: Шапка

    private var hero: some View {
        VStack(spacing: 6) {
            ZStack {
                if running || outcome == nil {
                    SpinningArc(period: 0.9, color: Theme.tint)
                        .frame(width: 80, height: 80)
                        .transition(.opacity)
                } else {
                    Circle().fill(heroColor.opacity(0.16))
                    Image(systemName: heroIcon)
                        .font(.system(size: 36, weight: .bold))
                        .foregroundStyle(heroColor)
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                }
            }
            .frame(width: 84, height: 84)
            .padding(.bottom, 10)
            .animation(.spring(response: 0.45, dampingFraction: 0.7), value: running)

            Text(heroTitle)
                .font(.sc(24, .bold, relativeTo: .title2))
                .foregroundStyle(Theme.label)
                .contentTransition(.opacity)
            Text(heroText)
                .font(.scSub)
                .foregroundStyle(Theme.label2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
        }
        .frame(maxWidth: .infinity)
        .animation(.easeInOut(duration: 0.25), value: outcome)
    }

    private var heroTitle: String {
        guard !running, let outcome else { return "Проверяем…" }
        switch outcome {
        case .good: return "Всё работает"
        case .offline: return "Нет интернета"
        case .vpnOff: return "VPN выключен"
        case .problem: return "Есть проблема"
        }
    }

    private var heroText: String {
        guard !running, let outcome else { return "Это займёт несколько секунд" }
        switch outcome {
        case .good: return "Если какой-то сайт не открывается — отправьте отчёт, разберёмся."
        case .offline: return "Проверьте Wi‑Fi или мобильную сеть."
        case .vpnOff: return "Включите VPN на главной — и проверим ещё раз."
        case .problem: return "Попробуйте другой сервер. Не помогло — отправьте отчёт, разберёмся."
        }
    }

    private var heroIcon: String {
        switch outcome {
        case .offline: return "wifi.slash"
        case .vpnOff: return "power"
        case .problem: return "exclamationmark"
        default: return "checkmark"
        }
    }

    private var heroColor: Color {
        switch outcome {
        case .offline, .vpnOff: return Theme.ink
        case .problem: return Theme.orange
        default: return Theme.green
        }
    }

    // MARK: Проверка

    private func set(_ index: Int, _ state: StepState, _ detail: String) {
        withAnimation(.snappy(duration: 0.3)) {
            steps[index].state = state
            steps[index].detail = detail
        }
    }

    /// Каждый шаг идёт не быстрее ~0,6 с — иначе результат не успеть заметить.
    private func pause(since start: Date, min: Double = 0.6) async {
        let left = min - Date().timeIntervalSince(start)
        if left > 0 { try? await Task.sleep(for: .seconds(left)) }
    }

    private func run() async {
        guard !running else { return }
        running = true
        outcome = nil
        withAnimation(.snappy) { steps = CheckStep.initial }
        defer { running = false }

        // 1. Интернет на iPhone
        var start = Date()
        set(0, .running, "проверяем…")
        let offline = app.pathOffline
        if !offline { await app.refreshNetwork() }
        await pause(since: start)
        if offline || app.networkMode == .offline {
            set(0, .failed, "Нет подключения к сети")
            for i in 1..<steps.count { set(i, .skipped, "Нет сети") }
            outcome = .offline
            return
        }
        set(0, .ok, networkText)

        // 2. Сервер
        let on = app.vpn.state == .connected
        guard on else {
            set(1, .skipped, "VPN выключен")
            set(2, .skipped, "Не проверяли — VPN выключен")
            await russian(start: Date(), on: false)
            outcome = .vpnOff
            return
        }
        start = Date()
        set(1, .running, "проверяем…")
        await app.vpn.requestCheck(network: false)
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(200))
            if app.vpn.report?.checking != true, app.tunnelHealthy != nil { break }
        }
        await pause(since: start)
        let route = app.displayRoute ?? app.activeRoute
        if app.tunnelHealthy == false {
            set(1, .failed, "\(route?.title ?? "Сервер") не отвечает")
        } else if let route {
            let word = route.quality.map { Quality.word($0).lowercased() + " связь" } ?? "подключено"
            set(1, .ok, "\(route.title) · \(word)")
        } else {
            set(1, .ok, "Подключено")
        }

        // 3. Зарубежные сайты
        start = Date()
        set(2, .running, "проверяем…")
        await pause(since: start)
        let foreign = app.probes.filter { !$0.isDomestic }
        if foreign.isEmpty {
            set(2, .skipped, "Не удалось проверить")
        } else if let best = foreign.compactMap(\.ms).min() {
            set(2, .ok, "Открываются · \(best) мс")
        } else {
            set(2, .failed, "Не открываются")
        }

        // 4. Российские сайты
        await russian(start: Date(), on: true)

        outcome = steps.contains { $0.state == .failed } ? .problem : .good
    }

    private func russian(start: Date, on: Bool) async {
        set(3, .running, "проверяем…")
        await pause(since: start)
        let domestic = app.probes.filter(\.isDomestic)
        if domestic.isEmpty {
            set(3, .skipped, "Не удалось проверить")
        } else if domestic.contains(where: { $0.ms != nil }) {
            set(3, .ok, on && ruDirect ? "Открываются напрямую" : "Открываются")
        } else {
            set(3, .failed, "Не открываются")
        }
    }

    private var networkText: String {
        var kind: String
        switch app.pathKind {
        case .wifi: kind = "Wi‑Fi"
        case .cellular: kind = "Мобильная сеть"
        case .wired: kind = "Кабель"
        default: kind = "Есть подключение"
        }
        if app.networkMode == .whitelist { kind += " · сеть ограничена" }
        return kind
    }

    private var report: String {
        app.supportReport(steps: steps.map { step in
            let mark: String
            switch step.state {
            case .ok: mark = "✓"
            case .failed: mark = "✗"
            case .skipped: mark = "–"
            case .waiting, .running: mark = "…"
            }
            return "\(mark) \(step.title): \(step.detail)"
        })
    }
}

private struct StepRow: View {
    let step: CheckView.CheckStep

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                switch step.state {
                case .waiting:
                    Circle().fill(Theme.fill2).frame(width: 10, height: 10)
                case .running:
                    ProgressView().controlSize(.small)
                case .ok:
                    Circle().fill(Theme.green)
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .heavy)).foregroundStyle(.white)
                case .failed:
                    Circle().fill(Theme.red)
                    Image(systemName: "xmark").font(.system(size: 10, weight: .heavy)).foregroundStyle(.white)
                case .skipped:
                    Image(systemName: "minus").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.label3)
                }
            }
            .frame(width: 22, height: 22)
            .transition(.scale.combined(with: .opacity))
            .id(step.state)
            VStack(alignment: .leading, spacing: 1) {
                Text(step.title).font(.sc(17, .semibold, relativeTo: .body)).foregroundStyle(Theme.label)
                Text(step.detail)
                    .font(.scFoot)
                    .foregroundStyle(step.state == .failed ? Theme.red : Theme.label2)
                    .contentTransition(.opacity)
            }
            .lineLimit(1)
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Проверка VPN-профиля (для поддержки)

struct SelfTestView: View {
    @Environment(AppModel.self) private var app
    @State private var steps: [DiagnosticStep] = []
    @State private var testing = false

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    Text(intro)
                        .font(.scSub)
                        .foregroundStyle(Theme.label2)
                        .fixedSize(horizontal: false, vertical: true)
                    Button { Task { await run() } } label: {
                        LoadingLabel(title: steps.isEmpty ? "Запустить проверку" : "Проверить ещё раз", loading: testing)
                    }
                    .buttonStyle(.scPrimary)
                    .disabled(testing || app.vpn.isBusy)
                }
                .padding(.vertical, 8)
            }

            if !steps.isEmpty {
                Section {
                    ForEach(steps) { s in
                        Label {
                            Text(s.text).foregroundStyle(Theme.label)
                        } icon: {
                            Image(systemName: s.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(s.ok ? Theme.green : Theme.red)
                        }
                    }
                } footer: {
                    Text(steps.allSatisfy(\.ok) ? "Всё в порядке." : "Отправьте результат в поддержку — разберёмся.")
                }
                Section {
                    ShareLink(item: app.supportReport(steps: steps.map { "\($0.ok ? "✓" : "✗") \($0.text)" })) {
                        Label("Отправить в поддержку", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Проверка VPN-профиля")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if app.isDemo && steps.isEmpty { steps = DemoData.permissionSteps }
        }
    }

    private var intro: String {
        app.vpn.state == .connected
            ? "VPN включён: проверим ядро, память расширения и выход в интернет через туннель."
            : "Создаст VPN-профиль и поднимет пробный туннель — без перехвата трафика. Помогает понять, разрешает ли iPhone этот VPN."
    }

    private func run() async {
        testing = true
        steps = []
        steps = await app.vpn.selfTest()
        testing = false
    }
}
