import Foundation
import Network
import NetworkExtension
import os

/// Туннель SecretClub: поднимает utun и запускает ядро Xray с TUN-входом прямо на его дескрипторе.
/// Собственный трафик расширения (подключения к серверам) идёт мимо туннеля — так устроен iOS.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let log = Logger(subsystem: "com.secretclub.app.tunnel", category: "provider")
    /// Все обращения к ядру и к report — только на этой очереди.
    private let work = DispatchQueue(label: "com.secretclub.tunnel.work", qos: .userInitiated)
    private var report = TunnelReport()
    /// Локальный HTTP-вход ядра для проверки, работает ли сервер.
    private var healthPort = 0
    private var currentConfig: String?
    private var utunName: String?
    private var ifaceLast: (out: UInt32, inb: UInt32)?
    /// Запасные серверы «Авто» и наблюдение за сетью.
    private var pool: AutoPool?
    private var pathMonitor: NWPathMonitor?
    private var pathSignature: String?
    private var watchdog: DispatchSourceTimer?
    private var pendingCheck: DispatchWorkItem?
    private var pendingReason: CheckReason?
    private var evaluating = false
    private var lastCheck: Date?
    private var lastNetworkCheck: Date?
    private var failedAt: Date?
    private var lastTraffic: (up: Int64, down: Int64) = (0, 0)

    enum CheckReason: String {
        /// start — после запуска/смены сервера, network — сменилась сеть, stall — трафик уходит,
        /// а ответов нет, app — попросило приложение.
        case start, network, stall, app
    }

    // MARK: - Жизненный цикл

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        if (options?[TunnelOption.probe] as? NSNumber)?.boolValue == true {
            work.async { self.report.probe = true; self.report.coreVersion = XrayEngine.version }
            setTunnelNetworkSettings(Self.probeSettings()) { completionHandler($0) }
            return
        }

        let stored = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration
        let config = (options?[TunnelOption.config] as? String) ?? (stored?[TunnelOption.config] as? String)
        let routeID = (options?[TunnelOption.routeID] as? String) ?? (stored?[TunnelOption.routeID] as? String)
        let routeTitle = (options?[TunnelOption.routeTitle] as? String) ?? (stored?[TunnelOption.routeTitle] as? String)
        guard let config, !config.isEmpty else {
            completionHandler(Self.error("Нет настроек подключения. Откройте SecretClub и нажмите «Подключить»."))
            return
        }

        setTunnelNetworkSettings(Self.tunnelSettings()) { error in
            if let error {
                completionHandler(Self.error("Не удалось настроить туннель: \(error.localizedDescription)"))
                return
            }
            self.work.async {
                do {
                    self.loadPool(options?[TunnelOption.pool] as? String)
                    try self.startCore(config)
                    self.report.routeID = routeID
                    self.report.routeTitle = routeTitle
                    self.report.uplink = 0
                    self.report.downlink = 0
                    self.ifaceLast = self.utunName.flatMap(Self.interfaceBytes)
                    self.startMonitoring()
                    self.scheduleCheck(.start, delay: 3)
                    completionHandler(nil)
                } catch {
                    self.log.error("start failed: \(error.localizedDescription, privacy: .public)")
                    self.report.error = error.localizedDescription
                    completionHandler(Self.error("Ядро Xray не запустилось: \(error.localizedDescription)"))
                }
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        work.async {
            self.stopMonitoring()
            if self.report.running {
                XrayEngine.stopSync()
                self.report.running = false
            }
            completionHandler()
        }
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        if String(data: messageData, encoding: .utf8) == "ping" {
            completionHandler?(Data("pong".utf8))
            return
        }
        guard let command = TunnelCoding.decode(TunnelCommand.self, messageData) else {
            completionHandler?(nil)
            return
        }
        switch command.kind {
        case .status:
            work.async {
                self.updateCounters()
                self.report.memoryMB = Self.footprintMB
                completionHandler?(TunnelCoding.encode(self.report))
            }
        case .pool:
            work.async {
                if let pool = command.pool {
                    self.pool = pool
                    Self.savePool(pool)
                }
                completionHandler?(TunnelCoding.encode(self.report))
            }
        case .check:
            work.async {
                let reason: CheckReason = command.reason == "network" ? .network : .app
                // Свежая проверка уже есть — не дёргаем сеть лишний раз.
                let recent = self.lastCheck.map { Date().timeIntervalSince($0) < 20 } ?? false
                if !(reason == .app && recent && self.report.healthy == true) {
                    self.scheduleCheck(reason, delay: reason == .network ? 2 : 0)
                }
                completionHandler?(TunnelCoding.encode(self.report))
            }
        case .ping:
            // Свои соединения расширения идут мимо туннеля — замер честный.
            let targets = command.targets ?? []
            Task {
                let results = await LatencyProbe.direct(targets, timeout: 3)
                self.work.async {
                    var reply = self.report
                    reply.pings = results
                    completionHandler?(TunnelCoding.encode(reply))
                }
            }
        case .reload:
            guard let config = command.config else {
                work.async { completionHandler?(TunnelCoding.encode(self.report)) }
                return
            }
            work.async {
                self.reasserting = true
                if self.report.running {
                    XrayEngine.stopSync()
                    self.report.running = false
                }
                do {
                    try self.startCore(config)
                    self.report.routeID = command.routeID
                    self.report.routeTitle = command.routeTitle
                    self.report.healthy = nil
                    self.report.pingMS = nil
                } catch {
                    self.report.error = error.localizedDescription
                }
                self.reasserting = false
                if self.report.running { self.scheduleCheck(.start, delay: 2) }
                completionHandler?(TunnelCoding.encode(self.report))
            }
        }
    }

    // MARK: - Ядро

    /// Вызывать на очереди work, после setTunnelNetworkSettings.
    private func startCore(_ config: String) throws {
        if report.coreVersion.isEmpty { report.coreVersion = XrayEngine.version }
        guard let fd = Self.tunnelFileDescriptor(&utunName) else {
            throw Self.error("не найден дескриптор utun")
        }
        if healthPort == 0 { healthPort = XrayEngine.freePort() ?? 49228 }
        let prepared = try Self.prepare(config, fd: fd, healthPort: healthPort)
        try XrayEngine.runSync(prepared)
        currentConfig = config
        report.running = true
        report.startedAt = Date()
        report.error = nil
        log.info("xray started, fd \(fd), health \(self.healthPort)")
    }

    /// Подставляет в конфиг дескриптор туннеля, путь к geo-файлам и порт проверочного входа.
    static func prepare(_ text: String, fd: Int32, healthPort: Int) throws -> String {
        guard var root = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else {
            throw error("некорректная конфигурация")
        }
        var env = root["env"] as? [String: Any] ?? [:]
        env["xray.tun.fd"] = String(fd)
        if let resources = Bundle.main.resourcePath { env["xray.location.asset"] = resources }
        root["env"] = env

        var inbounds = root["inbounds"] as? [[String: Any]] ?? []
        let health: [String: Any] = ["tag": "health-in", "listen": "127.0.0.1", "port": healthPort,
                                     "protocol": "http", "settings": [String: Any]()]
        if let index = inbounds.firstIndex(where: { ($0["tag"] as? String) == "health-in" }) {
            inbounds[index] = health
        } else {
            inbounds.append(health)
        }
        root["inbounds"] = inbounds
        for key in ["stats", "metrics", "api"] { root.removeValue(forKey: key) }

        let data = try JSONSerialization.data(withJSONObject: root)
        return String(decoding: data, as: UTF8.self)
    }

    /// Смена сервера внутри работающего туннеля. На очереди work.
    private func swapCore(_ config: String, id: String?, title: String?) -> Bool {
        if report.running {
            XrayEngine.stopSync()
            report.running = false
        }
        do {
            try startCore(config)
            report.routeID = id
            report.routeTitle = title
            return true
        } catch {
            report.error = error.localizedDescription
            return false
        }
    }

    // MARK: - Трафик

    /// Счётчики самого интерфейса utun: что ушло в туннель (отправлено) и что пришло из него.
    private func updateCounters() {
        guard let name = utunName, let current = Self.interfaceBytes(name) else { return }
        if let last = ifaceLast {
            report.uplink += Int64(current.out &- last.out)
            report.downlink += Int64(current.inb &- last.inb)
        }
        ifaceLast = current
    }

    static func interfaceBytes(_ name: String) -> (out: UInt32, inb: UInt32)? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let item = cursor {
            let ifa = item.pointee
            cursor = ifa.ifa_next
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
                  let data = ifa.ifa_data, String(cString: ifa.ifa_name) == name else { continue }
            let stats = data.assumingMemoryBound(to: if_data.self).pointee
            return (stats.ifi_obytes, stats.ifi_ibytes)
        }
        return nil
    }

    // MARK: - Сеть

    static func tunnelSettings() -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "198.18.0.2")
        let ipv4 = NEIPv4Settings(addresses: ["198.18.0.1"], subnetMasks: ["255.255.255.252"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        ipv4.excludedRoutes = [
            NEIPv4Route(destinationAddress: "10.0.0.0", subnetMask: "255.0.0.0"),
            NEIPv4Route(destinationAddress: "172.16.0.0", subnetMask: "255.240.0.0"),
            NEIPv4Route(destinationAddress: "192.168.0.0", subnetMask: "255.255.0.0"),
            NEIPv4Route(destinationAddress: "169.254.0.0", subnetMask: "255.255.0.0"),
            NEIPv4Route(destinationAddress: "224.0.0.0", subnetMask: "240.0.0.0"),
        ]
        settings.ipv4Settings = ipv4
        let ipv6 = NEIPv6Settings(addresses: ["fd66:5c00::1"], networkPrefixLengths: [126])
        ipv6.includedRoutes = [NEIPv6Route.default()]
        settings.ipv6Settings = ipv6
        // Запросы приложений к этим адресам уходят в туннель и перехватываются DNS ядра.
        // Сам iOS резолвит адреса серверов для расширения напрямую через них же — без петли.
        let dns = NEDNSSettings(servers: ["77.88.8.8", "77.88.8.1"])
        dns.matchDomains = [""]
        settings.dnsSettings = dns
        settings.mtu = 1500
        return settings
    }

    /// Пробный режим: интерфейс с маршрутом только на служебную подсеть, трафик не перехватывается.
    static func probeSettings() -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.255.0.1")
        let ipv4 = NEIPv4Settings(addresses: ["10.255.0.2"], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = [NEIPv4Route(destinationAddress: "10.255.0.0", subnetMask: "255.255.255.0")]
        settings.ipv4Settings = ipv4
        settings.mtu = 1400
        return settings
    }

    /// Ищет дескриптор utun, который создал NetworkExtension (способ из README Xray-core).
    static func tunnelFileDescriptor(_ found: inout String?) -> Int32? {
        var buf = [CChar](repeating: 0, count: Int(IFNAMSIZ))
        for fd: Int32 in 0...1024 {
            var len = socklen_t(buf.count)
            // 2 = SYSPROTO_CONTROL, 2 = UTUN_OPT_IFNAME
            guard getsockopt(fd, 2, 2, &buf, &len) == 0 else { continue }
            let name = buf.withUnsafeBufferPointer { ptr -> String in
                guard let base = ptr.baseAddress else { return "" }
                return String(cString: base)
            }
            if name.hasPrefix("utun") {
                found = name
                return fd
            }
        }
        return nil
    }

    static var footprintMB: Double? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Double(info.phys_footprint) / 1_048_576
    }

    static func error(_ message: String) -> NSError {
        NSError(domain: "com.secretclub.tunnel", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

// MARK: - Авто: проверка сервера и переключение при смене сети

extension PacketTunnelProvider {
    /// Выполнить блок на очереди work и дождаться результата.
    private func onWork<T>(_ body: @escaping () -> T) async -> T {
        await withCheckedContinuation { (cont: CheckedContinuation<T, Never>) in
            work.async { cont.resume(returning: body()) }
        }
    }

    private static var poolURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("auto-pool.json")
    }

    /// Список кандидатов: из опций запуска (свежий от приложения) или сохранённый (автоподключение).
    private func loadPool(_ text: String?) {
        if let text, let pool = TunnelCoding.decode(AutoPool.self, Data(text.utf8)) {
            self.pool = pool
            Self.savePool(pool)
        } else if let url = Self.poolURL, let data = try? Data(contentsOf: url) {
            pool = TunnelCoding.decode(AutoPool.self, data)
        }
    }

    fileprivate static func savePool(_ pool: AutoPool) {
        guard let url = poolURL, let data = TunnelCoding.encode(pool) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// На очереди work.
    private func startMonitoring() {
        if pathMonitor == nil {
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] path in self?.pathChanged(path) }
            monitor.start(queue: work)
            pathMonitor = monitor
        }
        if watchdog == nil {
            let timer = DispatchSource.makeTimerSource(queue: work)
            timer.schedule(deadline: .now() + 15, repeating: 15, leeway: .seconds(3))
            timer.setEventHandler { [weak self] in self?.watchdogTick() }
            timer.resume()
            watchdog = timer
        }
    }

    /// На очереди work.
    private func stopMonitoring() {
        pathMonitor?.cancel()
        pathMonitor = nil
        watchdog?.cancel()
        watchdog = nil
        pendingCheck?.cancel()
        pendingCheck = nil
    }

    /// Сменился Wi‑Fi/мобильный интернет: старые соединения всё равно оборвались — проверяем сервер
    /// и, если нужно, подбираем другой под новую сеть. Вызывается на очереди work.
    private func pathChanged(_ path: Network.NWPath) {
        let signature = NetworkCheck.signature(path)
        guard signature != "other" else { return }
        let previous = pathSignature
        pathSignature = signature
        guard let previous, previous != signature else { return }
        log.info("network changed: \(previous, privacy: .public) → \(signature, privacy: .public)")
        report.healthy = nil
        if signature == "none" {
            report.network = NetKind.offline.rawValue
            return
        }
        report.network = nil
        scheduleCheck(.network, delay: 2.5)
    }

    /// Раз в 15 с: если трафик уходит в туннель, а в ответ почти ничего — сервер, похоже, умер.
    private func watchdogTick() {
        updateCounters()
        let up = report.uplink - lastTraffic.up
        let down = report.downlink - lastTraffic.down
        lastTraffic = (report.uplink, report.downlink)
        guard report.running, !evaluating, pendingCheck == nil else { return }
        let stalled = up > 6000 && down < up / 2
        let due = lastCheck.map { Date().timeIntervalSince($0) > 30 } ?? true
        if stalled && due { scheduleCheck(.stall, delay: 0) }
    }

    /// На очереди work. Смена сети важнее остальных причин.
    fileprivate func scheduleCheck(_ reason: CheckReason, delay: Double) {
        if pendingReason == .network && reason != .network {
            return
        }
        pendingCheck?.cancel()
        pendingReason = reason
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingCheck = nil
            self.pendingReason = nil
            Task { await self.evaluate(reason) }
        }
        pendingCheck = item
        work.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Выход в интернет через текущий сервер (CONNECT через локальный вход ядра). мс или nil.
    private static func health(port: Int, tries: Int, timeout: Double = 5) async -> Int? {
        guard port > 0 else { return nil }
        for attempt in 0..<tries {
            if let ms = await LatencyProbe.viaProxy(port: port, timeout: timeout) { return ms }
            if attempt < tries - 1 { try? await Task.sleep(nanoseconds: 800_000_000) }
        }
        return nil
    }

    private func evaluate(_ requested: CheckReason) async {
        let start: (Bool, Int, CheckReason) = await onWork {
            guard self.report.running else { return (false, 0, requested) }
            if self.evaluating {
                // Сеть сменилась посреди проверки — повторим, когда закончим.
                if requested == .network { self.scheduleCheck(.network, delay: 3) }
                return (false, 0, requested)
            }
            self.evaluating = true
            self.report.checking = true
            // Приложение тоже заметило смену сети, но расширение её уже отработало.
            var reason = requested
            if reason == .network, let last = self.lastNetworkCheck, Date().timeIntervalSince(last) < 15 { reason = .app }
            if reason == .network { self.lastNetworkCheck = Date() }
            return (true, self.healthPort, reason)
        }
        guard start.0 else { return }
        let port = start.1
        let reason = start.2

        async let healthMS = Self.health(port: port, tries: 2)
        async let kind = NetworkCheck.kind()
        let ms = await healthMS
        let network = await kind

        let state: (AutoPool?, String?, String?, String?, Date?) = await onWork {
            self.report.network = network.rawValue
            self.report.healthy = ms != nil
            if let ms { self.report.pingMS = ms }
            self.lastCheck = Date()
            return (self.pool, self.report.routeID, self.report.routeTitle, self.currentConfig, self.failedAt)
        }
        log.info("check \(reason.rawValue, privacy: .public): network \(network.rawValue, privacy: .public), health \(ms ?? -1)")

        if let pool = state.0, pool.auto, network != .offline {
            let order = AutoPool.order(for: network)
            let rank = pool.group(of: state.1).flatMap { order.firstIndex(of: $0) } ?? order.count
            var groups: [String] = []
            // Если только что перебрали всё без толку — не дёргаем туннель снова, пока не сменится сеть.
            let cooling = state.4.map { Date().timeIntervalSince($0) < 120 } ?? false
            if ms == nil {
                if reason == .network || !cooling { groups = order }
            } else if reason == .network, rank > 0 {
                // Работает, но после смены сети можно вернуться на более быстрый вариант.
                groups = Array(order.prefix(rank))
            }
            if !groups.isEmpty {
                await failover(pool, groups: groups, healthy: ms != nil,
                               original: (state.1, state.2, state.3), port: port)
            }
        }
        await onWork {
            self.evaluating = false
            self.report.checking = false
        }
    }

    /// Пробует кандидатов по группам: сперва отвечающие быстрее (по TCP/QUIC до сервера),
    /// для каждого — настоящая проверка через ядро. Ничего не подошло — возвращаем прежний сервер.
    private func failover(_ pool: AutoPool, groups: [String], healthy: Bool,
                          original: (id: String?, title: String?, config: String?), port: Int) async {
        await onWork { self.reasserting = true }
        var found: (AutoCandidate, Int)?
        search: for group in groups {
            let list = pool.candidates.filter { $0.group == group && $0.id != original.id }
            guard !list.isEmpty else { continue }
            for candidate in await Self.rank(list).prefix(4) {
                let started = await onWork { self.swapCore(candidate.config, id: candidate.id, title: candidate.title) }
                guard started else { continue }
                try? await Task.sleep(nanoseconds: 300_000_000)
                if let ms = await Self.health(port: port, tries: 1, timeout: 4) {
                    found = (candidate, ms)
                    break search
                }
            }
        }
        let result = found
        await onWork {
            if let result {
                let candidate = result.0
                self.report.healthy = true
                self.report.pingMS = result.1
                let kind = Self.groupTitle(candidate.group)
                let text = healthy
                    ? "Сеть сменилась — переключились на «\(candidate.title)»\(kind)."
                    : "Сервер «\(original.title ?? "—")» не отвечал — переключились на «\(candidate.title)»\(kind)."
                self.post(text)
                self.failedAt = nil
                self.log.info("switched to \(candidate.id, privacy: .public)")
            } else {
                if let config = original.config, self.currentConfig != config || !self.report.running {
                    _ = self.swapCore(config, id: original.id, title: original.title)
                }
                if !healthy {
                    self.failedAt = Date()
                    self.post("Серверы не отвечают в этой сети. Попробуем снова, когда сеть изменится.")
                }
            }
            self.reasserting = false
        }
    }

    private static func groupTitle(_ group: String) -> String {
        switch group {
        case "bridge": return " (мост через РФ)"
        case "reserve": return " (резервное подключение)"
        default: return ""
        }
    }

    /// На очереди work.
    private func post(_ text: String) {
        report.note = text
        report.noteID += 1
    }

    /// Кандидаты по задержке до сервера. Не открывшие TCP — отбрасываем; QUIC-серверы
    /// без ответа на рукопожатие оставляем в конце (Hysteria2 отвечает не всегда).
    private static func rank(_ list: [AutoCandidate]) async -> [AutoCandidate] {
        let pings = await LatencyProbe.direct(list.compactMap(\.target), timeout: 2)
        let answered = list.filter { pings[$0.id] != nil }.sorted { pings[$0.id]! < pings[$1.id]! }
        let unknown = list.filter { pings[$0.id] == nil && ($0.target?.udp ?? true) }
        return answered + unknown
    }
}
