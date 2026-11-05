import SwiftUI
import Observation
import Network
import CryptoKit
import BackgroundTasks

enum AppTab: String, Hashable {
    case home, settings
}

/// Семь состояний кнопки. Главный экран рисуется только от них.
enum PowerState: Equatable {
    case off, connecting, connected, switching, waiting, failed, expired
}

/// Тип сети: для плитки «Сеть» в сводке.
enum PathKind: Equatable {
    case unknown, wifi, cellular, wired, offline
}

enum LoginPhase: Equatable {
    case starting, waiting
    case failed(String)
}

@MainActor
@Observable
final class AppModel {
    var isLoggedIn: Bool
    var selectedTab: AppTab = .home
    var routes: [Route] = []
    var autoMode = true
    var selectedRouteID: String?
    var autoRouteID: String?
    var connectedRouteID: String?
    var networkMode: NetworkMode = .unknown
    var probes: [ProbeResult] = []
    var probedAt: Date?
    /// Основная подписка и резервное подключение.
    var subscription: SubscriptionInfo = .empty
    var reserve: SubscriptionInfo?
    var meta: SubscriptionMeta?
    var reserveMeta: SubscriptionMeta?
    /// Аккаунт из бэкенда (есть, если вошли через Telegram).
    var account: AccountMe?
    var hasSession = false
    var accountError: String?
    var isRefreshing = false
    var refreshError: String?
    var reserveError: String?
    var isPinging = false
    /// Серверы, для которых идёт замер прямо сейчас (крутилка в строке).
    var pingingIDs: Set<String> = []
    var pingedAt: Date?
    /// Что делаем, пока VPN «подключается» на стороне приложения.
    var phase: String?
    /// Вход через Telegram.
    var showLogin = false
    var loginPhase: LoginPhase?
    var loginTicket: LoginTicket?
    /// Действие с аккаунтом, которое сейчас выполняется: consent, trial, reserve, device:<hwid>.
    var busyAction: String?
    /// Работает ли текущий сервер по последней проверке расширения (nil — не проверяли).
    var tunnelHealthy: Bool?
    /// Сообщение от «Авто» в расширении: на что и почему переключились.
    var autoNotice: String?
    /// Плашка сверху экрана.
    var toast: ToastMessage?
    /// Меняем сервер, не выключая VPN.
    var isSwitching = false
    /// Сети нет совсем (по системе) и какой интерфейс основной.
    var pathOffline = false
    var pathKind: PathKind = .unknown
    /// Стек «Настроек» и шторка серверов — чтобы открывать их из любого места.
    var settingsPath: [SettingsRoute] = []
    var showServers = false
    /// Сбоев за 7 дней (MetricKit и аварийные завершения VPN) — для строки «Диагностика».
    var recentIncidents = 0
    /// Избранные серверы (id = название из подписки — не меняется при обновлении).
    var favorites: Set<String> = Set(UserDefaults.standard.stringArray(forKey: SettingsKey.favorites) ?? [])

    @ObservationIgnored private var configs: [String: [String: Any]] = [:]
    @ObservationIgnored private var primaryParsed: ParsedSubscription?
    @ObservationIgnored private var reserveParsed: ParsedSubscription?
    @ObservationIgnored private var settingsTask: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var pollInFlight = false
    /// Когда мерили каждый сервер (сбрасывается при смене сети).
    @ObservationIgnored private var pingAt: [String: Date] = [:]
    /// Ядро Xray в приложении одно: пинг и проверка конфига — по очереди.
    @ObservationIgnored private var xrayBusy = false
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var pathSignature: String?
    @ObservationIgnored private var lastNoteID = 0
    @ObservationIgnored private let defaults = UserDefaults.standard
    /// Номер текущей попытки подключения: новое нажатие отменяет старую.
    @ObservationIgnored private var connectToken = 0
    /// Конфиги, которые ядро уже проверило (хэш) — второй раз testXray не гоняем.
    @ObservationIgnored private var validated: [String] = UserDefaults.standard.stringArray(forKey: "validatedConfigs") ?? []
    /// Статус узлов от бэкенда: хост → (онлайн, нагрузка).
    @ObservationIgnored private var nodes: [String: NodeStatus] = [:]
    @ObservationIgnored private var nodesAt: Date?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    /// Что последний раз отдали виджетам и напоминаниям о подписке.
    @ObservationIgnored private var sharedSubscriptionKey: String?

    /// Фоновое обновление подписки (BGAppRefreshTask): идентификатор есть в Info.plist.
    static let refreshTaskID = "com.secretclub.app.refresh"

    let vpn = VPNController()
    let isDemo: Bool
    let initialScreen: String?

    init() {
        isDemo = defaults.bool(forKey: "demo")
        initialScreen = defaults.string(forKey: "screen")

        if isDemo {
            routes = DemoData.routes
            account = DemoData.account
            hasSession = true
            subscription = DemoData.subscription
            reserve = DemoData.reserve
            autoRouteID = DemoData.routes.first?.id
            isLoggedIn = initialScreen != "onboarding" && initialScreen != "login"
            networkMode = .normal
            pathKind = .wifi
            probes = DemoData.probes
            let screen = initialScreen ?? "home"
            vpn.enableDemo(connected: !["disconnected", "failed", "expired", "connecting"].contains(screen))
            connectedRouteID = autoRouteID
            pingedAt = Date()
            switch screen {
            case "login":
                showLogin = true
                loginPhase = .waiting
                loginTicket = DemoData.loginTicket
            case "servers":
                showServers = true
                pingingIDs = ["de-cdn", "ru-cdn"]
            case "connecting":
                vpn.state = .connecting
            case "failed":
                vpn.lastError = "Сервер не ответил. Попробуйте ещё раз или выберите другой сервер."
            case "expired":
                subscription.status = .expired
                subscription.expiresAt = Date().addingTimeInterval(-86400)
                reserve = nil
            case "waiting":
                pathOffline = true
                pathKind = .offline
            default:
                break
            }
        } else {
            let session = Keychain.read(Keychain.sessionKey) != nil
            hasSession = session
            isLoggedIn = session || Keychain.read(Keychain.subscriptionKey) != nil
            autoMode = defaults.object(forKey: SettingsKey.autoMode) as? Bool ?? true
            selectedRouteID = defaults.string(forKey: SettingsKey.selectedRoute)
            connectedRouteID = defaults.string(forKey: SettingsKey.connectedRoute)
            if isLoggedIn { loadCache() }
            if !isLoggedIn, let ticket = LoginTicket.load() {
                loginTicket = ticket
                loginPhase = .waiting
                showLogin = true
            }
        }

        vpn.onReport = { [weak self] report in self?.apply(report) }
        if !isDemo {
            Reminders.install { [weak self] url in self?.handle(url: url) }
            shareSubscription()
        }

        switch initialScreen {
        case "settings": selectedTab = .settings
        case "subscription": selectedTab = .settings; settingsPath = [.subscription]
        case "devices": selectedTab = .settings; settingsPath = [.devices]
        case "check": selectedTab = .settings; settingsPath = [.check]
        case "diagnostics": selectedTab = .settings; settingsPath = [.diagnostics]
        case "appearance": selectedTab = .settings; settingsPath = [.appearance]
        case "advanced": selectedTab = .settings; settingsPath = [.advanced]
        case "exceptions": selectedTab = .settings; settingsPath = [.exceptions]
        default: selectedTab = .home
        }
    }

