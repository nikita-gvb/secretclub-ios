import SwiftUI
import Charts

/// Главная: свайп между «Кнопкой» и «Сводкой».
struct HomeView: View {
    @Environment(AppModel.self) private var app
    @State private var page = 0

    var body: some View {
        @Bindable var app = app
        ZStack(alignment: .bottom) {
            LinearGradient(colors: [Theme.launchTop, Theme.launchMid, Theme.launchBottom], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            TabView(selection: $page) {
                LaunchPage().tag(0)
                SummaryPage().tag(1)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            PageDots(page: page) { i in withAnimation(.smooth(duration: 0.4)) { page = i } }
                .padding(.bottom, 8)
        }
        .sheet(isPresented: $app.showServers) { ServersSheet() }
        .onAppear {
            if app.isDemo, app.initialScreen == "summary" { page = 1 }
        }
    }
}

// MARK: - Кнопка

private enum HomeGate { case consent, noSubscription }

struct LaunchPage: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    @State private var shake = 0
    @State private var taps = 0
    @State private var warn = 0

    private var gate: HomeGate? {
        if app.needsConsent { return .consent }
        if app.needsSubscription && app.routes.isEmpty { return .noSubscription }
        return nil
    }

    private var power: PowerState { gate != nil ? .expired : app.power }

    var body: some View {
        let current = self.power
        VStack(spacing: 0) {
            Spacer(minLength: 16)
            PowerButton(state: current, shake: shake) { tap() }
                .background { AmbientGlow(power: current, fail: shake) }
            StatusBlock(title: title(current), subtitle: subtitle(current),
                        since: current == .connected ? app.vpn.connectedSince : nil)
                .padding(.top, 36)
            Spacer(minLength: 16)
            bottom(current)
                .padding(.horizontal, 16)
                .padding(.bottom, 46)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sensoryFeedback(.impact(weight: .medium), trigger: taps)
        .sensoryFeedback(.warning, trigger: warn)
        .sensoryFeedback(trigger: current) { old, new in
            switch new {
            case .connected: return old == .switching ? .impact(weight: .light) : .success
            case .failed: return .error
            case .off: return old == .connecting ? nil : .impact(weight: .light)
            default: return nil
            }
        }
        .onChange(of: current) { _, new in
            if new == .failed { shake += 1 }
        }
    }

    private func tap() {
        if gate != nil || power == .expired {
            shake += 1
            warn += 1
            if gate == nil { app.tapPower() }
            return
        }
        taps += 1
        app.tapPower()
    }

    // MARK: Тексты

    private func title(_ power: PowerState) -> String {
        switch gate {
        case .consent: return "Примите условия"
        case .noSubscription: return "Подписки пока нет"
        case nil: break
        }
        switch power {
        case .off: return "Выключено"
        case .connecting: return "Подключаемся…"
        case .connected: return "Подключено"
        case .switching: return "Меняем сервер…"
        case .waiting: return "Ждём интернет"
        case .failed: return "Не получилось подключиться"
        case .expired: return app.subscription.status == .limited ? "Трафик закончился" : "Подписка закончилась"
        }
    }

    private func subtitle(_ power: PowerState) -> String {
        switch gate {
        case .consent: return "Один раз — и можно подключаться"
        case .noSubscription:
            if app.account?.trialAvailable == true {
                let days = app.account?.trialDays ?? 7
                return "Попробуйте бесплатно — \(Format.days(days))"
            }
            return "Оформите в боте — всё появится само"
        case nil: break
        }
        switch power {
        case .off: return "Нажмите, чтобы подключиться"
        case .connecting:
            if let phase = app.phase, !phase.isEmpty { return phase.trimmingCharacters(in: CharacterSet(charactersIn: "…")) }
            if !app.autoMode, let route = app.displayRoute { return route.title }
            return "Выбираем самый быстрый сервер"
        case .connected: return ""
        case .switching: return "Это займёт пару секунд"
        case .waiting: return "Подключимся сами, когда он появится"
        case .failed: return Self.friendly(app.vpn.lastError)
        case .expired: return "Продлите — VPN включится сам"
        }
    }

    /// Ошибку показываем по-человечески: с большой буквы и без длинных технических хвостов.
    static func friendly(_ error: String?) -> String {
        let fallback = "Попробуйте ещё раз или смените сервер"
        guard var text = error?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, text.count <= 110 else { return fallback }
        text = text.prefix(1).uppercased() + text.dropFirst()
        return text
    }

    // MARK: Низ экрана

    @ViewBuilder
    private func bottom(_ power: PowerState) -> some View {
        switch gate {
        case .consent:
            ConsentCard()
        case .noSubscription:
            NoSubscriptionCard()
        case nil:
            if power == .expired {
                Button { openURL(Config.botLink(start: "buy")) } label: {
                    Label("Продлить подписку", systemImage: "paperplane.fill")
                }
                .buttonStyle(.scPrimary)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                ServerCapsule(power: power)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }
}

/// Мягкое янтарное свечение фона, когда VPN работает; красная вспышка при ошибке.
private struct AmbientGlow: View {
    let power: PowerState
    let fail: Int
    @Environment(\.colorScheme) private var scheme

    private var level: Double {
        switch power {
        case .connected, .switching: return 1
        case .waiting: return 0.35
        default: return 0
        }
    }

    var body: some View {
        ZStack {
            Ellipse()
                .fill(EllipticalGradient(colors: [Theme.tint.opacity(scheme == .dark ? 0.42 : 0.3), Theme.tint.opacity(0)],
                                         center: .center, startRadiusFraction: 0, endRadiusFraction: 0.5))
                .opacity(level)
                .animation(.easeInOut(duration: 0.9), value: level)
            Ellipse()
                .fill(EllipticalGradient(colors: [Theme.red.opacity(0.24), Theme.red.opacity(0)],
                                         center: .center, startRadiusFraction: 0, endRadiusFraction: 0.5))
                .keyframeAnimator(initialValue: 0.0, trigger: fail) { c, v in c.opacity(v) } keyframes: { _ in
                    KeyframeTrack {
                        LinearKeyframe(1, duration: 0.24)
                        CubicKeyframe(0, duration: 1.36)
                    }
                }
        }
        .frame(width: 560, height: 640)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Заголовок и подпись под кнопкой: старый текст уходит вверх с размытием, новый приходит снизу.
private struct StatusBlock: View {
    let title: String
    let subtitle: String
    let since: Date?

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Text(title)
                    .font(.sc(22, .bold, relativeTo: .title2))
                    .tracking(-0.4)
                    .foregroundStyle(Theme.label)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .id(title)
                    .transition(.blurReplace)
            }
            .frame(height: 30)
            ZStack(alignment: .top) {
                if let since {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let elapsed = context.date.timeIntervalSince(since)
                        Text(Format.duration(elapsed))
                            .font(.scNumber(17, .medium, relativeTo: .body))
                            .monospacedDigit()
                            .foregroundStyle(Theme.label2)
                            .contentTransition(.numericText(countsDown: false))
                            .animation(.snappy(duration: 0.3), value: Int(elapsed))
                    }
                    .transition(.blurReplace)
                } else {
                    Text(subtitle)
                        .font(.sc(15, relativeTo: .subheadline))
                        .foregroundStyle(Theme.label2)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .id(subtitle)
                        .transition(.blurReplace)
                }
            }
            .frame(height: 42, alignment: .top)
        }
        .padding(.horizontal, 30)
        .animation(.smooth(duration: 0.32), value: title)
        .animation(.smooth(duration: 0.32), value: subtitle)
        .animation(.smooth(duration: 0.32), value: since == nil)
        .accessibilityElement(children: .combine)
    }
}

/// Капсула сервера: флаг, страна, связь. Открывает шторку серверов.
struct ServerCapsule: View {
    @Environment(AppModel.self) private var app
    let power: PowerState

    var body: some View {
        Button(action: open) {
            HStack(spacing: 11) {
                lead
                VStack(alignment: .leading, spacing: 1) {
                    Text(texts.name)
                        .font(.sc(17, .semibold, relativeTo: .headline))
                        .foregroundStyle(Theme.label)
                    Text(texts.mode)
                        .font(.sc(13, relativeTo: .footnote))
                        .foregroundStyle(Theme.label2)
                }
                .lineLimit(1)
                .id(texts.name + texts.mode)
                .transition(.blurReplace)
                Spacer(minLength: 6)
                trailing
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.label3)
            }
            .padding(.leading, 15)
            .padding(.trailing, 20)
            .frame(height: 62)
            .contentShape(Capsule())
            .scGlass(Capsule(), interactive: true)
            .animation(.smooth(duration: 0.3), value: texts.name + texts.mode)
        }
        .buttonStyle(PressScaleStyle(scale: 0.97))
        .accessibilityLabel("Сервер: \(texts.name), \(texts.mode)")
        .accessibilityHint("Открыть список серверов")
    }

    private func open() {
        if app.routes.isEmpty {
            Task { await app.refreshSubscription() }
        } else {
            app.showServers = true
        }
    }

    private var route: Route? { app.displayRoute }

    private var texts: (name: String, mode: String) {
        if app.routes.isEmpty {
            return app.isRefreshing ? ("Загружаем серверы…", "Секунду") : ("Серверы не загружены", "Нажмите, чтобы обновить")
        }
        if app.autoMode {
            if let route { return (route.title, "Авто") }
            return ("Авто", "самый быстрый сервер")
        }
        if let route { return (route.title, route.humanDetail) }
        return ("Выберите сервер", "или включите «Авто»")
    }

    private var lead: some View {
        ZStack {
            Circle().fill(Theme.fill)
            if let route, !app.routes.isEmpty {
                Text(route.emoji).font(.system(size: 21))
            } else if app.routes.isEmpty {
                Image(systemName: "arrow.clockwise").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
            } else {
                Image(systemName: "sparkles").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.ink)
            }
        }
        .frame(width: 32, height: 32)
        .clipShape(Circle())
    }

