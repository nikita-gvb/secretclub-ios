import Foundation
import Network
import NetworkExtension
import os

/// Туннель SecretClub: поднимает utun и запускает ядро Xray с TUN-входом прямо на его дескрипторе.
/// Собственный трафик расширения (подключения к серверам, проверки) идёт мимо туннеля — так устроен iOS.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    let log = Logger(subsystem: "com.secretclub.app.tunnel", category: "provider")
    /// Все обращения к ядру и к состоянию ниже — только на этой очереди.
    let work = DispatchQueue(label: "com.secretclub.tunnel.work", qos: .userInitiated)
    var report = TunnelReport()

    /// Рабочий сервер: его конфиг сейчас в ядре.
    struct Active {
        var id: String?
        var title: String?
        var config: String
    }

    /// Локальный HTTP-вход ядра для проверки рабочего сервера.
    var healthPort = 0
    var active: Active?
    /// Проверочные входы запасных серверов в запущенном ядре: id → порт.
    var extraPorts: [String: Int] = [:]
    /// Ядро не приняло общий конфиг — до нового пула запускаем серверы по одному.
    var multiBroken = false
    var launchedAt: Date?
    var utunName: String?
    var ifaceLast: (out: UInt32, inb: UInt32)?
    /// Запасные серверы «Авто».
    var pool: AutoPool?

    // Наблюдение за сетью
    var pathMonitor: NWPathMonitor?
    var pathSignature: String?
    var pathFingerprint: String?
    var memoryKey: String?
    var networkFirstEvent: Date?
    var lastNetworkChange: Date?

    // Проверки
    var watchdog: DispatchSourceTimer?
    var watchInterval: Double = 10
    var idleTicks = 0
    var stallStrikes = 0
    var stallSpacing: Double = 20
    var lastTraffic: (up: Int64, down: Int64) = (0, 0)
    var pendingCheck: DispatchWorkItem?
    var pendingReason: CheckReason?
    var evaluating = false
    var lastCheck: Date?
    var retryStep = 0
    var failureNoted = false
    var asleepSince: Date?
    var startCompletion: ((Error?) -> Void)?
    /// Туннель останавливается: больше ничего не запускаем.
    var stopped = false

    // Память и статистика
    var memory = NetMemory.load()
    var stats: [String: CandidateStat] = [:]
    /// Серверы, у которых в этой сети «замирает» соединение после ~16 КБ.
    var throttled: Set<String> = []
    var events: [String] = []

    enum CheckReason: String {
        /// start — запуск туннеля, network — сменилась сеть, stall — трафик уходит, а ответов нет,
        /// app — попросило приложение, retry — повтор после неудачи, wake — устройство проснулось,
        /// reload — приложение сменило сервер.
        case start, network, stall, app, retry, wake, reload
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
                self.loadPool(options?[TunnelOption.pool] as? String)
                // Автоподключение без приложения: берём последний сервер, который сработал.
                var target = Active(id: routeID, title: routeTitle, config: config)
                if options?[TunnelOption.config] == nil, let last = self.memory.lastActive,
                   let candidate = self.pool?.candidates.first(where: { $0.id == last }), self.pool?.auto == true {
                    target = Active(id: candidate.id, title: candidate.title, config: candidate.config)
                }
                do {
                    try self.launch(target)
                } catch {
                    self.log.error("start failed: \(error.localizedDescription, privacy: .public)")
                    self.report.error = error.localizedDescription
                    completionHandler(Self.error("Ядро Xray не запустилось: \(error.localizedDescription)"))
                    return
                }
                self.report.uplink = 0
                self.report.downlink = 0
                self.ifaceLast = self.utunName.flatMap(Self.interfaceBytes)
                self.startMonitoring()
                // «Подключено» — только после проверки сервера (и выбора лучшего в «Авто»).
                // Если проверка затянулась — всё равно отпускаем систему, проверка доведёт дело сама.
                self.startCompletion = completionHandler
                self.work.asyncAfter(deadline: .now() + 9) { self.finishStart() }
                self.scheduleCheck(.start, delay: 0)
            }
        }
    }

    /// На очереди work.
    func finishStart() {
        guard let completion = startCompletion else { return }
        startCompletion = nil
        completion(nil)
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        work.async {
            self.stopped = true
            self.startCompletion = nil
            self.stopMonitoring()
            if self.report.running {
                XrayEngine.stopSync()
                self.report.running = false
            }
            self.memory.save()
            completionHandler()
        }
    }

    override func sleep(completionHandler: @escaping () -> Void) {
        work.async {
            self.asleepSince = Date()
            self.stopWatchdog()
            if self.pendingReason != .network {
                self.pendingCheck?.cancel()
                self.pendingCheck = nil
                self.pendingReason = nil
            }
            completionHandler()
        }
    }

    override func wake() {
        work.async {
            let slept = self.asleepSince.map { Date().timeIntervalSince($0) } ?? 0
            self.asleepSince = nil
            guard self.report.running else { return }
            self.startWatchdog()
            // Долго спали — соединения с сервером могли протухнуть (NAT); после неудачи — пробуем снова.
            if slept > 90 || self.retryStep > 0 { self.scheduleCheck(.wake, delay: 1) }
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
                    self.multiBroken = false
                    Self.savePool(pool)
                }
                completionHandler?(TunnelCoding.encode(self.report))
            }
        case .check:
            work.async {
                // Смену сети расширение видит само, раньше приложения, — от приложения это просто «проверь».
                let fresh = self.lastCheck.map { Date().timeIntervalSince($0) < 60 } ?? false
                if !(fresh && self.report.healthy == true) && !self.evaluating && self.pendingCheck == nil {
                    self.scheduleCheck(.app, delay: 0)
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
                do {
                    try self.launch(Active(id: command.routeID, title: command.routeTitle, config: config))
                    self.report.healthy = nil
                    self.report.pingMS = nil
                    self.event("приложение сменило сервер → «\(command.routeTitle ?? "?")»")
                } catch {
                    self.report.error = error.localizedDescription
                }
                self.reasserting = false
                if self.report.running { self.scheduleCheck(.reload, delay: 1.5) }
                completionHandler?(TunnelCoding.encode(self.report))
            }
        }
    }

    // MARK: - Ядро

    /// Запускает ядро с этим сервером в роли рабочего и проверочными входами для запасных.
    /// Если ядро не приняло общий конфиг — запускает один сервер, как раньше. На очереди work.
    func launch(_ target: Active) throws {
        if stopped { throw Self.error("туннель остановлен") }
        if report.running {
            XrayEngine.stopSync()
            report.running = false
        }
        if report.coreVersion.isEmpty { report.coreVersion = XrayEngine.version }
        guard let fd = Self.tunnelFileDescriptor(&utunName) else {
            throw Self.error("не найден дескриптор utun")
        }
        if healthPort == 0 { healthPort = XrayEngine.freePort() ?? 49228 }
        let extras = multiBroken ? [] : extrasFor(target.id)
        var ports: [Int] = []
        if !extras.isEmpty {
            ports = XrayEngine.freePorts(extras.count + 1).filter { $0 != healthPort }
        }
        let assets = Bundle.main.resourcePath
        do {
            let built = try CoreConfig.compose(active: target.config, fd: fd, assetDir: assets, healthPort: healthPort,
                                               extras: extras, ports: ports)
            try XrayEngine.runSync(built.text)
            extraPorts = built.ports
        } catch let error where !extras.isEmpty {
            // Какой-то запасной сервер ядру не понравился — работаем по-старому, по одному серверу.
            event("ядро не приняло общий конфиг (\(error.localizedDescription)) — проверяем по одному")
            multiBroken = true
            XrayEngine.stopSync()
            let built = try CoreConfig.compose(active: target.config, fd: fd, assetDir: assets, healthPort: healthPort,
                                               extras: [], ports: [])
            try XrayEngine.runSync(built.text)
            extraPorts = [:]
        }
        active = target
        launchedAt = Date()
        report.routeID = target.id
        report.routeTitle = target.title
        report.running = true
        report.startedAt = Date()
        report.error = nil
        report.multi = !extraPorts.isEmpty
        log.info("xray started, fd \(fd), health \(self.healthPort), extras \(self.extraPorts.count)")
    }

    /// Какие запасные серверы держать в ядре: по нескольку лучших из каждой группы.
    func extrasFor(_ activeID: String?) -> [(id: String, config: String)] {
        guard let pool, pool.auto else { return [] }
        let limits = ["regular": 5, "bridge": 4, "reserve": 3]
        var counts: [String: Int] = [:]
        var out: [(id: String, config: String)] = []
        for candidate in pool.candidates where candidate.id != activeID {
            let n = counts[candidate.group, default: 0]
            guard n < limits[candidate.group, default: 2] else { continue }
            counts[candidate.group] = n + 1
            out.append((candidate.id, candidate.config))
        }
        return out
    }

    // MARK: - Трафик

    /// Счётчики самого интерфейса utun: что ушло в туннель (отправлено) и что пришло из него.
    func updateCounters() {
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

    // MARK: - Журнал

    /// Короткая запись в журнал решений (видна в отчёте для поддержки). На очереди work.
    func event(_ text: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        events.append("\(formatter.string(from: Date())) \(text)")
        if events.count > 24 { events.removeFirst(events.count - 24) }
        report.events = events
        log.info("\(text, privacy: .public)")
    }

    /// На очереди work.
    func post(_ text: String) {
        report.note = text
        report.noteID += 1
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