    // MARK: - Состояние

    private var sessionToken: String? { Keychain.read(Keychain.sessionKey) }

    func subscriptionURL(_ slot: SubscriptionSlot) -> URL? {
        Keychain.read(slot.keychainKey).flatMap(URL.init(string:))
    }

    var hasReserveRoutes: Bool { routes.contains { $0.group == .reserve } }

    /// Нужно принять условия сервиса, прежде чем бэкенд отдаст подписки.
    var needsConsent: Bool { account.map { !$0.consentAccepted } ?? false }

    /// Вошли через Telegram, условия приняты, но подписки ещё нет.
    var needsSubscription: Bool {
        guard let account, account.consentAccepted else { return false }
        return !account.hasSubscription
    }

    var activeRoute: Route? {
        let id: String?
        if vpn.isActive, vpn.state != .preparing, let connected = connectedRouteID {
            id = connected
        } else {
            id = autoMode ? (autoRouteID ?? bestCachedRoute()?.id) : selectedRouteID
        }
        if let route = routes.first(where: { $0.id == id }) { return route }
        guard autoMode else { return nil }
        return routes.first(where: { $0.group != .reserve }) ?? routes.first
    }

    var settings: BuildOptions {
        BuildOptions(ruDirect: defaults.object(forKey: SettingsKey.ruDirect) as? Bool ?? true,
                     vpnDomains: Self.domains(defaults.string(forKey: SettingsKey.vpnDomains)),
                     directDomains: Self.domains(defaults.string(forKey: SettingsKey.directDomains)),
                     quietLog: true)
    }

    private var transportPreference: TransportPreference {
        TransportPreference(rawValue: defaults.string(forKey: SettingsKey.transport) ?? "") ?? .auto
    }