    @ViewBuilder private var trailing: some View {
        if power == .connecting || power == .switching || (app.routes.isEmpty && app.isRefreshing) {
            ProgressView().controlSize(.small).tint(Theme.ink)
        } else if power == .connected {
            QualityBars(level: quality)
        }
    }

    private var quality: Int? {
        if app.tunnelHealthy == false { return 0 }
        if let ms = app.vpn.report?.pingMS { return Route.quality(ms: ms) }
        return route?.quality ?? 4
    }
}

/// Точки страниц: активная растягивается в «таблетку».
struct PageDots: View {
    let page: Int
    let select: (Int) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<2, id: \.self) { i in
                Capsule()
                    .fill(i == page ? Theme.label : Theme.label3)
                    .frame(width: i == page ? 18 : 7, height: 7)
                    .contentShape(Rectangle().inset(by: -8))
                    .onTapGesture { select(i) }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 22)
        .scGlass(Capsule())
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: page)
        .accessibilityElement()
        .accessibilityLabel(page == 0 ? "Кнопка, страница 1 из 2" : "Сводка, страница 2 из 2")
    }
}

// MARK: - Сводка

struct SummaryPage: View {
    @Environment(AppModel.self) private var app

    private var power: PowerState { app.power }
    private var live: Bool { power == .connected }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                if power == .off || power == .failed { offCard }
                if let announce = app.meta?.announce ?? app.account?.announcement, !announce.isEmpty {
                    announceCard(announce)
                }
                speedTile
                HStack(spacing: 12) {
                    let down = Format.bytesParts(app.vpn.bytesIn)
                    let up = Format.bytesParts(app.vpn.bytesOut)
                    SummaryTile(icon: "arrow.down", label: "Скачано") {
                        BigValue(number: app.vpn.bytesIn > 0 ? down.number : "—", unit: app.vpn.bytesIn > 0 ? down.unit : "", dim: app.vpn.bytesIn == 0)
                        TileFooter(text: "за сеанс")
                    }
                    SummaryTile(icon: "arrow.up", label: "Отправлено") {
                        BigValue(number: app.vpn.bytesOut > 0 ? up.number : "—", unit: app.vpn.bytesOut > 0 ? up.unit : "", dim: app.vpn.bytesOut == 0)
                        TileFooter(text: "за сеанс")
                    }
                }
                HStack(spacing: 12) {
                    qualityTile
                    networkTile
                }
                subscriptionTile
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 56)
            .animation(.smooth(duration: 0.35), value: power)
        }
        .scrollIndicators(.hidden)
        .refreshable { await app.refreshSubscription() }
    }

    private var header: some View {
        HStack(alignment: .center) {
            Text("Сводка")
                .font(.scLarge)
                .foregroundStyle(Theme.label)
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 7, height: 7)
                Text(statusText)
                    .lineLimit(1)
                    .id(statusText)
                    .transition(.blurReplace)
            }
            .font(.sc(13, .semibold, relativeTo: .footnote))
            .foregroundStyle(Theme.label)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .scGlass(Capsule())
            .animation(.smooth(duration: 0.3), value: statusText)
        }
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private var statusText: String {
        switch power {
        case .off: return "Выключено"
        case .connecting: return "Подключаемся"
        case .connected: return app.displayRoute.map { "Подключено · \($0.title)" } ?? "Подключено"
        case .switching: return "Меняем сервер"
        case .waiting: return "Ждём интернет"
        case .failed: return "Не подключено"
        case .expired: return "Подписка закончилась"
        }
    }

    private var statusColor: Color {
        switch power {
        case .connected, .switching: return Theme.tint
        case .failed, .expired: return Theme.red
        default: return Theme.label3
        }
    }

    private var offCard: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(power == .failed ? "Не получилось подключиться" : "VPN выключен")
                    .font(.scHeadline)
                    .foregroundStyle(Theme.label)
                Text("Включите — здесь появится скорость")
                    .font(.scFoot)
                    .foregroundStyle(Theme.label2)
            }
            Spacer(minLength: 8)
            Button(power == .failed ? "Ещё раз" : "Включить") { app.tapPower() }
                .buttonStyle(.sc(.primary, small: true))
                .fixedSize()
        }
        .padding(16)
        .background(Theme.cell, in: RoundedRectangle(cornerRadius: Theme.rTile, style: .continuous))
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func announceCard(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "megaphone.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .frame(width: 30, height: 30)
                .background(Theme.tintSoft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(text)
                .font(.scSub)
                .foregroundStyle(Theme.label)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(Theme.cell, in: RoundedRectangle(cornerRadius: Theme.rTile, style: .continuous))
    }

    private var speedTile: some View {
        let now = Format.speedParts(app.vpn.rateIn)
        return SummaryTile(icon: "speedometer", label: "Скорость") {
            BigValue(number: live ? now.number : "—", unit: live ? now.unit : "", dim: !live)
            HStack(spacing: 14) {
                Label(live ? Format.speed(app.vpn.rateIn) : "—", systemImage: "arrow.down")
                Label(live ? Format.speed(app.vpn.rateOut) : "—", systemImage: "arrow.up")
            }
            .font(.sc(13, .medium, relativeTo: .footnote))
            .monospacedDigit()
            .foregroundStyle(Theme.label2)
            .labelStyle(CompactLabelStyle())
            .padding(.top, 2)
            SpeedChart(history: app.vpn.rateHistory)
                .frame(height: 64)
                .padding(.top, 8)
                .opacity(live ? 1 : 0.3)
        }
    }

    private var currentQuality: Int? {
        guard live else { return nil }
        if app.tunnelHealthy == false { return 0 }
        if let ms = app.vpn.report?.pingMS { return Route.quality(ms: ms) }
        return app.displayRoute?.quality ?? 4
    }

    private var qualityTile: some View {
        let q = currentQuality
        return SummaryTile(icon: "waveform.path.ecg", label: "Связь") {
            Text(q.map { Quality.word($0) } ?? (power == .connecting || power == .switching ? "…" : "—"))
                .font(.sc(24, .bold, relativeTo: .title2))
                .foregroundStyle(q == nil ? Theme.label3 : Theme.label)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.top, 8)
                .contentTransition(.opacity)
            Spacer(minLength: 6)
            HStack(spacing: 6) {
                Text(live ? (app.displayRoute?.title ?? "—") : "нет подключения")
                    .lineLimit(1)
                Spacer(minLength: 0)
                QualityBars(level: q)
            }
            .font(.sc(13, relativeTo: .footnote))
            .foregroundStyle(Theme.label2)
        }
    }

    private var networkTile: some View {
        let kind: (icon: String, title: String)
        switch app.isOffline ? PathKind.offline : app.pathKind {
        case .wifi: kind = ("wifi", "Wi‑Fi")
        case .cellular: kind = ("antenna.radiowaves.left.and.right", "Мобильная")
        case .wired: kind = ("cable.connector", "Кабель")
        case .offline: kind = ("wifi.slash", "Нет сети")
        case .unknown: kind = ("network", "Интернет")
        }
        let footer: String
        if app.isOffline {
            footer = "ждём подключения"
        } else {
            switch app.networkMode {
            case .normal: footer = "всё открывается"
            case .whitelist: footer = "есть ограничения — обходим"
            case .offline: footer = "ждём подключения"
            case .unknown: footer = "проверяем…"
            }
        }
        return SummaryTile(icon: kind.icon, label: "Сеть") {
            Text(kind.title)
                .font(.sc(24, .bold, relativeTo: .title2))
                .foregroundStyle(Theme.label)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.top, 8)
            Spacer(minLength: 6)
            TileFooter(text: footer)
        }
    }

    private var subscriptionTile: some View {
        let sub = app.subscription
        return Button {
            app.selectedTab = .settings
            app.settingsPath = [.subscription]
        } label: {
            SummaryTile(icon: "creditcard", label: "Подписка") {
                HStack(alignment: .firstTextBaseline) {
                    if !sub.isActive {
                        Text(sub.status == .limited ? "Трафик закончился" : "Закончилась")
                            .font(.sc(24, .bold, relativeTo: .title2))
                            .foregroundStyle(Theme.red)
                    } else if let days = sub.daysLeft {
                        BigValue(number: "\(days)", unit: Format.plural(days, "день", "дня", "дней"))
                    } else {
                        Text("Бессрочно").font(.sc(24, .bold, relativeTo: .title2)).foregroundStyle(Theme.label)
                    }
                    Spacer(minLength: 8)
                    Text(subFooter(sub))
                        .font(.sc(13, relativeTo: .footnote))
                        .foregroundStyle(Theme.label2)
                        .lineLimit(1)
                }
                .padding(.top, 2)
                ProgressBar(value: sub.isActive ? sub.progress : 0)
                    .padding(.top, 10)
            }
        }
        .buttonStyle(PressScaleStyle(scale: 0.98))
    }

    private func subFooter(_ sub: SubscriptionInfo) -> String {
        if !sub.isActive { return "продлите в Telegram" }
        if let expires = sub.expiresAt, !sub.lifetime { return "до \(expires.formatted(.dateTime.day().month(.wide).locale(Format.ru)))" }
        return "срок не ограничен"
    }
}

