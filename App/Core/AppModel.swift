import SwiftUI
import Observation

enum AppTab: String, Hashable {
    case home, locations, subscription, settings
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
    var subscription: SubscriptionInfo = .empty
    var meta: SubscriptionMeta?
    var isRefreshing = false
    var refreshError: String?
    var isPinging = false
    var pingedAt: Date?
    /// Что делаем, пока VPN «подключается» на стороне приложения.
    var phase: String?

    @ObservationIgnored private var configs: [String: [String: Any]] = [:]
    @ObservationIgnored private var settingsTask: Task<Void, Never>?
    @ObservationIgnored private let defaults = UserDefaults.standard

    let vpn = VPNController()
    let isDemo: Bool
    let initialScreen: String?

    init() {
        isDemo = defaults.bool(forKey: "demo")
        initialScreen = defaults.string(forKey: "screen")

        if isDemo {
            routes = DemoData.routes
            subscription = DemoData.subscription
            autoRouteID = DemoData.routes.first?.id
            isLoggedIn = initialScreen != "onboarding"
            networkMode = .normal
            probes = DemoData.probes
            vpn.enableDemo(connected: initialScreen != "disconnected")
            connectedRouteID = autoRouteID
        } else {
            isLoggedIn = Keychain.read(Keychain.subscriptionKey) != nil
            autoMode = defaults.object(forKey: SettingsKey.autoMode) as? Bool ?? true
            selectedRouteID = defaults.string(forKey: SettingsKey.selectedRoute)
            connectedRouteID = defaults.string(forKey: SettingsKey.connectedRoute)
            if isLoggedIn { loadCache() }
        }

        switch initialScreen {
        case "locations": selectedTab = .locations
        case "subscription": selectedTab = .subscription
        case "settings", "diagnostics", "exceptions": selectedTab = .settings
        default: selectedTab = .home
        }
    }

    // MARK: - Состояние

    var subscriptionURL: URL? {
        Keychain.read(Keychain.subscriptionKey).flatMap(URL.init(string:))
    }

    var activeRoute: Route? {
        let id: String?
        if vpn.isActive, vpn.state != .preparing, let connected = connectedRouteID {
            id = connected
        } else {
            id = autoMode ? (autoRouteID ?? bestCachedRoute()?.id) : selectedRouteID
        }
        return routes.first { $0.id == id } ?? (autoMode ? routes.first : nil)
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
        if !vpn.isActive { await refreshNetwork() }
        guard isLoggedIn else { return }
        await refreshSubscription()
        if !vpn.isActive && !energySaver { await pingAll() }
    }

    private var energySaver: Bool { defaults.object(forKey: SettingsKey.energySaver) as? Bool ?? true }

    func becameActive() async {
        vpn.setForeground(true)
        guard !isDemo, isLoggedIn else { return }
        let interval: TimeInterval = energySaver ? 3 * 3600 : 3600
        if let updated = meta?.updatedAt, Date().timeIntervalSince(updated) < interval { return }
        await refreshSubscription()
    }

    // MARK: - Подписка

    private func loadCache() {
        guard let cached = SubscriptionService.loadCache(),
              let parsed = try? SubscriptionService.parse(cached.0) else { return }
        apply(parsed, meta: cached.1)
    }

    private func apply(_ parsed: ParsedSubscription, meta: SubscriptionMeta) {
        let old = Dictionary(routes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        routes = parsed.routes.map { route in
            var r = route
            if let prev = old[route.id] {
                r.ping = prev.ping
                r.unavailable = prev.unavailable
            }
            return r
        }
        configs = parsed.configs
        self.meta = meta
        subscription = SubscriptionInfo(meta: meta)
        if let id = selectedRouteID, configs[id] == nil { selectedRouteID = nil }
        if !autoMode && selectedRouteID == nil { autoMode = true }
    }

    func refreshSubscription() async {
        guard !isDemo, let url = subscriptionURL, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let (data, meta) = try await SubscriptionService.fetch(url)
            let parsed = try SubscriptionService.parse(data)
            SubscriptionService.save(data: data, meta: meta)
            apply(parsed, meta: meta)
            refreshError = nil
        } catch {
            refreshError = error.localizedDescription
        }
    }

    /// Возвращает текст ошибки или nil, если вход удался.
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
            apply(parsed, meta: meta)
            refreshError = nil
            isLoggedIn = true
            selectedTab = .home
            Task { await pingAll() }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func logout() {
        Task { await vpn.disconnect() }
        Keychain.delete(Keychain.subscriptionKey)
        SubscriptionService.clearCache()
        routes = []
        configs = [:]
        meta = nil
        subscription = .empty
        connectedRouteID = nil
        defaults.removeObject(forKey: SettingsKey.connectedRoute)
        isLoggedIn = false
    }

    func handle(url: URL) {
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

    // MARK: - Сеть и пинг

    func refreshNetwork() async {
        guard !isDemo else { return }
        networkMode = .unknown
        let results = await NetworkProbe.run()
        probes = results
        probedAt = Date()
        networkMode = NetworkProbe.classify(results)
    }

    var canPing: Bool { !isDemo && !vpn.isActive && !routes.isEmpty }

    func pingIfStale() async {
        guard canPing else { return }
        if let pingedAt, Date().timeIntervalSince(pingedAt) < 180 { return }
        await pingAll()
    }

    func pingAll() async {
        let order = groupOrder
        let ids = routes.sorted { (order.firstIndex(of: $0.group) ?? 9) < (order.firstIndex(of: $1.group) ?? 9) }.map(\.id)
        await ping(ids)
    }

    /// Пинг через само ядро — показывает, работает ли сервер на самом деле.
    func ping(_ ids: [String]) async {
        if isDemo {
            isPinging = true
            try? await Task.sleep(for: .seconds(1))
            isPinging = false
            return
        }
        guard canPing, !isPinging else { return }
        isPinging = true
        defer {
            isPinging = false
            pingedAt = Date()
        }
        var queue = ids
        while !queue.isEmpty {
            let chunk = Array(queue.prefix(5))
            queue.removeFirst(chunk.count)
            let items = chunk.compactMap { id -> (id: String, json: String, tag: String)? in
                guard let raw = configs[id], let p = ConfigBuilder.pingConfig(raw) else { return nil }
                return (id, p.json, p.tag)
            }
            let results = await XrayEngine.pingChunk(items.map { ($0.json, $0.tag) }, timeout: 4)
            if vpn.isActive { return }
            for (item, ms) in zip(items, results) {
                guard let index = routes.firstIndex(where: { $0.id == item.id }) else { continue }
                routes[index].ping = ms
                routes[index].unavailable = ms == nil
            }
        }
    }

    /// Порядок групп для авто-режима в текущей сети.
    private var groupOrder: [RouteGroup] {
        networkMode == .whitelist ? [.bypass, .bridge, .regular] : [.regular, .bridge, .bypass]
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
        let order = networkMode == .whitelist ? [RouteGroup.bypass, .bridge] : groupOrder
        let fresh = pingedAt.map { Date().timeIntervalSince($0) < 300 } ?? false
        for group in order {
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