    private static func domains(_ raw: String?) -> [String] {
        (raw ?? "").split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    // MARK: - Запуск

    func start() async {
        guard !isDemo else { return }
        MetricsCollector.shared.start()
        AppGroup.defaults?.set(AppSettings.autoConnect, forKey: SharedKey.autoConnect)
        DiagLog.write("запуск приложения \(Config.version), iOS \(UIDevice.current.systemVersion), общая папка: \(AppGroup.identifier ?? "нет")", to: .app)
        recentIncidents = await Task.detached { Incidents.recent().count }.value
        await vpn.load()
        startPathMonitor()
        if let reportRoute = vpn.report?.routeID { connectedRouteID = reportRoute }
        if loginTicket != nil { startPolling() }
        if !vpn.isActive { await refreshNetwork() }
        guard isLoggedIn else { return }
        await refreshSubscription()
        Task { await refreshNodes() }
        if !vpn.isActive && !energySaver { await pingAll() }
    }

    private var energySaver: Bool { defaults.object(forKey: SettingsKey.energySaver) as? Bool ?? true }

    func becameActive() async {
        vpn.setForeground(true)
        guard !isDemo else { return }
        if vpn.state == .connected { Task { await vpn.requestCheck(network: false) } }
        if loginTicket != nil {
            pollNow()
            return
        }
        guard isLoggedIn else { return }
        Task { await refreshNodes() }
        let interval: TimeInterval = energySaver ? 3 * 3600 : 3600
        if let updated = meta?.updatedAt, Date().timeIntervalSince(updated) < interval { return }
        await refreshSubscription()
    }

    // MARK: - Подписки

    private func loadCache() {
        if let raw = AccountStore.load() { account = AccountMe(json: raw) }
        for slot in [SubscriptionSlot.primary, .reserve] {
            guard let cached = SubscriptionService.loadCache(slot) else { continue }
            setMeta(cached.1, slot)
            if let data = cached.0, let parsed = try? SubscriptionService.parse(data, slot: slot) {
                setParsed(parsed, slot)
            }
        }
        rebuild()
    }

    private func setMeta(_ meta: SubscriptionMeta?, _ slot: SubscriptionSlot) {
        if slot == .primary { self.meta = meta } else { reserveMeta = meta }
    }

    private func setParsed(_ parsed: ParsedSubscription?, _ slot: SubscriptionSlot) {
        if slot == .primary { primaryParsed = parsed } else { reserveParsed = parsed }
    }

    /// Собирает общий список серверов из обеих подписок, сохраняя последние замеры.
    private func rebuild() {
        let old = Dictionary(routes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let merged = (primaryParsed?.routes ?? []) + (reserveParsed?.routes ?? [])
        routes = merged.map { route in
            var r = route
            if let prev = old[route.id] {
                r.ping = prev.ping
                r.unavailable = prev.unavailable
            }
            return r
        }
        configs = (primaryParsed?.configs ?? [:]).merging(reserveParsed?.configs ?? [:]) { a, _ in a }
        recomputeInfo()
        if let id = selectedRouteID, configs[id] == nil { selectedRouteID = nil }
        if !autoMode && selectedRouteID == nil { autoMode = true }
    }

    private func recomputeInfo() {
        defer { if !isDemo { shareSubscription() } }
        if let s = account?.subscription, s.error == nil {
            subscription = SubscriptionInfo(account: s)
        } else if let meta {
            subscription = SubscriptionInfo(meta: meta)
        } else {
            subscription = .empty
        }
        if let r = account?.reserve, r.error == nil {
            reserve = SubscriptionInfo(account: r)
        } else if let reserveMeta, subscriptionURL(.reserve) != nil {
            reserve = SubscriptionInfo(meta: reserveMeta)
        } else {
            reserve = nil
        }
    }

    func refreshSubscription() async {
        await refresh(includeAccount: true)
    }

    private func refresh(includeAccount: Bool) async {
        guard !isDemo, isLoggedIn, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        if includeAccount && hasSession { await refreshAccount() }
        async let primary = fetch(.primary)
        async let reserve = fetch(.reserve)
        let (primaryError, reserveError) = await (primary, reserve)
        refreshError = primaryError
        self.reserveError = reserveError
        rebuild()
        await syncPool()
        await storeForBackgroundStart()
    }

    /// VPN выключен: кладём в профиль свежий сервер и запасные — их возьмёт расширение, если VPN
    /// включат из виджета, Пункта управления, Настроек iOS или он поднимется сам.
    private func storeForBackgroundStart() async {
        guard !isDemo, vpn.hasProfile, !vpn.isActive, !routes.isEmpty else { return }
        let route = autoMode ? initialAutoRoute() : routes.first { $0.id == selectedRouteID }
        guard let route, var req = request(for: route) else { return }
        req.pool = TunnelCoding.encode(makePool()).map { String(decoding: $0, as: UTF8.self) }
        await vpn.store(req)
    }

    /// Срок подписки — виджетам (общая папка) и напоминаниям о продлении. Только если изменился.
    private func shareSubscription() {
        let info = subscription
        let usable = subscriptionUsable
        let key = "\(info.expiresAt?.timeIntervalSince1970 ?? 0)|\(info.lifetime)|\(usable)|\(Reminders.enabled)"
        guard key != sharedSubscriptionKey else { return }
        sharedSubscriptionKey = key
        if let shared = AppGroup.defaults {
            shared.set(info.expiresAt?.timeIntervalSince1970 ?? 0, forKey: SharedKey.subscriptionEnds)
            shared.set(info.lifetime, forKey: SharedKey.subscriptionLifetime)
            shared.set(usable, forKey: SharedKey.subscriptionUsable)
            WidgetSync.reload()
        }
        Task { await Reminders.update(expiresAt: info.expiresAt, lifetime: info.lifetime) }
        // Подписка закончилась — iOS не должна бесконечно поднимать VPN, который сервер не пустит
        // (телефон остался бы без интернета). После продления «держать включённым» вернётся при подключении.
        if !usable, isLoggedIn {
            Task {
                await vpn.setOnDemand(false)
                DiagLog.write("подписка неактивна — автоподключение VPN приостановлено", to: .app)
            }
        }
    }

    /// Напоминания включили или выключили в настройках.
    func remindersChanged(_ enabled: Bool) {
        sharedSubscriptionKey = nil
        if enabled {
            Task {
                let allowed = await Reminders.ask()
                if !allowed { showToast("Уведомления выключены в Настройках iOS", icon: "bell.slash", tone: .bad) }
                shareSubscription()
            }
        } else {
            Reminders.cancelAll()
        }
    }

    // MARK: - Фоновое обновление

    /// Попросить iOS обновить подписку в фоне (часа через три). Вызывается при уходе в фон.
    func scheduleBackgroundRefresh() {
        guard !isDemo, isLoggedIn else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskID)
        request.earliestBeginDate = Date().addingTimeInterval(3 * 3600)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// Фоновое обновление: свежие серверы — работающему VPN (запасные) или в профиль (для виджета
    /// и автоподключения), срок подписки — напоминаниям и виджетам. Приложение может быть даже не открыто.
    func backgroundRefresh() async {
        guard !isDemo, isLoggedIn else { return }
        scheduleBackgroundRefresh()
        if !vpn.hasProfile { await vpn.load() }
        DiagLog.write("фоновое обновление подписки", to: .app)
        await refresh(includeAccount: hasSession)
    }

    // MARK: - Избранное

    func isFavorite(_ route: Route) -> Bool { favorites.contains(route.id) }

    func toggleFavorite(_ route: Route) {
        if favorites.contains(route.id) { favorites.remove(route.id) } else { favorites.insert(route.id) }
        defaults.set(Array(favorites).sorted(), forKey: SettingsKey.favorites)
    }

    /// Загружает одну подписку. Возвращает текст ошибки или nil.
    private func fetch(_ slot: SubscriptionSlot) async -> String? {
        guard let url = subscriptionURL(slot) else {
            if slot == .reserve {
                setParsed(nil, .reserve)
                setMeta(nil, .reserve)
                SubscriptionService.clearCache(.reserve)
            }
            return nil
        }
        let data: Data
        let meta: SubscriptionMeta
        do {
            (data, meta) = try await SubscriptionService.fetch(url)
        } catch {
            return error.localizedDescription
        }
        setMeta(meta, slot)
        do {
            let parsed = try SubscriptionService.parse(data, slot: slot)
            SubscriptionService.save(data: data, meta: meta, slot: slot)
            setParsed(parsed, slot)
            return nil
        } catch {
            if slot == .reserve {
                // Трафик резерва закончился или подписка неактивна — серверов нет, но данные о ней есть.
                setParsed(.empty, .reserve)
                SubscriptionService.save(data: nil, meta: meta, slot: .reserve)
            }
            return error.localizedDescription
        }
    }

    private func refreshAccount() async {
        guard let token = sessionToken else { return }
        do {
            applyAccount(try await AccountAPI.me(token))
            accountError = nil
        } catch let error as AccountError where error.status == 401 {
            endSession()
            accountError = "Вход в аккаунт сброшен. Войдите через Telegram ещё раз."
        } catch {
            accountError = error.localizedDescription
        }
    }

    private func applyAccount(_ raw: [String: Any]) {
        let me = AccountMe(json: raw)
        account = me
        AccountStore.save(raw)
        if let bot = me.botUsername { defaults.set(bot, forKey: "botUsername") }
        if let support = me.supportURL { defaults.set(support.absoluteString, forKey: "supportURL") }
        // Без согласия бэкенд не присылает подписки — не трогаем сохранённые ссылки.
        if me.consentAccepted {
            store(me.hasSubscription ? me.subscription?.url : nil, for: .primary)
            store(me.reserve?.url, for: .reserve)
        }
        recomputeInfo()
    }

    /// Сохраняет ссылку из аккаунта. Если бэкенд ссылку не прислал, оставляем ту, что была
    /// (например, добавленную вручную), — она удаляется только при выходе.
    private func store(_ value: String?, for slot: SubscriptionSlot) {
        guard let value, !value.isEmpty, Keychain.read(slot.keychainKey) != value else { return }
        Keychain.save(value, for: slot.keychainKey)
    }

    private func endSession() {
        Keychain.delete(Keychain.sessionKey)
        AccountStore.clear()
        hasSession = false
        account = nil
        recomputeInfo()
        if subscriptionURL(.primary) == nil && subscriptionURL(.reserve) == nil { isLoggedIn = false }
    }

    /// Вход по ссылке подписки. Возвращает текст ошибки или nil, если вход удался.
    func login(with raw: String) async -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let link = Self.extractSubscriptionURL(from: text) else {
            return "Это не похоже на ссылку подписки. Она начинается с https://"
        }
        if isDemo {
            isLoggedIn = true
            selectedTab = .home
            return nil
        }
        do {
            let (data, meta) = try await SubscriptionService.fetch(link)
            let parsed = try SubscriptionService.parse(data)
            Keychain.save(link.absoluteString, for: Keychain.subscriptionKey)
            SubscriptionService.save(data: data, meta: meta)
            self.meta = meta
            primaryParsed = parsed
            rebuild()
            refreshError = nil
            isLoggedIn = true
            selectedTab = .home
            Task { await pingAll() }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Добавить ссылку резервного подключения вручную (для входа по ссылке).
    func addReserve(with raw: String) async -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let link = Self.extractSubscriptionURL(from: text) else {
            return "Это не похоже на ссылку подписки. Она начинается с https://"
        }
        if isDemo { return nil }
        do {
            let (data, meta) = try await SubscriptionService.fetch(link)
            let parsed = try SubscriptionService.parse(data, slot: .reserve)
            Keychain.save(link.absoluteString, for: Keychain.reserveKey)
            SubscriptionService.save(data: data, meta: meta, slot: .reserve)
            reserveMeta = meta
            reserveParsed = parsed
            reserveError = nil
            rebuild()
            Task { await ping(parsed.routes.map(\.id)) }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func logout() {
        let token = sessionToken
        Task {
            await vpn.disconnect()
            if let token { await AccountAPI.logout(token) }
        }
        cancelLogin()
        Keychain.delete(Keychain.subscriptionKey)
        Keychain.delete(Keychain.reserveKey)
        endSession()
        SubscriptionService.clearCache()
        routes = []
        configs = [:]
        primaryParsed = nil
        reserveParsed = nil
        meta = nil
        reserveMeta = nil
        subscription = .empty
        reserve = nil
        refreshError = nil
        reserveError = nil
        accountError = nil
        connectedRouteID = nil
        defaults.removeObject(forKey: SettingsKey.connectedRoute)
        isLoggedIn = false
    }

    func handle(url: URL) {
        if url.scheme == "secretclub", url.host == "login" {
            pollNow()
            return
        }
        // Ссылки из виджетов.
        if url.scheme == "secretclub", let host = url.host {
            switch host {
            case "home":
                selectedTab = .home
                return
            case "diagnostics":
                selectedTab = .settings
                settingsPath = [.diagnostics]
                return
            case "servers":
                selectedTab = .home
                showServers = true
                return
            case "subscription":
                selectedTab = .settings
                settingsPath = [.subscription]
                return
            default:
                break
            }
        }
        Task {
            if let error = await login(with: url.absoluteString) { refreshError = error }
        }
    }

    /// Принимает https-ссылку подписки или secretclub://import?url=<ссылка>.
    static func extractSubscriptionURL(from text: String) -> URL? {
        guard var comps = URLComponents(string: text) else { return nil }
        if comps.scheme == "secretclub" {
            guard let inner = comps.queryItems?.first(where: { $0.name == "url" })?.value,
                  let innerComps = URLComponents(string: inner) else { return nil }
            comps = innerComps
        }
        guard comps.scheme == "https", let host = comps.host, !host.isEmpty, comps.path.count > 1 else { return nil }
        // Ссылку на /json или /v2ray-json приводим к базовой.
        if let last = comps.path.split(separator: "/").last, ["json", "v2ray-json", "xray-json"].contains(String(last)) {
            comps.path = "/" + comps.path.split(separator: "/").dropLast().joined(separator: "/")
        }
        return comps.url
    }

    // MARK: - Вход через Telegram

    /// Получает код входа у бэкенда. Открыть Telegram должен экран (через openURL).
    func beginTelegramLogin() async -> LoginTicket? {
        if isDemo {
            loginTicket = DemoData.loginTicket
            loginPhase = .waiting
            return nil
        }
        if let ticket = loginTicket, ticket.expiresAt.timeIntervalSinceNow > 60 {
            loginPhase = .waiting
            startPolling()
            return ticket
        }
        loginPhase = .starting
        do {
            let ticket = try await AccountAPI.start()
            loginTicket = ticket
            ticket.save()
            loginPhase = .waiting
            startPolling()
            return ticket
        } catch {
            loginPhase = .failed(error.localizedDescription)
            return nil
        }
    }

    func cancelLogin() {
        pollTask?.cancel()
        pollTask = nil
        loginTicket = nil
        LoginTicket.clear()
        loginPhase = nil
        showLogin = false
    }

    private func startPolling() {
        guard !isDemo else { return }
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let ticket = self.loginTicket else { return }
                if ticket.expiresAt < Date() {
                    self.loginFailed("Время на вход истекло. Нажмите «Войти через Telegram» ещё раз.")
                    return
                }
                if await self.pollOnce(ticket) { return }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// Проверить вход сразу (вернулись из Telegram).
    func pollNow() {
        guard !isDemo, let ticket = loginTicket, loginPhase == .waiting else { return }
        Task { _ = await pollOnce(ticket) }
    }

    /// true — опрос можно прекращать (вошли или вход больше невозможен).
    private func pollOnce(_ ticket: LoginTicket) async -> Bool {
        guard !pollInFlight else { return false }
        guard loginTicket?.code == ticket.code else { return true }
        pollInFlight = true
        defer { pollInFlight = false }
        do {
            switch try await AccountAPI.poll(ticket) {
            case .pending:
                return false
            case .ok(let token, let me):
                await finishLogin(token: token, me: me)
                return true
            }
        } catch let error as AccountError {
            if let status = error.status, [400, 403, 404, 410].contains(status) {
                if loginTicket?.code == ticket.code { loginFailed(error.localizedDescription) }
                return true
            }
            return false
        } catch {
            return false
        }
    }

    private func loginFailed(_ message: String) {
        pollTask?.cancel()
        loginTicket = nil
        LoginTicket.clear()
        loginPhase = .failed(message)
    }

    private func finishLogin(token: String, me: [String: Any]) async {
        loginTicket = nil
        LoginTicket.clear()
        Keychain.save(token, for: Keychain.sessionKey)
        hasSession = true
        accountError = nil
        if me.isEmpty { await refreshAccount() } else { applyAccount(me) }
        loginPhase = nil
        showLogin = false
        isLoggedIn = true
        selectedTab = .home
        await refresh(includeAccount: false)
        if !vpn.isActive { await pingAll() }
    }

    // MARK: - Действия с аккаунтом

    private func accountAction(_ name: String, _ body: (String) async throws -> [String: Any]?) async {
        guard let token = sessionToken, busyAction == nil else { return }
        busyAction = name
        defer { busyAction = nil }
        do {
            if let me = try await body(token) { applyAccount(me) }
            accountError = nil
        } catch let error as AccountError where error.status == 401 {
            endSession()
            accountError = "Вход в аккаунт сброшен. Войдите через Telegram ещё раз."
        } catch {
            accountError = error.localizedDescription
        }
    }

    func acceptConsent() async {
        guard let version = account?.consentVersion else { return }
        await accountAction("consent") { try await AccountAPI.acceptConsent($0, version: version) }
        await refresh(includeAccount: false)
        if !vpn.isActive { await pingAll() }
    }

    func startTrial() async {
        await accountAction("trial") { try await AccountAPI.startTrial($0) }
        await refresh(includeAccount: false)
        if !vpn.isActive { await pingAll() }
    }

    func createReserve() async {
        await accountAction("reserve") { try await AccountAPI.createReserve($0) }
        await refresh(includeAccount: false)
        let ids = routes.filter { $0.group == .reserve }.map(\.id)
        if !ids.isEmpty { await ping(ids) }
    }

    func unlink(_ device: Device, reserve: Bool) async {
        await accountAction("device:\(device.id)") { token in
            try await AccountAPI.deleteDevice(token, hwid: device.id, reserve: reserve)
            return try await AccountAPI.me(token)
        }
    }

    // MARK: - Сеть и пинг

    func refreshNetwork() async {
        guard !isDemo else { return }
        networkMode = .unknown
        let results = await NetworkProbe.run()
        probes = results
        probedAt = Date()
        networkMode = NetworkProbe.classify(results)
    }

    private func startPathMonitor() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = Self.pathHandler { [weak self] signature in
            Task { @MainActor in self?.pathChanged(signature) }
        }
        monitor.start(queue: DispatchQueue(label: "com.secretclub.path", qos: .utility))
        pathMonitor = monitor
    }

    /// Обработчик вызывается на фоновой очереди — собираем его вне главного актора.
    nonisolated private static func pathHandler(_ sink: @escaping @Sendable (String) -> Void) -> @Sendable (NWPath) -> Void {
        { path in sink(NetworkCheck.signature(path)) }
    }

    /// Сменился Wi‑Fi/мобильный интернет: старые замеры и режим сети больше не верны.
    private func pathChanged(_ signature: String) {
        let offline = signature == "none"
        if pathOffline != offline { pathOffline = offline }
        // Когда VPN включён, приложению может быть виден только туннель — это не смена сети.
        guard signature != "other" else { return }
        let kind: PathKind
        if offline { kind = .offline }
        else if signature.hasPrefix("wifi") { kind = .wifi }
        else if signature.hasPrefix("cellular") { kind = .cellular }
        else if signature.hasPrefix("wired") { kind = .wired }
        else { kind = .unknown }
        if pathKind != kind { pathKind = kind }
        let previous = pathSignature
        pathSignature = signature
        guard let previous, previous != signature else { return }
        for index in routes.indices {
            routes[index].ping = nil
            routes[index].unavailable = false
        }
        pingAt = [:]
        pingedAt = nil
        probedAt = nil
        switch vpn.state {
        case .connected, .connecting:
            // Смену сети расширение видит само (раньше приложения): перезапустит ядро, проверит
            // все серверы разом и при необходимости переключится. Здесь только сбрасываем экран.
            networkMode = .unknown
            tunnelHealthy = nil
        case .disconnected, .invalid:
            if signature == "none" {
                networkMode = .offline
                return
            }
            Task {
                try? await Task.sleep(for: .seconds(1))
                await refreshNetwork()
                if showServers || !energySaver { await pingAll() }
            }
        case .preparing, .disconnecting:
            networkMode = .unknown
        }
    }

    /// Сервер из отчёта расширения. Если подписка успела обновиться и id сменился — ищем по названию.
    private func resolveRoute(_ report: TunnelReport) -> String? {
        guard let id = report.routeID else { return nil }
        if configs[id] != nil || routes.contains(where: { $0.id == id }) { return id }
        guard let title = report.routeTitle else { return nil }
        return routes.first { "\($0.emoji) \($0.title)" == title || $0.remarks == title || $0.title == title }?.id
    }

    /// Отчёт расширения: сервер мог смениться сам, плюс свежая проверка сети и сервера.
    private func apply(_ report: TunnelReport) {
        if let id = resolveRoute(report), id != connectedRouteID {
            if connectedRouteID != nil { DiagLog.write("сервер сменился: «\(report.routeTitle ?? id)»", to: .app) }
            connectedRouteID = id
            defaults.set(id, forKey: SettingsKey.connectedRoute)
            if autoMode { autoRouteID = id }
            WidgetSync.reload()
        }
        if let raw = report.network, let mode = NetworkMode(rawValue: raw), mode != networkMode {
            networkMode = mode
        }
        if tunnelHealthy != report.healthy { tunnelHealthy = report.healthy }
        if let ms = report.pingMS, let id = report.routeID,
           let index = routes.firstIndex(where: { $0.id == id }), routes[index].ping != ms {
            routes[index].ping = ms
            routes[index].unavailable = false
            pingAt[id] = Date()
        }
        if report.noteID > lastNoteID {
            let first = lastNoteID == 0
            lastNoteID = report.noteID
            autoNotice = report.note
            // Первое сообщение после запуска приложения — старое, его не показываем.
            if !first, let note = report.note { showToast(note, icon: "arrow.triangle.2.circlepath") }
        }
    }

    /// Индикатор в шапке: режим сети, а если VPN включён и сервер не отвечает — об этом.
    var networkChip: (title: String, color: Color) {
        if vpn.state == .connected, tunnelHealthy == false { return ("Сервер не отвечает", Theme.red) }
        return (networkMode.short, networkMode.color)
    }

    /// Пинговать можно, когда туннель выключен (меряем сами) или полностью включён (меряет расширение).
    var canPing: Bool {
        guard !isDemo, !routes.isEmpty else { return false }
        switch vpn.state {
        case .connected, .disconnected, .invalid, .preparing: return true
        case .connecting, .disconnecting: return false
        }
    }

    func pingIfStale() async {
        guard canPing, vpn.state != .preparing else { return }
        if let pingedAt, Date().timeIntervalSince(pingedAt) < 180 { return }
        await pingAll()
    }

    func pingAll() async {
        let order = groupOrder + RouteGroup.allCases.filter { !groupOrder.contains($0) }
        let ids = routes.sorted { (order.firstIndex(of: $0.group) ?? 9) < (order.firstIndex(of: $1.group) ?? 9) }.map(\.id)
        await ping(ids)
    }

    private func setPing(_ id: String, _ ms: Int?, keepOnFailure: Bool = false) {
        pingingIDs.remove(id)
        guard let index = routes.firstIndex(where: { $0.id == id }) else { return }
        if ms == nil && keepOnFailure { return }
        routes[index].ping = ms
        routes[index].unavailable = ms == nil
        pingAt[id] = Date()
    }

    /// Дождаться, пока закончится уже идущий замер.
    private func waitForPing() async {
        while isPinging { try? await Task.sleep(for: .milliseconds(120)) }
    }

    private func lockXray() async {
        while xrayBusy { try? await Task.sleep(for: .milliseconds(100)) }
        xrayBusy = true
    }

    /// Пинг серверов параллельно, результат появляется у каждого сразу.
    /// Если замер уже идёт — ждём его и меряем своё (раньше запрос молча терялся).
    func ping(_ ids: [String]) async {
        if isDemo {
            isPinging = true
            pingingIDs = Set(ids)
            for id in ids {
                try? await Task.sleep(for: .milliseconds(60))
                pingingIDs.remove(id)
            }
            isPinging = false
            return
        }
        guard !ids.isEmpty else { return }
        await waitForPing()
        guard canPing else { return }
        isPinging = true
        pingingIDs = Set(ids)
        defer {
            isPinging = false
            pingingIDs = []
            pingedAt = Date()
        }
        if vpn.state == .connected {
            await pingThroughTunnel(ids)
            return
        }
        let items = ids.compactMap { id in configs[id].map { (id: id, raw: $0) } }
        await lockXray()
        defer { xrayBusy = false }
        let ok = await PingService.run(items) { [weak self] id, ms in
            self?.setPing(id, ms)
        }
        if !ok { await pingWithBatch(ids.filter { pingingIDs.contains($0) }) }
    }

    /// VPN включён: расширение меряет время до серверов своими соединениями, мимо туннеля.
    private func pingThroughTunnel(_ ids: [String]) async {
        var udpIDs = Set<String>()
        let targets = ids.compactMap { id -> PingTarget? in
            guard let raw = configs[id], let route = routes.first(where: { $0.id == id }) else { return nil }
            let udp = route.transport == .hysteria2
            if udp { udpIDs.insert(id) }
            return ConfigBuilder.pingTarget(id: id, raw: raw, udp: udp)
        }
        guard !targets.isEmpty else { return }
        let report = await vpn.send(TunnelCommand(kind: .ping, targets: targets), attempts: 1, timeout: 8)
        guard let pings = report?.pings else { return }
        for target in targets {
            // QUIC-рукопожатие проходит не у всех серверов Hysteria2 — неудачу не считаем «нет ответа».
            setPing(target.id, pings[target.id], keepOnFailure: udpIDs.contains(target.id))
        }
    }

    /// Запасной способ (если общий конфиг не запустился): pingBatch ядра по 5 серверов.
    private func pingWithBatch(_ ids: [String]) async {
        var queue = ids
        while !queue.isEmpty {
            let chunk = Array(queue.prefix(5))
            queue.removeFirst(chunk.count)
            let items = chunk.compactMap { id -> (id: String, json: String, tag: String)? in
                guard let raw = configs[id], let p = ConfigBuilder.pingConfig(raw) else { return nil }
                return (id, p.json, p.tag)
            }
            let results = await XrayEngine.pingChunk(items.map { ($0.json, $0.tag) }, timeout: 4)
            if vpn.state == .connected || vpn.state == .connecting { return }
            for (item, ms) in zip(items, results) { setPing(item.id, ms) }
        }
    }

    /// Порядок групп для «Авто»: резерв — только если остальное не работает (у него ограничен трафик).
    private var groupOrder: [RouteGroup] {
        networkMode == .whitelist ? [.bridge, .reserve] : [.regular, .bridge, .reserve]
    }

    private func candidates(_ group: RouteGroup) -> [Route] {
        let all = routes.filter { $0.group == group }
        let pref = transportPreference
        let preferred = all.filter { pref.matches($0) }
        return preferred.isEmpty ? all : preferred
    }

    /// Лучший сервер по последним замерам (без новых проверок).
    func bestCachedRoute() -> Route? {
        for group in groupOrder {
            if let best = candidates(group).filter({ $0.ping != nil }).min(by: { $0.ping! < $1.ping! }) { return best }
        }
        return nil
    }

    /// Замеры группы свежие: хотя бы один сервер ответил за последние 2 минуты в этой же сети.
    private func isFresh(_ list: [Route]) -> Bool {
        list.contains { route in
            route.ping != nil && (pingAt[route.id].map { Date().timeIntervalSince($0) < 120 } ?? false)
        }
    }

    /// С какого сервера начать в «Авто»: без замеров и ожидания. Расширение сразу после запуска
    /// проверит его и все запасные параллельно (через ядро) и при необходимости переключится само.
    private func initialAutoRoute() -> Route? {
        if let best = bestCachedRoute(), isFresh([best]) { return best }
        if let id = connectedRouteID, let route = routes.first(where: { $0.id == id }),
           route.group != .reserve, !route.unavailable, !isNodeOffline(route) { return route }
        for group in groupOrder {
            if let route = candidates(group).first(where: { !$0.unavailable && !isNodeOffline($0) }) { return route }
        }
        return routes.first
    }

    // MARK: - Статус узлов

    /// Онлайн и нагрузка узлов от бэкенда (только со входом через Telegram). Не чаще раза в 2 минуты.
    func refreshNodes() async {
        guard !isDemo, let token = sessionToken else { return }
        if let nodesAt, Date().timeIntervalSince(nodesAt) < 120 { return }
        nodesAt = Date()
        guard let json = try? await AccountAPI.call("/api/app/nodes", method: "GET", token: token, timeout: 8),
              let list = json["nodes"] as? [[String: Any]] else { return }
        var map: [String: NodeStatus] = [:]
        for item in list {
            guard let host = (item["host"] as? String)?.lowercased(), !host.isEmpty else { continue }
            map[host] = NodeStatus(online: item["online"] as? Bool ?? true, load: (item["load"] as? NSNumber)?.doubleValue)
        }
        nodes = map
    }

    /// Свежий статус узла этого сервера (по адресу из конфига), если бэкенд его знает.
    private func nodeStatus(_ route: Route) -> NodeStatus? {
        guard let nodesAt, Date().timeIntervalSince(nodesAt) < 600, !nodes.isEmpty,
              let raw = configs[route.id], let outbounds = raw["outbounds"] as? [[String: Any]],
              let main = RouteClassifier.mainOutbound(outbounds) else { return nil }
        return nodes[RouteClassifier.address(main).lowercased()]
    }

    private func isNodeOffline(_ route: Route) -> Bool { nodeStatus(route)?.online == false }

    // MARK: - Подключение

    func request(for route: Route) -> ConnectRequest? {
        guard let raw = configs[route.id] else { return nil }
        let runtime = ConfigBuilder.runtime(raw, options: settings)
        guard let json = ConfigBuilder.json(runtime) else { return nil }
        return ConnectRequest(config: json,
                              routeID: route.id,
                              routeTitle: "\(route.emoji) \(route.title)",
                              onDemand: AppSettings.autoConnect,
                              killSwitch: defaults.bool(forKey: SettingsKey.killSwitch))
    }

    /// Запасные серверы для расширения: лучшие из каждой группы с готовыми конфигами.
    /// По ним оно само переключится, если сменилась сеть или сервер перестал отвечать.
    func makePool() -> AutoPool {
        var list: [AutoCandidate] = []
        var seen = Set<String>()
        func add(_ route: Route) {
            guard !seen.contains(route.id), let raw = configs[route.id], let req = request(for: route) else { return }
            seen.insert(route.id)
            list.append(AutoCandidate(id: route.id, title: req.routeTitle, group: route.group.rawValue, config: req.config,
                                      target: ConfigBuilder.pingTarget(id: route.id, raw: raw, udp: route.transport == .hysteria2),
                                      load: nodeStatus(route)?.load))
        }
        for group in RouteGroup.allCases {
            // Выключенные узлы (по данным бэкенда) — в конец; дальше по последнему замеру.
            let ranked = candidates(group).sorted { a, b in
                let oa = isNodeOffline(a), ob = isNodeOffline(b)
                if oa != ob { return !oa }
                return (a.ping ?? Int.max) < (b.ping ?? Int.max)
            }
            ranked.prefix(6).forEach(add)
        }
        if let id = connectedRouteID, let route = routes.first(where: { $0.id == id }) { add(route) }
        return AutoPool(auto: autoMode, candidates: list, updatedAt: Date())
    }

    private func syncPool() async {
        guard !isDemo, vpn.state == .connected else { return }
        await vpn.sendPool(makePool())
    }

    /// Проверка конфига самим ядром до запуска туннеля — понятная ошибка вместо «не подключилось».
    private func validate(_ route: Route) async -> String? {
        guard let raw = configs[route.id] else { return "Нет настроек для «\(route.title)»" }
        let runtime = ConfigBuilder.runtime(raw, options: settings)
        guard let json = ConfigBuilder.validation(runtime, assetDir: Bundle.main.resourcePath) else { return "Не удалось собрать конфиг" }
        let key = Self.digest(json)
        if validated.contains(key) { return nil }
        await lockXray()
        defer { xrayBusy = false }
        do {
            try await XrayEngine.test(json)
            rememberValid(key)
            return nil
        } catch {
            guard Self.isCoreBusy(error) else {
                return "Конфиг «\(route.title)» не прошёл проверку: \(error.localizedDescription)"
            }
        }
        // Ядро в приложении ещё занято замером — останавливаем и проверяем ещё раз.
        _ = try? await XrayEngine.call("stopXray")
        do {
            try await XrayEngine.test(json)
            return nil
        } catch {
            // Проверка — только подсказка; если ядро так и не освободилось, просто подключаемся.
            if Self.isCoreBusy(error) { return nil }
            return "Конфиг «\(route.title)» не прошёл проверку: \(error.localizedDescription)"
        }
    }

    private func rememberValid(_ key: String) {
        validated.removeAll { $0 == key }
        validated.append(key)
        if validated.count > 60 { validated.removeFirst(validated.count - 60) }
        defaults.set(validated, forKey: "validatedConfigs")
    }

    static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private static func isCoreBusy(_ error: Error) -> Bool {
        error.localizedDescription.contains("isolated process")
    }

    func toggleConnection() async {
        switch vpn.state {
        case .connected, .connecting, .disconnecting, .preparing:
            await disconnect()
        case .disconnected, .invalid:
            await connect()
        }
    }

    /// Выключить VPN или отменить подключение, которое ещё идёт.
    func disconnect() async {
        let background = BackgroundWork.begin("Выключение VPN")
        defer { background.end() }
        connectToken += 1
        phase = nil
        isSwitching = false
        vpn.lastError = nil
        if vpn.state == .preparing {
            vpn.cancelPreparing(nil)
            return
        }
        await vpn.disconnect()
        vpn.lastError = nil
    }

    func connect() async {
        let background = BackgroundWork.begin("Подключение VPN")
        defer { background.end() }
        connectToken += 1
        let token = connectToken
        if isDemo {
            vpn.lastError = nil
            if let r = activeRoute, let req = demoRequest(r) { try? await vpn.connect(req) }
            return
        }
        vpn.beginPreparing()
        autoNotice = nil
        tunnelHealthy = nil
        if routes.isEmpty {
            phase = "Загружаем серверы…"
            await refreshSubscription()
            guard token == connectToken else { return }
        }
        guard !routes.isEmpty else {
            phase = nil
            vpn.cancelPreparing(refreshError ?? "В подписке нет серверов.")
            return
        }
        let route: Route?
        if autoMode {
            // Замер, начатый раньше (например, на экране локаций), не дублируем — берём что есть.
            route = initialAutoRoute()
            autoRouteID = route?.id
        } else {
            route = routes.first { $0.id == selectedRouteID }
        }
        guard let route else {
            phase = nil
            vpn.cancelPreparing(autoMode ? "Ни один сервер не ответил. Проверьте интернет или выберите сервер вручную." : "Выберите сервер.")
            return
        }
        phase = "Проверяем сервер…"
        let problem = await validate(route)
        guard token == connectToken else { return }
        if let problem {
            phase = nil
            vpn.cancelPreparing(problem)
            return
        }
        phase = nil
        guard var req = request(for: route) else {
            vpn.cancelPreparing("Не удалось собрать конфиг для «\(route.title)».")
            return
        }
        connectedRouteID = route.id
        defaults.set(route.id, forKey: SettingsKey.connectedRoute)
        req.pool = TunnelCoding.encode(makePool()).map { String(decoding: $0, as: UTF8.self) }
        do {
            try await vpn.connect(req)
            // После первого удачного подключения — один раз спросить про уведомления (напоминания о продлении).
            Task {
                try? await Task.sleep(for: .seconds(2))
                await Reminders.askOnce()
                sharedSubscriptionKey = nil
                shareSubscription()
            }
        } catch {
            guard token == connectToken else { return }
            vpn.lastError = error.localizedDescription
            if autoMode, let index = routes.firstIndex(where: { $0.id == route.id }) {
                routes[index].unavailable = true
                routes[index].ping = nil
            }
        }
    }

    private func demoRequest(_ route: Route) -> ConnectRequest? {
        ConnectRequest(config: "{}", routeID: route.id, routeTitle: route.title, onDemand: false, killSwitch: false)
    }

    /// Переключиться на другой сервер, не выключая VPN.
    private func switchTo(_ route: Route) async {
        guard vpn.state == .connected, route.id != connectedRouteID else {
            await syncPool()
            return
        }
        isSwitching = true
        let background = BackgroundWork.begin("Смена сервера")
        defer {
            isSwitching = false
            background.end()
        }
        if isDemo {
            try? await Task.sleep(for: .seconds(1.3))
            connectedRouteID = route.id
            return
        }
        if let problem = await validate(route) {
            vpn.lastError = problem
            return
        }
        guard let req = request(for: route) else { return }
        connectedRouteID = route.id
        defaults.set(route.id, forKey: SettingsKey.connectedRoute)
        autoNotice = nil
        if await vpn.reload(req) {
            await syncPool()
            return
        }
        await vpn.disconnect()
        var full = req
        full.pool = TunnelCoding.encode(makePool()).map { String(decoding: $0, as: UTF8.self) }
        do { try await vpn.connect(full) } catch { vpn.lastError = error.localizedDescription }
    }

    func selectAuto() {
        autoMode = true
        defaults.set(true, forKey: SettingsKey.autoMode)
        guard vpn.state == .connected else { return }
        if let best = bestCachedRoute() {
            autoRouteID = best.id
            Task { await switchTo(best) }
        } else {
            Task { await syncPool() }
        }
    }

    func select(_ route: Route) {
        autoMode = false
        selectedRouteID = route.id
        defaults.set(false, forKey: SettingsKey.autoMode)
        defaults.set(route.id, forKey: SettingsKey.selectedRoute)
        if vpn.state == .connected { Task { await switchTo(route) } }
    }

    /// Настройки маршрутизации поменялись — применяем к работающему туннелю.
    func settingsChanged() {
        guard !isDemo, vpn.state == .connected else { return }
        settingsTask?.cancel()
        settingsTask = Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled, let id = connectedRouteID, let route = routes.first(where: { $0.id == id }),
                  let req = request(for: route) else { return }
            _ = await vpn.reload(req)
            await syncPool()
        }
    }

    func autoConnectChanged(_ enabled: Bool) {
        AppGroup.defaults?.set(enabled, forKey: SharedKey.autoConnect)
        DiagLog.write("«Держать VPN включённым»: \(enabled ? "вкл" : "выкл")", to: .app)
        Task { await vpn.setOnDemand(enabled) }
    }

    // MARK: - Состояние кнопки

    /// Подписка (или хотя бы резерв) позволяет подключаться.
    var subscriptionUsable: Bool { subscription.isActive || (reserve?.isActive ?? false) }

    var isOffline: Bool { pathOffline || networkMode == .offline }

    var power: PowerState {
        switch vpn.state {
        case .preparing, .connecting:
            return isOffline ? .waiting : .connecting
        case .connected:
            if isOffline { return .waiting }
            if isSwitching { return .switching }
            if autoMode, vpn.report?.checking == true, tunnelHealthy == false { return .switching }
            return .connected
        case .disconnecting:
            return .off
        case .disconnected, .invalid:
            if !subscriptionUsable && !needsConsent && !needsSubscription { return .expired }
            return vpn.lastError != nil ? .failed : .off
        }
    }

    /// Сервер, который показываем в капсуле и сводке.
    var displayRoute: Route? {
        switch power {
        case .connected, .switching, .waiting:
            return routes.first { $0.id == connectedRouteID } ?? activeRoute
        default:
            return autoMode ? nil : routes.first { $0.id == selectedRouteID }
        }
    }

    /// Сейчас идёт замер всех серверов.
    var isMeasuring: Bool { isPinging || !pingingIDs.isEmpty }

    /// Самый быстрый из обычных серверов по последним замерам.
    var fastestRouteID: String? {
        routes.filter { $0.group != .reserve && $0.ping != nil && !$0.unavailable }
            .min { ($0.ping ?? .max) < ($1.ping ?? .max) }?.id
    }

    /// Нажатие на кнопку.
    func tapPower() {
        switch power {
        case .expired:
            showToast("Подписка закончилась — продлите в Telegram", icon: "creditcard", tone: .bad)
        case .off, .failed:
            Task { await connect() }
        case .connecting, .connected, .switching, .waiting:
            Task { await disconnect() }
        }
    }

    /// Выбор в шторке серверов: nil — «Авто». Если VPN выключен — сразу подключаемся.
    func choose(_ route: Route?) {
        let changed = route.map { autoMode || selectedRouteID != $0.id } ?? !autoMode
        if let route { select(route) } else { selectAuto() }
        guard changed else { return }
        if power == .off || power == .failed { Task { await connect() } }
    }

    /// Плашки на переходах состояний (вызывается из корня).
    func powerChanged(from old: PowerState, to new: PowerState) {
        switch (old, new) {
        case (.connected, .waiting), (.switching, .waiting):
            showToast("Нет интернета — подключимся сами, когда появится", icon: "wifi.slash", tone: .bad)
        case (.waiting, .connected):
            showToast("Интернет вернулся — снова под защитой", icon: "checkmark.shield.fill", tone: .good)
        default:
            break
        }
    }

    func showToast(_ text: String, icon: String = "arrow.triangle.2.circlepath", tone: ToastMessage.Tone = .neutral) {
        toastTask?.cancel()
        let message = ToastMessage(text: text, icon: icon, tone: tone)
        let hadToast = toast != nil
        toastTask = Task { [weak self] in
            if hadToast {
                self?.toast = nil
                try? await Task.sleep(for: .milliseconds(260))
            }
            guard !Task.isCancelled else { return }
            self?.toast = message
            try? await Task.sleep(for: .seconds(3.6))
            guard !Task.isCancelled, self?.toast?.id == message.id else { return }
            self?.toast = nil
        }
    }

    func dismissToast() {
        toastTask?.cancel()
        toast = nil
    }

    // MARK: - Отчёт для поддержки

    func supportReport(steps: [String] = []) -> String {
        var lines = ["SecretClub \(Config.version)", "Сеть: \(networkMode.title), интерфейс: \(pathKind)"]
        lines += probes.map { "  \($0.title): \($0.ms.map { "\($0) мс" } ?? "нет ответа")" }
        lines.append("VPN: \(String(describing: vpn.state)), кнопка: \(String(describing: power))")
        if let r = vpn.report {
            lines.append("Ядро: \(r.coreVersion), работает: \(r.running ? "да" : "нет")\(r.memoryMB.map { ", память \(Int($0)) МБ" } ?? "")\(r.multi == true ? ", проверка запасных: параллельно" : "")")
            if let e = r.error { lines.append("Ошибка ядра: \(e)") }
            if let h = r.healthy { lines.append("Сервер отвечает: \(h ? "да" : "нет")\(r.pingMS.map { ", \($0) мс" } ?? "")") }
            if let ms = r.lastSwitchMS { lines.append("Последнее переключение: \(String(format: "%.1f", Double(ms) / 1000)) с") }
            if let source = r.counters { lines.append("Счётчики трафика: \(source == "core" ? "ядро" : "интерфейс utun")") }
            if let events = r.events, !events.isEmpty {
                lines.append("Журнал расширения:")
                lines += events.suffix(16).map { "  \($0)" }
            }
        }
        if vpn.state == .connected {
            let link = vpn.lastReportAt.map { "ответ \(Int(Date().timeIntervalSince($0))) с назад" } ?? "ответов не было"
            lines.append("Связь с расширением: \(link)\(vpn.pollFailures > 0 ? ", сбоев подряд: \(vpn.pollFailures)" : "")")
        }
        if let route = activeRoute { lines.append("Маршрут: \(route.remarks) [\(route.group.rawValue), \(route.transportTitle)]") }
        lines.append("Режим: \(autoMode ? "Авто" : "вручную"), способ: \(TransportPreference(rawValue: defaults.string(forKey: SettingsKey.transport) ?? "")?.title ?? "Авто")")
        lines.append("Серверов: \(routes.count), подписка: \(subscription.plan), \(subscription.status.title)")
        lines += steps.map { "  \($0)" }
        lines += routes.prefix(30).map { "  \($0.remarks): \($0.unavailable ? "нет ответа" : ($0.ping.map { "\($0) мс" } ?? "—"))" }
        if let e = vpn.lastError { lines.append("Ошибка: \(e)") }
        if let e = refreshError { lines.append("Подписка: \(e)") }
        if let n = autoNotice { lines.append("Авто: \(n)") }
        return lines.joined(separator: "\n")
    }
}

extension TransportPreference {
    func matches(_ route: Route) -> Bool {
        switch self {
        case .auto: return true
        case .fast: return route.transport == .hysteria2
        case .stable: return route.transport != .hysteria2
        }
    }
}
