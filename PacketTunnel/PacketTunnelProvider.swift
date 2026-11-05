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
    /// Копия отчёта для мгновенного ответа приложению, пока очередь work занята (перезапуск ядра, проверка).
    let snapshot = ReportBox()
    var report = TunnelReport() { didSet { snapshot.set(report) } }

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
    /// Ядро не приняло «горячий» конфиг (балансировщик) — переключаем перезапуском.
    var hotBroken = false
    /// «Горячий» режим: id сервера → тег его outbound в запущенном ядре.
    var routeTags: [String: String] = [:]
    /// Когда включили VPN (для виджета «подключено N минут»).
    var sessionStart: Date?
    var lastStatus: SharedStatus?
    var peakMB: Double = 0
    var loggedPeakMB: Double = 0
    var sessionTouched: Date?
    var launchedAt: Date?
    var utunName: String?
    var ifaceLast: (out: UInt32, inb: UInt32)?
    /// Счётчики ядра для рабочего конфига; nil — считаем по utun (запасной путь).
    var counterNames: (up: String, down: String, server: String)?
    /// Ядро сбрасывает счётчики при перезапуске — копим итог прошлых запусков.
    var trafficBase: (up: Int64, down: Int64, server: Int64) = (0, 0, 0)
    /// Получено от рабочего сервера за сеанс (для сторожа).
    var serverDown: Int64 = 0
    /// Последнее обновление счётчиков шло из ядра.
    var coreCounters = false
    /// Запасные серверы «Авто».
    var pool: AutoPool?

    // Наблюдение за сетью
    var pathMonitor: NWPathMonitor?
    var pathSignature: String?
    var pathFingerprint: String?
    var memoryKey: String?
    var networkFirstEvent: Date?
    var lastNetworkChange: Date?
    /// Сеть (интерфейс и адрес), в которой ядро открыло свои соединения к серверу. Вернулись в ту же
    /// сеть после «моргания» — соединения живы, ядро не перезапускаем.
    var coreFingerprint: String?

    // Память (лимит iOS для расширения — 50 МБ)
    /// Экономный режим: меньше запасных серверов в ядре (была нехватка памяти).
    var lean = false
    /// Ядро уже перезапускали ради памяти в этом сеансе.
    var shrunk = false
    var lastFree: Date?
    var memorySource: DispatchSourceMemoryPressure?

    // Проверки
    var watchdog: DispatchSourceTimer?
    var watchInterval: Double = 10
    var idleTicks = 0
    var stallStrikes = 0
    var stallSpacing: Double = 20
    var lastTraffic: (up: Int64, down: Int64, server: Int64) = (0, 0, 0)
    /// Когда сервер последний раз прошёл проверку объёмом (id → время).
    var payloadOK: [String: Date] = [:]
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
            // Пробный туннель гасим сами: приложение могли закрыть посреди проверки.
            work.asyncAfter(deadline: .now() + 45) { [weak self] in
                guard let self, self.report.probe, !self.stopped else { return }
                DiagLog.write("пробный туннель: приложение не выключило его за 45 с — выключаем сами", to: .tunnel)
                self.cancelTunnelWithError(nil)
            }
            return
        }

        let stored = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration
        let config = (options?[TunnelOption.config] as? String) ?? (stored?[TunnelOption.config] as? String)
        let routeID = (options?[TunnelOption.routeID] as? String) ?? (stored?[TunnelOption.routeID] as? String)
        let routeTitle = (options?[TunnelOption.routeTitle] as? String) ?? (stored?[TunnelOption.routeTitle] as? String)
        guard let config, !config.isEmpty else {
            DiagLog.warn("запуск без настроек подключения", to: .tunnel)
            completionHandler(Self.error("Нет настроек подключения. Откройте SecretClub и нажмите «Подключить»."))
            return
        }
        let byApp = options?[TunnelOption.config] != nil
        work.async {
            self.noteUncleanExit()
            self.sessionStart = Date()
            self.peakMB = Self.footprintMB ?? 0
            self.touchSession(force: true, route: routeTitle)
            DiagLog.write("включение VPN (\(byApp ? "из приложения" : "без приложения: виджет, команда или автоподключение")), "
                          + "«\(routeTitle ?? "?")», ядро \(XrayEngine.version), iOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
                          to: .tunnel)
        }

        setTunnelNetworkSettings(Self.tunnelSettings()) { error in
            if let error {
                DiagLog.warn("не удалось настроить туннель: \(error.localizedDescription)", to: .tunnel)
                self.work.async { TunnelSession.end() }
                completionHandler(Self.error("Не удалось настроить туннель: \(error.localizedDescription)"))
                return
            }
            self.work.async {
                self.loadPool(options?[TunnelOption.pool] as? String, stored: stored?[TunnelOption.pool] as? String)
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
                    DiagLog.warn("ядро не запустилось: \(error.localizedDescription)", to: .tunnel)
                    TunnelSession.end()
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
        WidgetRefresh.request(after: 1)
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        work.async {
            self.stopped = true
            self.startCompletion = nil
            self.stopMonitoring()
            if self.report.running {
                self.updateCounters()
                XrayEngine.stopSync()
                self.report.running = false
            }
            self.memory.save()
            let minutes = self.sessionStart.map { Int(Date().timeIntervalSince($0) / 60) } ?? 0
            let text = "выключение VPN: \(Self.describe(reason)); \(minutes) мин, ↑\(Self.mb(self.report.uplink)) ↓\(Self.mb(self.report.downlink)), память до \(Int(self.peakMB.rounded())) МБ"
            if Self.unexpected(reason) { DiagLog.warn(text, to: .tunnel) } else { DiagLog.write(text, to: .tunnel) }
            TunnelSession.end()
            self.publishStatus()
            WidgetRefresh.now()
            DiagLog.flush()
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
            respond(completionHandler) {
                self.updateCounters()
                self.trackMemory()
            }
        case .pool:
            respond(completionHandler) {
                if let pool = command.pool {
                    if pool.candidates.map(\.id) != self.pool?.candidates.map(\.id) || pool.auto != self.pool?.auto {
                        DiagLog.write("список серверов: \(pool.candidates.count), \(pool.auto ? "авто" : "выбран вручную")", to: .tunnel)
                    }
                    self.pool = pool
                    self.multiBroken = false
                    self.hotBroken = false
                    Self.savePool(pool)
                    self.publishStatus()
                }
            }
        case .check:
            respond(completionHandler) {
                // Смену сети расширение видит само, раньше приложения, — от приложения это просто «проверь».
                let fresh = self.lastCheck.map { Date().timeIntervalSince($0) < 60 } ?? false
                if !(fresh && self.report.healthy == true) && !self.evaluating && self.pendingCheck == nil {
                    self.scheduleCheck(.app, delay: 0)
                }
            }
        case .ping:
            // Свои соединения расширения идут мимо туннеля — замер честный.
            let targets = command.targets ?? []
            Task {
                let results = await LatencyProbe.direct(targets, timeout: 3)
                var reply = self.snapshot.get()
                reply.pings = results
                completionHandler?(TunnelCoding.encode(reply))
            }
        case .log:
            // Журнал читаем мимо очереди work — ответ сразу, даже во время перезапуска ядра.
            DispatchQueue.global(qos: .userInitiated).async {
                var reply = self.snapshot.get()
                reply.memoryMB = Self.footprintMB
                reply.logTail = DiagLog.read(.tunnel, maxBytes: 96 * 1024)
                reply.incidents = Incidents.all()
                completionHandler?(TunnelCoding.encode(reply))
            }
        case .reload:
            guard let config = command.config else {
                work.async { completionHandler?(TunnelCoding.encode(self.report)) }
                return
            }
            work.async {
                // Сервер выбрали вручную — перезапуск: все соединения сразу переходят на новый
                // (при «горячем» переключении открытые страницы ещё какое-то время шли бы через прежний).
                self.reasserting = true
                do {
                    try self.launch(Active(id: command.routeID, title: command.routeTitle, config: config))
                    self.report.healthy = nil
                    self.report.pingMS = nil
                    self.event("приложение сменило сервер → «\(command.routeTitle ?? "?")»")
                } catch {
                    self.report.error = error.localizedDescription
                    DiagLog.warn("не удалось сменить сервер на «\(command.routeTitle ?? "?")»: \(error.localizedDescription)", to: .tunnel)
                }
                self.reasserting = false
                if self.report.running { self.scheduleCheck(.reload, delay: 1.5) }
                completionHandler?(TunnelCoding.encode(self.report))
            }
        }
    }

    // MARK: - Ядро

    /// Запускает ядро с этим сервером в роли рабочего и проверочными входами для запасных.
    /// Попытки по убыванию возможностей: «горячий» общий конфиг → общий → один сервер. На очереди work.
    func launch(_ target: Active) throws {
        if stopped { throw Self.error("туннель остановлен") }
        if report.running {
            updateCounters()
            XrayEngine.stopSync()
            report.running = false
            if lean { XrayEngine.freeMemory() }
        }
        // Новое ядро начнёт счёт с нуля — продолжаем от уже накопленного.
        trafficBase = (report.uplink, report.downlink, serverDown)
        if report.coreVersion.isEmpty { report.coreVersion = XrayEngine.version }
        guard let fd = Self.tunnelFileDescriptor(&utunName) else {
            throw Self.error("не найден дескриптор utun")
        }
        if healthPort == 0 { healthPort = XrayEngine.freePort() ?? 49228 }
        let extras = multiBroken ? [] : extrasFor(target.id)
        var ports: [Int] = []
        if !extras.isEmpty {
            ports = XrayEngine.freePorts(extras.count + 2).filter { $0 != healthPort }
        }
        var attempts: [(extras: [(id: String, config: String)], hot: Bool)] = []
        if !extras.isEmpty {
            if !hotBroken { attempts.append((extras, true)) }
            attempts.append((extras, false))
        }
        attempts.append(([], false))
        let assets = Bundle.main.resourcePath
        var built: CoreConfig.Built?
        var lastError: Error?
        for attempt in attempts {
            do {
                let candidate = try CoreConfig.compose(active: target.config, fd: fd, assetDir: assets, healthPort: healthPort,
                                                       extras: attempt.extras, ports: ports, activeID: target.id, hot: attempt.hot)
                try XrayEngine.runSync(candidate.text)
                // Балансировщик сразу направляем на рабочий сервер, иначе он выберет outbound сам.
                if candidate.balanced {
                    guard let main = candidate.main, XrayEngine.setBalancerTarget(CoreConfig.routeBalancer, main) else {
                        throw Self.error("ядро не переключает балансировщик")
                    }
                }
                built = candidate
                break
            } catch {
                lastError = error
                XrayEngine.stopSync()
                if attempt.hot {
                    hotBroken = true
                    event("ядро не приняло конфиг для переключения без перезапуска (\(error.localizedDescription)) — переключаем перезапуском")
                } else if !attempt.extras.isEmpty {
                    // Какой-то запасной сервер ядру не понравился — работаем по-старому, по одному серверу.
                    multiBroken = true
                    event("ядро не приняло общий конфиг (\(error.localizedDescription)) — проверяем по одному")
                }
            }
        }
        guard let built else { throw lastError ?? Self.error("ядро не запустилось") }
        extraPorts = built.ports
        routeTags = built.hot ? built.tags : [:]
        active = target
        counterNames = CoreConfig.counterNames(target.config)
        launchedAt = Date()
        if let fp = pathFingerprint, fp != "none" { coreFingerprint = fp }
        report.routeID = target.id
        report.routeTitle = target.title
        report.running = true
        report.startedAt = Date()
        report.error = nil
        report.multi = !extraPorts.isEmpty
        report.hot = !routeTags.isEmpty
        log.info("xray started, fd \(fd), health \(self.healthPort), extras \(self.extraPorts.count), hot \(!self.routeTags.isEmpty)")
        DiagLog.write("ядро запущено: «\(target.title ?? "?")», запасных в ядре \(extras.isEmpty ? 0 : max(0, built.ports.count - (routeTags.isEmpty ? 0 : 1)))"
                      + (routeTags.isEmpty ? "" : ", переключение без перезапуска"), to: .tunnel)
        publishStatus()
        TunnelSignal.post()
    }

    /// Смена рабочего сервера без перезапуска ядра: балансировщик переводится на outbound, уже загруженный
    /// в ядро. Открытые соединения доживают через прежний сервер, новые идут через новый. На очереди work.
    @discardableResult
    func hotSwitch(_ target: Active) -> Bool {
        guard report.running, !stopped, let id = target.id, id != active?.id, let tag = routeTags[id],
              let current = active?.id, routeTags[current] != nil else { return false }
        updateCounters()
        guard XrayEngine.setBalancerTarget(CoreConfig.routeBalancer, tag) else {
            event("переключение без перезапуска не удалось — дальше перезапуском")
            routeTags = [:]
            report.hot = false
            return false
        }
        // Счётчик «получено от сервера» теперь у другого outbound — продолжаем итог без скачка.
        let name = "outbound>>>\(tag)>>>traffic>>>downlink"
        trafficBase.server = serverDown - (XrayEngine.counter(name) ?? 0)
        if let names = counterNames { counterNames = (names.up, names.down, name) }
        active = target
        launchedAt = Date()
        report.routeID = target.id
        report.routeTitle = target.title
        report.error = nil
        publishStatus()
        TunnelSignal.post()
        return true
    }

    /// Какие запасные серверы держать в ядре: по нескольку лучших из каждой группы.
    func extrasFor(_ activeID: String?) -> [(id: String, config: String)] {
        guard let pool, pool.auto else { return [] }
        // Экономный режим (была нехватка памяти) — по 1–2 запасных из группы.
        let limits = lean ? ["regular": 2, "bridge": 2, "reserve": 1] : ["regular": 5, "bridge": 4, "reserve": 3]
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

    /// Трафик за сеанс. Основной путь — счётчики ядра (вход TUN); запасной — счётчики интерфейса utun
    /// (на iOS они обычно не обновляются, поэтому статистика раньше стояла на нуле).
    func updateCounters() {
        // Счётчики в ядре появляются с первым соединением; пока одного нет — считаем его нулём.
        let names = report.running ? counterNames : nil
        let up = names.flatMap { XrayEngine.counter($0.up) }
        let down = names.flatMap { XrayEngine.counter($0.down) }
        if let names, up != nil || down != nil {
            report.uplink = trafficBase.up + (up ?? 0)
            report.downlink = trafficBase.down + (down ?? 0)
            serverDown = trafficBase.server + (XrayEngine.counter(names.server) ?? 0)
            coreCounters = true
            report.counters = "core"
            return
        }
        // Ядро только что перезапущено и счётчики ещё не созданы — итог прежний, utun не подмешиваем.
        if names != nil && coreCounters { return }
        coreCounters = false
        report.counters = "utun"
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
        DiagLog.write(text, to: .tunnel)
    }

    /// На очереди work.
    func post(_ text: String) {
        report.note = text
        report.noteID += 1
        TunnelSignal.post()
    }

    // MARK: - Ответы приложению

    /// Выполнить на очереди work и ответить отчётом. Если очередь занята дольше 0,25 с (перезапуск ядра,
    /// проверка), приложение сразу получает последнюю копию отчёта, а работа доделывается в фоне.
    func respond(_ completion: ((Data?) -> Void)?, _ body: @escaping () -> Void) {
        let once = ReplyOnce(completion)
        let snapshot = self.snapshot
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.25) {
            guard once.pending else { return }
            var reply = snapshot.get()
            reply.memoryMB = Self.footprintMB
            once.send(TunnelCoding.encode(reply))
        }
        work.async {
            body()
            once.send(TunnelCoding.encode(self.report))
        }
    }

    // MARK: - Общее состояние и диагностика

    /// Состояние для виджетов (общая папка). Пишем, только когда оно изменилось. На очереди work.
    func publishStatus() {
        var status = SharedStatus()
        status.running = report.running && !stopped
        status.routeID = active?.id
        status.routeTitle = active?.title
        status.pingMS = report.pingMS
        status.healthy = report.healthy
        status.network = report.network
        status.auto = pool?.auto
        status.since = status.running ? sessionStart : nil
        guard !status.same(as: lastStatus) else { return }
        // Виджетам важно: включён ли, какой сервер, отвечает ли, есть ли сеть (пинг — не повод тратить обновление).
        let previous = lastStatus
        let visible = previous == nil || previous?.running != status.running || previous?.routeID != status.routeID
            || previous?.healthy != status.healthy || previous?.network != status.network
        status.save()
        lastStatus = status
        if visible { WidgetRefresh.request() }
    }

    /// Прошлый сеанс не закрылся через stopTunnel — расширение завершилось аварийно (память, сбой). На очереди work.
    func noteUncleanExit() {
        guard let previous = TunnelSession.load() else { return }
        TunnelSession.end()
        // Устройство перезагружалось или приложение обновили после последнего признака жизни — это не сбой.
        if let boot = Self.bootTime, previous.alive < boot { return }
        if let build = previous.build, build != Self.build { return }
        let time = DateFormatter.localizedString(from: previous.alive, dateStyle: .short, timeStyle: .short)
        var detail = "Последний признак жизни \(time), сервер «\(previous.route ?? "?")», память до \(Int(previous.peakMB.rounded())) МБ, ядро \(previous.version)."
        if previous.peakMB >= 44 { detail += " Похоже, iOS выгрузила VPN из-за лимита памяти (50 МБ)." }
        if previous.peakMB >= 38 {
            // Прошлый сеанс упал с большой памятью — этот начинаем экономно.
            lean = true
            detail += " Этот сеанс — экономный режим: меньше запасных серверов в ядре."
        }
        DiagLog.warn("прошлый сеанс VPN завершился аварийно: \(detail)", to: .tunnel)
        Incidents.add(Incident(id: "tunnel-\(Int(previous.started.timeIntervalSince1970))", date: previous.alive, source: .tunnel,
                               title: "VPN завершился аварийно", detail: detail))
    }

    /// Метка живого сеанса: при запуске, раз в 5 минут и при росте памяти. На очереди work.
    func touchSession(force: Bool = false, route: String? = nil) {
        let now = Date()
        if !force, let last = sessionTouched, now.timeIntervalSince(last) < 300 { return }
        sessionTouched = now
        TunnelSession.save(TunnelSession.State(started: sessionStart ?? now, alive: now, peakMB: peakMB,
                                               route: route ?? active?.title, version: XrayEngine.version, build: Self.build))
    }

    /// Сторож памяти: пик за сеанс, запись в журнал при заметном росте. На очереди work.
    func trackMemory() {
        guard var mb = Self.footprintMB else { return }
        // Ближе к лимиту — сразу возвращаем свободную память ядра (не ждём его 10-секундного таймера).
        if mb >= Self.freeAtMB, lastFree.map({ Date().timeIntervalSince($0) > 5 }) ?? true {
            lastFree = Date()
            XrayEngine.freeMemory()
            let after = Self.footprintMB ?? mb
            if mb >= 40 {
                DiagLog.warn("память расширения \(Int(mb.rounded())) МБ → \(Int(after.rounded())) МБ после освобождения", to: .tunnel)
            }
            if mb >= 40, !lean {
                lean = true
                event("экономный режим памяти: дальше меньше запасных серверов в ядре")
            }
            if after >= 43 { shrinkIfNeeded(after) }
            mb = max(mb, after)
        }
        report.memoryMB = mb
        guard mb > peakMB else { return }
        let grew = mb - peakMB >= 1
        peakMB = mb
        if mb - loggedPeakMB >= 3 {
            loggedPeakMB = mb
            let text = "память расширения: \(Int(mb.rounded())) МБ"
            if mb >= 40 { DiagLog.warn(text + " (лимит iOS — 50 МБ)", to: .tunnel) } else { DiagLog.write(text, to: .tunnel) }
        }
        if grew { touchSession(force: true) }
    }

    /// С какой памяти освобождать её сразу.
    static let freeAtMB: Double = 34

    /// Память у самого лимита: перезапуск ядра с меньшим числом запасных (лучше секунда без сети,
    /// чем iOS выгрузит VPN целиком). Один раз за сеанс. На очереди work.
    func shrinkIfNeeded(_ mb: Double) {
        guard !shrunk, report.running, !evaluating, startCompletion == nil, !stopped, let current = active,
              extraPorts.count > 5 else { return }
        shrunk = true
        lean = true
        event("память \(Int(mb.rounded())) МБ у лимита — перезапуск ядра с меньшим числом запасных")
        do {
            try launch(current)
        } catch {
            report.error = error.localizedDescription
            DiagLog.warn("ядро не перезапустилось после нехватки памяти: \(error.localizedDescription)", to: .tunnel)
            scheduleRetry()
        }
    }

    /// Сигнал iOS о нехватке памяти в системе. На очереди work.
    func memoryPressure(critical: Bool) {
        lastFree = Date()
        XrayEngine.freeMemory()
        let mb = Self.footprintMB ?? 0
        report.memoryMB = mb
        DiagLog.warn("iOS: \(critical ? "критическая " : "")нехватка памяти, у VPN \(Int(mb.rounded())) МБ — освобождаем", to: .tunnel)
        if !lean {
            lean = true
            event("экономный режим памяти: дальше меньше запасных серверов в ядре")
        }
        if critical || mb >= 40 { shrinkIfNeeded(mb) }
    }

    static let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"

    static var bootTime: Date? {
        var tv = timeval()
        var size = MemoryLayout<timeval>.stride
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &tv, &size, nil, 0) == 0, tv.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec))
    }

    static func mb(_ bytes: Int64) -> String {
        bytes < 1_048_576 ? "\(bytes / 1024) КБ" : String(format: "%.1f МБ", Double(bytes) / 1_048_576)
    }

    static func unexpected(_ reason: NEProviderStopReason) -> Bool {
        switch reason {
        case .userInitiated, .superceded, .userLogout, .userSwitch, .configurationRemoved, .configurationDisabled,
             .sleep, .appUpdate, NEProviderStopReason.none:
            return false
        default:
            return true
        }
    }

    static func describe(_ reason: NEProviderStopReason) -> String {
        switch reason {
        case NEProviderStopReason.none: return "без причины"
        case .userInitiated: return "выключили (приложение, Пункт управления или Настройки)"
        case .providerFailed: return "сбой расширения"
        case .noNetworkAvailable: return "нет сети"
        case .unrecoverableNetworkChange: return "смена сети, которую не пережить"
        case .providerDisabled: return "расширение отключено"
        case .authenticationCanceled: return "отмена авторизации"
        case .configurationFailed: return "ошибка конфигурации"
        case .idleTimeout: return "простой"
        case .configurationDisabled: return "профиль VPN выключен"
        case .configurationRemoved: return "профиль VPN удалён"
        case .superceded: return "включили другой VPN"
        case .userLogout: return "выход из аккаунта"
        case .userSwitch: return "смена пользователя"
        case .connectionFailed: return "не удалось подключиться"
        case .sleep: return "сон устройства"
        case .appUpdate: return "обновление приложения"
        case .internalError: return "внутренняя ошибка iOS"
        @unknown default: return "код \(reason.rawValue)"
        }
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

/// Потокобезопасная копия отчёта (читается вне очереди work).
final class ReportBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = TunnelReport()

    func set(_ report: TunnelReport) {
        lock.lock()
        value = report
        lock.unlock()
    }

    func get() -> TunnelReport {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Ответ приложению ровно один раз (быстрый из копии или полный с очереди work — что раньше).
final class ReplyOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((Data?) -> Void)?

    init(_ handler: ((Data?) -> Void)?) { self.handler = handler }

    var pending: Bool {
        lock.lock()
        defer { lock.unlock() }
        return handler != nil
    }

    func send(_ data: Data?) {
        lock.lock()
        let handler = self.handler
        self.handler = nil
        lock.unlock()
        handler?(data)
    }
}