/// Плитка сводки: подпись с иконкой и содержимое.
struct SummaryTile<Content: View>: View {
    let icon: String
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 12, weight: .bold))
                Text(label)
            }
            .font(.sc(13, .semibold, relativeTo: .footnote))
            .foregroundStyle(Theme.label2)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
        .background(Theme.cell, in: RoundedRectangle(cornerRadius: Theme.rTile, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: Theme.rTile, style: .continuous))
    }
}

/// Крупное число (SF Rounded) с единицей; докручивается, а не прыгает.
struct BigValue: View {
    let number: String
    var unit: String = ""
    var dim = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(number)
                .font(.scNumber(30, .bold, relativeTo: .title))
                .monospacedDigit()
                .contentTransition(.numericText())
            if !unit.isEmpty {
                Text(unit)
                    .font(.sc(15, .semibold, relativeTo: .subheadline))
                    .foregroundStyle(Theme.label2)
            }
        }
        .foregroundStyle(dim ? Theme.label3 : Theme.label)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .padding(.top, 6)
        .animation(.smooth(duration: 0.5), value: number)
    }
}

struct TileFooter: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.sc(13, relativeTo: .footnote))
            .foregroundStyle(Theme.label2)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
    }
}

struct ProgressBar: View {
    let value: Double
    var color: Color = Theme.tint
    @State private var shown = 0.0

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.fill)
                Capsule().fill(color).frame(width: max(0, geo.size.width * min(1, shown)))
            }
        }
        .frame(height: 6)
        .onAppear { withAnimation(.smooth(duration: 0.8).delay(0.1)) { shown = max(0, value) } }
        .onChange(of: value) { _, v in withAnimation(.smooth(duration: 0.6)) { shown = max(0, v) } }
    }
}

struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.font(.system(size: 11, weight: .bold))
            configuration.title
        }
    }
}

/// График скорости за последние ~40 секунд.
struct SpeedChart: View {
    let history: [Double]

    var body: some View {
        let top = max(4 * 1_048_576, (history.max() ?? 0) * 1.25)
        Chart(Array(history.enumerated()), id: \.offset) { item in
            AreaMark(x: .value("t", item.offset), y: .value("v", item.element))
                .interpolationMethod(.catmullRom)
                .foregroundStyle(LinearGradient(colors: [Theme.tint.opacity(0.32), Theme.tint.opacity(0)], startPoint: .top, endPoint: .bottom))
            LineMark(x: .value("t", item.offset), y: .value("v", item.element))
                .interpolationMethod(.catmullRom)
                .foregroundStyle(Theme.tint)
                .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartXScale(domain: 0...max(1, history.count - 1))
        .chartYScale(domain: 0...top)
        .animation(.easeInOut(duration: 0.8), value: history)
        .accessibilityHidden(true)
    }
}
