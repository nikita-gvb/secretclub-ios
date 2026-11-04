import SwiftUI
import Observation

enum AppTab: String, Hashable {
    case home, locations, subscription, settings
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

    @ObservationIgnored private var configs: [String: [String: Any]] = [:]
    @ObservationIgnored private var primaryParsed: ParsedSubscription?
    @ObservationIgnored private var reserveParsed: ParsedSubscription?
    @ObservationIgnored private var settingsTask: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var pollInFlight = false
    @ObservationIgnored private let defaults = UserDefaults.standard

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
            probes = DemoData.probes
            vpn.enableDemo(connected: initialScreen != "disconnected" && initialScreen != "locations")
            connectedRouteID = autoRouteID
            if initialScreen == "login" {
                showLogin = true
                loginPhase = .waiting
                loginTicket = DemoData.loginTicket
            }
            if initialScreen == "locations" { pingingIDs = ["de-cdn", "ru-cdn"] }
        } else {
            hasSession = Keychain.read(Keychain.sessionKey) != nil
            isLoggedIn = hasSession || Keychain.read(Keychain.subscriptionKey) != nil
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

        switch initialScreen {
        case "locations": selectedTab = .locations
        case "subscription": selectedTab = .subscription
        case "settings", "diagnostics", "exceptions": selectedTab = .settings
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
        await vpn.load()
        if let reportRoute = vpn.report?.routeID { connectedRouteID = reportRoute }
        if loginTicket != nil { startPolling() }
        if !vpn.isActive { await refreshNetwork() }
        guard isLoggedIn else { return }
        await refreshSubscription()
        if !vpn.isActive && !energySaver { await pingAll() }
    }

    private var energySaver: Bool { defaults.object(forKey: SettingsKey.energySaver) as? Bool ?? true }

    func becameActive() async {
        vpn.setForeground(true)
        guard !isDemo else { return }
        if loginTicket != nil {
            pollNow()
            return
        }
        guard isLoggedIn else { return }
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
    }

    /// Пинг серверов параллельно, результат появляется у каждого сразу.
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
        guard canPing, !isPinging, !ids.isEmpty else { return }
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

    private func pickAuto() async -> Route? {
        if networkMode == .unknown || (probedAt.map { Date().timeIntervalSince($0) > 120 } ?? true) {
            phase = "Проверяем сеть…"
            await refreshNetwork()
        }
        let fresh = pingedAt.map { Date().timeIntervalSince($0) < 300 } ?? false
        for group in groupOrder {
            let list = candidates(group)
            guard !list.isEmpty else { continue }
            if !fresh || list.allSatisfy({ $0.ping == nil }) {
                phase = "Ищем быстрый сервер: \(group.shortTitle)…"
                await ping(list.map(\.id))
            }
            let updated = candidates(group)
            if let best = updated.filter({ $0.ping != nil }).min(by: { $0.ping! < $1.ping! }) { return best }
        }
        return nil
    }

    // MARK: - Подключение

    func request(for route: Route) -> ConnectRequest? {
        guard let raw = configs[route.id] else { return nil }
        let runtime = ConfigBuilder.runtime(raw, options: settings)
        guard let json = ConfigBuilder.json(runtime) else { return nil }
        return ConnectRequest(config: json,
                              routeID: route.id,
                              routeTitle: "\(route.emoji) \(route.title)",
                              onDemand: defaults.bool(forKey: SettingsKey.autoConnect),
                              killSwitch: defaults.bool(forKey: SettingsKey.killSwitch))
    }

    /// Проверка конфига самим ядром до запуска туннеля — понятная ошибка вместо «не подключилось».
    private func validate(_ route: Route) async -> String? {
        guard let raw = configs[route.id] else { return "Нет настроек для «\(route.title)»" }
        let runtime = ConfigBuilder.runtime(raw, options: settings)
        guard let json = ConfigBuilder.validation(runtime, assetDir: Bundle.main.resourcePath) else { return "Не удалось собрать конфиг" }
        do {
            try await XrayEngine.test(json)
            return nil
        } catch {
            return "Конфиг «\(route.title)» не прошёл проверку: \(error.localizedDescription)"
        }
    }

    func toggleConnection() async {
        switch vpn.state {
        case .connected, .connecting, .disconnecting:
            await vpn.disconnect()
        case .preparing:
            break
        case .disconnected, .invalid:
            await connect()
        }
    }

    func connect() async {
        if isDemo {
            if let r = activeRoute, let req = demoRequest(r) { try? await vpn.connect(req) }
            return
        }
        vpn.beginPreparing()
        if routes.isEmpty {
            phase = "Загружаем серверы…"
            await refreshSubscription()
        }
        guard !routes.isEmpty else {
            phase = nil
            vpn.cancelPreparing(refreshError ?? "В подписке нет серверов.")
            return
        }
        let route: Route?
        if autoMode {
            route = await pickAuto()
            autoRouteID = route?.id
        } else {
            route = routes.first { $0.id == selectedRouteID }
        }
        guard let route else {
            phase = nil
            vpn.cancelPreparing(autoMode ? "Ни один сервер не ответил. Проверьте интернет или выберите локацию вручную." : "Выберите локацию.")
            return
        }
        phase = "Проверяем конфиг…"
        if let problem = await validate(route) {
            phase = nil
            vpn.cancelPreparing(problem)
            return
        }
        phase = nil
        guard let req = request(for: route) else {
            vpn.cancelPreparing("Не удалось собрать конфиг для «\(route.title)».")
            return
        }
        connectedRouteID = route.id
        defaults.set(route.id, forKey: SettingsKey.connectedRoute)
        do {
            try await vpn.connect(req)
        } catch {
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
        guard vpn.state == .connected, route.id != connectedRouteID else { return }
        if isDemo {
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
        if await vpn.reload(req) { return }
        await vpn.disconnect()
        do { try await vpn.connect(req) } catch { vpn.lastError = error.localizedDescription }
    }

    func selectAuto() {
        autoMode = true
        defaults.set(true, forKey: SettingsKey.autoMode)
        if vpn.state == .connected, let best = bestCachedRoute() {
            autoRouteID = best.id
            Task { await switchTo(best) }
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
        }
    }

    func autoConnectChanged(_ enabled: Bool) {
        Task { await vpn.setOnDemand(enabled) }
    }
}

extension TransportPreference {
    func matches(_ route: Route) -> Bool {
        switch self {
        case .auto: return true
        case .reality: return route.transport == .reality
        case .xhttp: return route.transport == .xhttp || route.transport == .cdn
        case .hysteria2: return route.transport == .hysteria2
        }
    }
}
