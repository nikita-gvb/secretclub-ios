import Foundation
import Network

/// Что расширение помнит о сетях: что в них работало и какой там интернет.
/// Ключ — NetworkCheck.memoryKey (Wi‑Fi различаем по шлюзу, мобильная сеть одна).
struct NetMemory: Codable {
    struct Entry: Codable {
        var kind: String?
        var best: String?
        /// До этого времени обычные серверы в этой сети «замирают» после ~16 КБ — сразу берём мосты.
        /// Срок ограничен: блокировку могут снять, тогда обычные серверы снова в деле.
        var freezeUntil: Date?
        var payloadAt: Date?
        var at: Date

        var frozen: Bool { freezeUntil.map { $0 > Date() } ?? false }
    }

    var entries: [String: Entry] = [:]
    /// Последний сервер, который точно работал (для автоподключения без приложения).
    var lastActive: String?

    private static var url: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("net-memory.json")
    }

    static func load() -> NetMemory {
        guard let url, let data = try? Data(contentsOf: url),
              let memory = TunnelCoding.decode(NetMemory.self, data) else { return NetMemory() }
        return memory
    }

    func save() {
        guard let url = Self.url, let data = TunnelCoding.encode(self) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// Запись, если она ещё не устарела: мобильная сеть меняется часто (белые списки включают и выключают).
    func entry(_ key: String?) -> Entry? {
        guard let key, let e = entries[key] else { return nil }
        let ttl: TimeInterval = key.hasPrefix("cellular") ? 20 * 60 : 7 * 86400
        return Date().timeIntervalSince(e.at) < ttl ? e : nil
    }

    mutating func update(_ key: String?, _ change: (inout Entry) -> Void) {
        guard let key else { return }
        var e = entries[key] ?? Entry(at: Date())
        change(&e)
        e.at = Date()
        entries[key] = e
        if entries.count > 40, let oldest = entries.min(by: { $0.value.at < $1.value.at })?.key {
            entries.removeValue(forKey: oldest)
        }
    }
}

/// Сглаженная задержка и неудачи сервера в текущей сети.
struct CandidateStat {
    var ewma: Double?
    var fails = 0

    mutating func ok(_ ms: Int) {
        ewma = ewma.map { $0 * 0.5 + Double(ms) * 0.5 } ?? Double(ms)
        fails = 0
    }

    mutating func fail() { fails = min(fails + 1, 5) }
}

/// Результат проверки режима сети, который может прийти посреди замеров.
final class KindBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: NetKind?
    var kind: NetKind? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
    func set(_ kind: NetKind) {
        lock.lock()
        value = kind
        lock.unlock()
    }
}

/// Один проверочный вход ядра: рабочий сервер или запасной.
struct CheckTarget: Sendable {
    let key: String
    let id: String
    let group: String
    let port: Int
    let active: Bool
}

/// Итог параллельной проверки.
struct Survey {
    var activeMS: Int?
    var activeChecked = false
    var ok: [String: Int] = [:]
    var failed: Set<String> = []
    var seconds: Double = 0
}

private enum SurveyEvent: Sendable {
    case result(String, Int?)
    case tick
}

// MARK: - Авто: проверка сервера и переключение

extension PacketTunnelProvider {
    struct CheckContext {
        let reason: CheckReason
        let auto: Bool
        let activeProbe: CheckTarget
        let activeGroup: String
        let extras: [CheckTarget]
        /// Сразу проверять и запасные (смена сети, запуск, повтор, подозрение на обрыв).
        let broad: Bool
        /// Можно сменить рабочий сервер на заметно более быстрый из той же группы.
        let compare: Bool
        let classify: Bool
        /// Сеть вернулась та же — ядро не перезапускали; рабочий молчит — тогда перезапуск.
        let blip: Bool
        let freeze: Bool
        let activeThrottled: Bool
        /// Ядро без общего конфига: запасные проверяем по одному.
        let single: Bool
        let preferred: String?
        /// Есть кандидаты из пула без проверочного входа (пул обновился после запуска ядра).
        let unprobed: Bool
        let started: DispatchTime
    }

    struct Decision {
        var targets: [AutoCandidate]
        /// Рабочий сервер отвечает (может быть, переключаемся просто на лучший).
        var activeAlive: Bool
    }

    /// Выполнить блок на очереди work и дождаться результата.
    func onWork<T>(_ body: @escaping () -> T) async -> T {
        await withCheckedContinuation { (cont: CheckedContinuation<T, Never>) in
            work.async { cont.resume(returning: body()) }
        }
    }

    private static var poolURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("auto-pool.json")
    }

    /// Список кандидатов: из опций запуска (свежий от приложения), иначе — более свежий из сохранённого
    /// расширением и записанного приложением в профиль VPN (запуск из виджета, автоподключение).
    func loadPool(_ text: String?, stored: String? = nil) {
        if let text, let pool = TunnelCoding.decode(AutoPool.self, Data(text.utf8)) {
            self.pool = pool
            Self.savePool(pool)
            return
        }
        let file = Self.poolURL.flatMap { try? Data(contentsOf: $0) }.flatMap { TunnelCoding.decode(AutoPool.self, $0) }
        let profile = stored.flatMap { TunnelCoding.decode(AutoPool.self, Data($0.utf8)) }
        if let file, let profile {
            pool = (profile.updatedAt ?? .distantPast) > (file.updatedAt ?? .distantPast) ? profile : file
        } else {
            pool = file ?? profile
        }
        if let pool, pool.updatedAt == profile?.updatedAt, profile != nil { Self.savePool(pool) }
    }

    static func savePool(_ pool: AutoPool) {
        guard let url = poolURL, let data = TunnelCoding.encode(pool) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    // MARK: Наблюдение

    /// На очереди work.
    func startMonitoring() {
        if pathMonitor == nil {
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] path in self?.pathChanged(path) }
            monitor.start(queue: work)
            pathMonitor = monitor
        }
        if memorySource == nil {
            let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: work)
            source.setEventHandler { [weak self] in
                guard let self, let event = self.memorySource?.data else { return }
                self.memoryPressure(critical: event.contains(.critical))
            }
            source.resume()
            memorySource = source
        }
        startWatchdog()
    }

    /// На очереди work.
    func stopMonitoring() {
        pathMonitor?.cancel()
        pathMonitor = nil
        memorySource?.cancel()
        memorySource = nil
        stopWatchdog()
        pendingCheck?.cancel()
        pendingCheck = nil
        pendingReason = nil
    }

    func startWatchdog() {
        guard watchdog == nil, asleepSince == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: work)
        timer.schedule(deadline: .now() + watchInterval, repeating: watchInterval,
                       leeway: .milliseconds(Int(watchInterval * 250)))
        timer.setEventHandler { [weak self] in self?.watchdogTick() }
        timer.resume()
        watchdog = timer
    }

    func stopWatchdog() {
        watchdog?.cancel()
        watchdog = nil
    }

    /// Сменился Wi‑Fi/мобильный интернет или адрес: соединения ядра к серверу мертвы — перезапускаем
    /// ядро и проверяем все серверы разом. Вызывается на очереди work.
    func pathChanged(_ path: Network.NWPath) {
        let signature = NetworkCheck.signature(path)
        guard signature != "other" else { return }
        let fingerprint = signature == "none" ? "none" : (NetworkCheck.fingerprint(path) ?? signature)
        let previous = pathFingerprint
        pathFingerprint = fingerprint
        pathSignature = signature
        if signature != "none" { memoryKey = NetworkCheck.memoryKey(path) }
        // Ядро запустилось раньше, чем пришло первое состояние сети, — это и есть его сеть.
        if coreFingerprint == nil, fingerprint != "none", report.running { coreFingerprint = fingerprint }
        guard let previous, previous != fingerprint else { return }
        // Тот же интерфейс просто получил адрес сразу после смены — это та же смена сети.
        let recent = lastNetworkChange.map { Date().timeIntervalSince($0) < 5 } ?? false
        if recent, previous != "none", fingerprint.hasPrefix(previous) { return }
        event("сеть: \(Self.kindOf(previous)) → \(Self.kindOf(fingerprint))")
        lastNetworkChange = Date()
        report.healthy = nil
        retryStep = 0
        failureNoted = false
        throttled = []
        stats = [:]
        dnsOK = nil
        dnsRestarted = []
        dnsBroken = []
        report.dnsOK = nil
        report.dnsMS = nil
        if signature == "none" {
            report.network = NetKind.offline.rawValue
            if pendingReason != .start {
                pendingCheck?.cancel()
                pendingCheck = nil
                pendingReason = nil
            }
            return
        }
        report.network = nil
        // Интерфейс может «моргнуть» несколько раз: ждём ~1 с тишины, но не дольше 2,5 с с первого события.
        let first = networkFirstEvent ?? Date()
        networkFirstEvent = first
        let delay = max(0.3, min(1.0, 2.5 - Date().timeIntervalSince(first)))
        scheduleCheck(.network, delay: delay)
    }

    static func kindOf(_ fingerprint: String) -> String {
        String(fingerprint.split(separator: "|").first ?? "?")
    }

    /// Таймер: если трафик уходит в туннель, а в ответ почти ничего — сервер, похоже, умер.
    /// Пока трафика нет, тикает реже (10 → 30 с) — меньше пробуждений; во сне не тикает вовсе.
    func watchdogTick() {
        updateCounters()
        trackMemory()
        touchSession()
        let up = report.uplink - lastTraffic.up
        let down = report.downlink - lastTraffic.down
        let fromServer = serverDown - lastTraffic.server
        lastTraffic = (report.uplink, report.downlink, serverDown)
        let busy = up + down > 4096
        idleTicks = busy ? 0 : idleTicks + 1
        let next: Double = (busy || idleTicks < 3) ? 10 : 30
        if next != watchInterval {
            watchInterval = next
            watchdog?.schedule(deadline: .now() + next, repeating: next, leeway: .milliseconds(Int(next * 250)))
        }
        guard report.running, !evaluating, pendingCheck == nil, startCompletion == nil else { return }
        let stalled: Bool
        if coreCounters {
            // Ядро считает полезные данные. Пока соединение с сервером не установлено, запросы приложений
            // ещё не прочитаны — видны в основном DNS-запросы. Пользователь активен, а в ответ почти ничего
            // (и от сервера, и вообще) — похоже, сервер умер. Проверка лёгкая, ложная тревога стоит ~2 КБ.
            stalled = up + down > 600 && fromServer < 1024 && down < 8192
        } else {
            // Счётчики utun: ответы ядро генерирует и само (TCP внутри туннеля), поэтому «ничего» — меньше трети.
            stalled = up > 4000 && down < up / 3 && down < 65536
        }
        guard stalled else {
            stallStrikes = 0
            // Интервал между проверками сбрасываем, только когда сервер точно снова отдаёт данные.
            if (coreCounters ? fromServer > 16384 : busy) { stallSpacing = 20 }
            return
        }
        stallStrikes += 1
        let due = lastCheck.map { Date().timeIntervalSince($0) > stallSpacing } ?? true
        if due { scheduleCheck(.stall, delay: 0) }
    }

    /// На очереди work. Смена сети и запуск важнее остальных причин.
    func scheduleCheck(_ reason: CheckReason, delay: Double) {
        if let pending = pendingReason, pending == .network || pending == .start, reason != .network { return }
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

    /// Повтор после неудачи: 10, 20, 40 с … до 10 минут, пока есть сеть.
    func scheduleRetry() {
        guard !stopped, active != nil, pathSignature != "none" else { return }
        let delays: [Double] = [10, 20, 40, 80, 160, 300, 600]
        let delay = delays[min(retryStep, delays.count - 1)]
        retryStep += 1
        scheduleCheck(.retry, delay: delay)
    }

    // MARK: Проверка

    /// На очереди work: что и как проверять.
    func beginCheck(_ requested: CheckReason) -> CheckContext? {
        guard !stopped, let current = active else {
            finishStart()
            return nil
        }
        if evaluating {
            // Сеть сменилась посреди проверки — повторим, когда закончим.
            if requested == .network { scheduleCheck(.network, delay: 1.5) }
            return nil
        }
        if !report.running {
            // Ядро упало (например, не перезапустилось) — поднимаем снова, иначе ждём и пробуем ещё.
            do {
                try launch(current)
            } catch {
                report.error = error.localizedDescription
                scheduleRetry()
                finishStart()
                return nil
            }
        }
        evaluating = true
        report.checking = true
        let reason = requested
        var blip = false
        if reason == .network {
            networkFirstEvent = nil
            if let core = coreFingerprint, core == pathFingerprint {
                // Сеть «моргнула» и вернулась та же (тот же интерфейс и адрес): соединения ядра живы —
                // не рвём их перезапуском, только быстро проверяем рабочий сервер.
                blip = true
                event("сеть вернулась та же (\(Self.kindOf(core))) — без перезапуска ядра")
            } else if let at = launchedAt, Date().timeIntervalSince(at) > 2 {
                // Свежие соединения вместо протухших (XHTTP/gRPC держат их долго и «висят» после смены сети).
                do {
                    try launch(current)
                } catch {
                    report.error = error.localizedDescription
                }
            }
        }
        let hint = memory.entry(memoryKey)
        let auto = pool?.auto == true
        let activeGroup = pool?.group(of: current.id) ?? "regular"
        let freeze = hint?.frozen == true || regularFrozenCount >= 2
        let probe = CheckTarget(key: "#active", id: current.id ?? "", group: activeGroup, port: healthPort, active: true)
        var extras: [CheckTarget] = []
        var unprobed = false
        if auto, let pool {
            for c in pool.candidates where c.id != current.id {
                if throttled.contains(c.id) || dnsBroken.contains(c.id) || (freeze && c.group == "regular") { continue }
                if let port = extraPorts[c.id] {
                    extras.append(CheckTarget(key: c.id, id: c.id, group: c.group, port: port, active: false))
                } else {
                    unprobed = true
                }
            }
        }
        // Подозрение на обрыв сначала проверяем лёгким запросом через рабочий сервер; не ответил — всех.
        let broad: Set<CheckReason> = [.start, .network, .retry, .dns]
        return CheckContext(reason: reason, auto: auto, activeProbe: probe, activeGroup: activeGroup, extras: extras,
                            broad: auto && broad.contains(reason) && !blip,
                            compare: (reason == .start || reason == .network) && !blip,
                            classify: (reason == .start || reason == .network || reason == .retry) && !blip,
                            blip: blip,
                            freeze: freeze, activeThrottled: current.id.map { throttled.contains($0) } ?? false,
                            single: multiBroken,
                            preferred: hint?.best, unprobed: unprobed && !multiBroken, started: DispatchTime.now())
    }

    func evaluate(_ requested: CheckReason) async {
        guard var ctx = await onWork({ self.beginCheck(requested) }) else { return }
        let box = KindBox()
        var kindTask: Task<NetKind, Never>?
        func classify() {
            guard kindTask == nil else { return }
            kindTask = Task {
                let kind = await NetworkCheck.kind()
                box.set(kind)
                return kind
            }
        }
        if ctx.classify { classify() }

        var survey = await Self.survey([ctx.activeProbe] + (ctx.broad ? ctx.extras : []), box: box,
                                       timeout: ctx.blip ? 2.5 : 4, compare: ctx.compare)
        if ctx.blip, survey.activeMS == nil {
            // Сеть та же, а рабочий молчит — соединения всё-таки протухли: обычная проверка смены сети
            // (перезапуск ядра — у запасных при этом новые проверочные порты, поэтому контекст собираем заново).
            let fresh = await onWork { () -> CheckContext? in
                self.event("после «моргания» сети рабочий не ответил — перезапуск ядра")
                self.coreFingerprint = nil
                self.evaluating = false
                return self.beginCheck(.network)
            }
            guard let fresh else { return }
            ctx = fresh
            if ctx.classify { classify() }
            survey = await Self.survey([ctx.activeProbe] + (ctx.broad ? ctx.extras : []), box: box, timeout: 4, compare: ctx.compare)
        }
        await onWork { self.trackMemory() }
        if survey.activeMS == nil, ctx.auto, !ctx.broad, !ctx.blip, !ctx.extras.isEmpty {
            // Рабочий не ответил на лёгкой проверке — проверяем все разом (и его ещё раз).
            classify()
            survey = await Self.survey([ctx.activeProbe] + ctx.extras, box: box, timeout: 4, compare: false)
        }

        // Подозрение на обрыв, а маленькая проверка проходит — проверяем объёмом (блокировка после ~16 КБ).
        // Не чаще раза в 15 минут на сервер: тревога могла быть ложной (например, долгая выгрузка файла).
        if ctx.reason == .stall, survey.activeMS != nil, !ctx.activeThrottled {
            let id = ctx.activeProbe.id
            let recent = await onWork { self.payloadOK[id].map { Date().timeIntervalSince($0) < 900 } ?? false }
            if !recent {
                switch await LatencyProbe.payload(port: ctx.activeProbe.port) {
                case .stalled(let bytes):
                    await onWork { self.markFrozen(self.active?.id, bytes: bytes) }
                    survey.activeMS = nil
                case .ok:
                    await onWork { self.payloadOK[id] = Date() }
                case .inconclusive:
                    break
                }
            }
        }

        var decision = await onWork { self.decide(survey, ctx) }

        // Ничего не нашли, а в пуле есть серверы без проверочного входа (пул обновился) — перезапускаем
        // ядро с ними и проверяем ещё раз.
        if decision.targets.isEmpty, !decision.activeAlive, ctx.unprobed {
            let reason = ctx.reason
            let refreshed = await onWork { () -> CheckContext? in
                guard let current = self.active, (try? self.launch(current)) != nil else { return nil }
                self.evaluating = false
                return self.beginCheck(reason)
            }
            if let fresh = refreshed {
                ctx = fresh
                survey = await Self.survey([ctx.activeProbe] + ctx.extras, box: box, timeout: 4, compare: false)
                decision = await onWork { self.decide(survey, ctx) }
            }
        }

        var switched: (AutoCandidate, Int)?
        if !decision.targets.isEmpty {
            switched = await switchTo(decision.targets, ctx: ctx, restoreAlive: decision.activeAlive)
        } else if !decision.activeAlive, ctx.auto, ctx.extras.isEmpty, ctx.single {
            // Ядро не принимает общий конфиг — перебираем по одному, как раньше.
            switched = await sequential(ctx)
        }

        let summary = Self.describe(survey, ctx)
        let alive = switched != nil || decision.activeAlive
        await onWork { self.finishCheck(ctx, survey: survey, switched: switched, alive: alive, summary: summary) }

        if let kindTask {
            Task {
                let kind = await kindTask.value
                await self.onWork {
                    if self.report.network != kind.rawValue { DiagLog.write("режим сети: \(kind.rawValue)", to: .tunnel) }
                    self.report.network = kind.rawValue
                    self.memory.update(self.memoryKey) { $0.kind = kind.rawValue }
                    self.publishStatus()
                }
            }
        }
        if alive { await checkDNS() }
        if alive, ctx.reason == .start || ctx.reason == .network {
            await checkPayloadIfNeeded()
        }
    }

    /// DNS через ядро. Приложениям сначала нужно узнать адрес сайта: если этот путь сломан, работает только
    /// то, что ходит по IP-адресам (Telegram), а проверка сервера (HTTP по имени сайта) проходит.
    /// Не ответил — один раз перезапускаем ядро (свежие соединения DNS); не помогло — в «Авто» уходим
    /// на другой сервер. Всё — не чаще раза на сервер в этой сети, поэтому без бесконечных перезапусков.
    func checkDNS(again: Bool = false) async {
        let plan = await onWork { () -> (port: Int, id: String, title: String, launched: Date?)? in
            guard self.report.running, !self.stopped, self.dnsReady, self.dnsPort > 0, let current = self.active,
                  self.pathSignature != "none" else { return nil }
            let id = current.id ?? ""
            if !again, let ok = self.dnsOK, ok.route == id, ok.launched == self.launchedAt,
               Date().timeIntervalSince(ok.at) < 30 { return nil }
            return (self.dnsPort, id, current.title ?? id, self.launchedAt)
        }
        guard let plan else { return }
        // Первый запрос после запуска ядра ждёт ещё и соединения DNS через сервер — даём второй шанс.
        var ms = await DNSProbe.viaCore(port: plan.port, timeout: 5)
        if ms == nil, !Task.isCancelled { ms = await DNSProbe.viaCore(port: plan.port, timeout: 4) }
        let repeatCheck = await onWork { () -> Bool in
            // Пока проверяли, сменился сервер или ядро перезапустили — результат ни о чём не говорит.
            guard self.report.running, (self.active?.id ?? "") == plan.id, self.launchedAt == plan.launched else { return false }
            if let ms {
                if self.report.dnsOK != true || again { self.event("DNS через «\(plan.title)»: ок, \(ms) мс") }
                self.report.dnsOK = true
                self.report.dnsMS = ms
                self.dnsOK = (plan.id, plan.launched, Date())
                self.dnsBroken.remove(plan.id)
                return false
            }
            let changed = self.report.dnsOK != false
            self.report.dnsOK = false
            self.report.dnsMS = nil
            self.dnsOK = nil
            defer { if changed { self.publishStatus(); TunnelSignal.post() } }
            if self.evaluating { return false }
            if !self.dnsRestarted.contains(plan.id), let current = self.active {
                self.dnsRestarted.insert(plan.id)
                self.event("DNS через «\(plan.title)» не отвечает (откроется только то, что ходит по IP, вроде Telegram) — перезапуск ядра")
                do {
                    try self.launch(current)
                    return true
                } catch {
                    self.report.error = error.localizedDescription
                    self.scheduleRetry()
                    return false
                }
            }
            guard !self.dnsBroken.contains(plan.id) else { return false }
            self.dnsBroken.insert(plan.id)
            let others = (self.pool?.candidates ?? []).contains { $0.id != plan.id && !self.dnsBroken.contains($0.id) }
            if self.pool?.auto == true, others {
                self.event("DNS через «\(plan.title)» не отвечает и после перезапуска — ищем другой сервер")
                self.scheduleCheck(.dns, delay: 0)
            } else {
                self.event("DNS через «\(plan.title)» не отвечает и после перезапуска")
                self.post("Через «\(plan.title)» не открываются сайты — попробуйте другой сервер")
            }
            return false
        }
        if repeatCheck {
            try? await Task.sleep(nanoseconds: 700_000_000)
            await checkDNS(again: true)
        }
    }

    /// Параллельная проверка через проверочные входы ядра с ранним выходом:
    /// не ждём таймаутов, если лучшая доступная группа уже понятна.
    static func survey(_ targets: [CheckTarget], box: KindBox, timeout: Double, compare: Bool) async -> Survey {
        var result = Survey()
        guard !targets.isEmpty else { return result }
        let start = DispatchTime.now()
        let elapsed = { Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9 }
        return await withTaskGroup(of: SurveyEvent.self) { group -> Survey in
            for t in targets {
                group.addTask { .result(t.key, await LatencyProbe.viaProxy(port: t.port, timeout: timeout)) }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 100_000_000)
                return .tick
            }
            var pending: [String: CheckTarget] = [:]
            for t in targets { pending[t.key] = t }
            var firstOK: [Int: Double] = [:]
            var activeOK = false

            func canStop(_ now: Double) -> Bool {
                let verdict = box.kind
                // Белый список: обычные (зарубежные) запасные не ответят — не ждём их.
                let live = pending.values.filter { $0.active || !(verdict == .whitelist && $0.group == "regular") }
                if live.isEmpty { return true }
                guard let best = firstOK.keys.min(), let t = firstOK[best] else { return false }
                if live.contains(where: { AutoPool.rank($0.group) < best }) {
                    // Группа получше ещё молчит. Живой сервер отвечает не сильно дольше уже ответившего.
                    return now >= t + max(1.0, t)
                }
                if activeOK && !compare { return true }
                if live.contains(where: { AutoPool.rank($0.group) == best }) {
                    let activeWaiting = live.contains { $0.active }
                    return now >= t + (activeWaiting ? max(0.8, t) : max(0.3, t * 0.5))
                }
                return true
            }

            while let event = await group.next() {
                let now = elapsed()
                switch event {
                case let .result(key, ms):
                    guard let t = pending.removeValue(forKey: key) else { break }
                    if t.active { result.activeChecked = true }
                    if let ms {
                        if t.active {
                            result.activeMS = ms
                            activeOK = true
                        } else {
                            result.ok[t.id] = ms
                        }
                        let rank = AutoPool.rank(t.group)
                        if firstOK[rank] == nil { firstOK[rank] = now }
                    } else if !t.active {
                        result.failed.insert(t.id)
                    }
                case .tick:
                    if !pending.isEmpty {
                        group.addTask {
                            try? await Task.sleep(nanoseconds: 100_000_000)
                            return .tick
                        }
                    }
                }
                if pending.isEmpty || now > timeout + 0.3 || canStop(now) {
                    group.cancelAll()
                    break
                }
            }
            result.seconds = elapsed()
            return result
        }
    }

    /// На очереди work: на какой сервер переключаться (по порядку попыток).
    func decide(_ s: Survey, _ ctx: CheckContext) -> Decision {
        for (id, ms) in s.ok { stats[id, default: CandidateStat()].ok(ms) }
        for id in s.failed { stats[id, default: CandidateStat()].fail() }
        let activeID = active?.id
        if let activeID {
            if let ms = s.activeMS { stats[activeID, default: CandidateStat()].ok(ms) }
            else if s.activeChecked { stats[activeID, default: CandidateStat()].fail() }
        }
        let alive = s.activeMS != nil
        guard ctx.auto, let pool else { return Decision(targets: [], activeAlive: alive) }
        // Замирание могли обнаружить посреди этой проверки (объёмный замер рабочего).
        let freeze = ctx.freeze || regularFrozenCount >= 2

        let usable = pool.candidates.filter { c in
            s.ok[c.id] != nil && c.id != activeID && !throttled.contains(c.id) && !dnsBroken.contains(c.id)
                && !(freeze && c.group == "regular")
        }
        let ranked = usable.sorted { a, b in
            let ra = AutoPool.rank(a.group), rb = AutoPool.rank(b.group)
            if ra != rb { return ra < rb }
            return score(a.id, load: a.load, ms: s.ok[a.id] ?? 9999, preferred: ctx.preferred)
                < score(b.id, load: b.load, ms: s.ok[b.id] ?? 9999, preferred: ctx.preferred)
        }
        // «Рабочий жив, но в этой сети замирает» — ищем другой, но если других нет, остаёмся.
        // Через рабочий не проходят DNS-запросы — для приложений он мёртв, хоть проверка и отвечает.
        let activeGood = alive && !(activeID.map { throttled.contains($0) || dnsBroken.contains($0) } ?? false)
            && !(freeze && ctx.activeGroup == "regular")
        if !activeGood { return Decision(targets: AutoPool.diverse(ranked), activeAlive: alive) }
        guard let best = ranked.first else { return Decision(targets: [], activeAlive: true) }
        let activeRank = AutoPool.rank(ctx.activeGroup)
        if AutoPool.rank(best.group) < activeRank {
            // Например, были на мосту, а в новой сети заработали обычные серверы.
            return Decision(targets: Array(ranked.filter { AutoPool.rank($0.group) < activeRank }.prefix(3)), activeAlive: true)
        }
        if ctx.compare, AutoPool.rank(best.group) == activeRank, let ams = s.activeMS {
            let load = pool.candidates.first { $0.id == activeID }?.load
            let mine = score(activeID, load: load, ms: ams, preferred: ctx.preferred)
            let theirs = score(best.id, load: best.load, ms: s.ok[best.id] ?? 9999, preferred: ctx.preferred)
            // Гистерезис: соединения после смены сети всё равно новые, но ради мелочи не переключаемся.
            if theirs < mine * 0.7 && mine - theirs >= 60 { return Decision(targets: [best], activeAlive: true) }
        }
        return Decision(targets: [], activeAlive: true)
    }

    /// Сколько обычных серверов «замерло» в этой сети. На очереди work.
    var regularFrozenCount: Int {
        throttled.filter { pool?.group(of: $0) == "regular" }.count
    }

    /// Ниже — лучше: сглаженная задержка, штраф за неудачи и нагрузку узла, бонус «работал в этой сети».
    func score(_ id: String?, load: Double?, ms: Int, preferred: String?) -> Double {
        let stat = id.flatMap { stats[$0] }
        var value = stat?.ewma ?? Double(ms)
        value += Double(stat?.fails ?? 0) * 120
        value += min(1, max(0, load ?? 0)) * 150
        if let id, id == preferred { value *= 0.85 }
        return value
    }

    /// Переключение и короткая проверка. Рабочий сервер жив (переходим на лучший) — без перезапуска ядра,
    /// VPN не моргает. Рабочий умер или «замирает» — перезапуском: зависшие соединения сбрасываются,
    /// и приложения сразу переподключаются. Не вышло ни с кем — возвращаем прежний.
    private func switchTo(_ targets: [AutoCandidate], ctx: CheckContext, restoreAlive: Bool) async -> (AutoCandidate, Int)? {
        // Уходим с «замершего» сервера — новый обычный проверяем и объёмом, иначе он замрёт так же.
        let plan = await onWork { () -> (verify: Bool, hot: Bool, original: Active?) in
            let activeThrottled = (self.active?.id).map { self.throttled.contains($0) } == true
            // С сервера, через который не шёл DNS, уходим перезапуском: DNS ядра держит соединения через него.
            let activeDNS = (self.active?.id).map { self.dnsBroken.contains($0) } == true
            let verify = ctx.reason == .stall && activeThrottled
            let hot = restoreAlive && !activeThrottled && !activeDNS && !(ctx.freeze && ctx.activeGroup == "regular")
                && !self.routeTags.isEmpty
            if !hot, self.startCompletion == nil { self.reasserting = true }
            return (verify, hot, self.active)
        }
        let original = plan.original
        var found: (AutoCandidate, Int)?
        for candidate in targets {
            let target = Active(id: candidate.id, title: candidate.title, config: candidate.config)
            let mode = await onWork { () -> String? in
                if plan.hot, self.hotSwitch(target) { return "hot" }
                if self.startCompletion == nil { self.reasserting = true }
                do {
                    try self.launch(target)
                    return "restart"
                } catch {
                    self.report.error = error.localizedDescription
                    return nil
                }
            }
            guard let mode else { continue }
            if mode == "restart" { try? await Task.sleep(nanoseconds: 150_000_000) }
            if let ms = await LatencyProbe.viaProxy(port: ctx.activeProbe.port, timeout: 3) {
                if plan.verify, candidate.group == "regular",
                   case .stalled(let bytes) = await LatencyProbe.payload(port: ctx.activeProbe.port) {
                    await onWork { self.markFrozen(candidate.id, bytes: bytes) }
                    continue
                }
                found = (candidate, ms)
                if mode == "hot" { await onWork { self.event("«\(candidate.title)»: без перезапуска ядра") } }
                break
            }
            await onWork { self.stats[candidate.id, default: CandidateStat()].fail() }
        }
        let result = found
        await onWork {
            if result == nil, let original {
                let back = self.active?.id == original.id && self.report.running
                if !back, !self.hotSwitch(original), (try? self.launch(original)) == nil {
                    self.report.error = "не удалось вернуть прежний сервер"
                    DiagLog.warn("не удалось вернуть прежний сервер «\(original.title ?? "?")»", to: .tunnel)
                }
            }
            self.reasserting = false
        }
        return result
    }

    /// Запасной путь без общего конфига: кандидаты по задержке до сервера, каждый — перезапуск ядра.
    private func sequential(_ ctx: CheckContext) async -> (AutoCandidate, Int)? {
        let list = await onWork { () -> [AutoCandidate] in
            (self.pool?.candidates ?? []).filter {
                $0.id != self.active?.id && !self.throttled.contains($0.id) && !self.dnsBroken.contains($0.id)
            }
        }
        guard !list.isEmpty else { return nil }
        let pings = await LatencyProbe.direct(list.compactMap(\.target), timeout: 2)
        let ordered = list
            .filter { pings[$0.id] != nil || ($0.target?.udp ?? true) }
            .sorted { a, b in
                let ra = AutoPool.rank(a.group), rb = AutoPool.rank(b.group)
                if ra != rb { return ra < rb }
                return (pings[a.id] ?? 9999) < (pings[b.id] ?? 9999)
            }
        return await switchTo(Array(ordered.prefix(4)), ctx: ctx, restoreAlive: false)
    }

    /// На очереди work.
    private func markFrozen(_ id: String?, bytes: Int) {
        guard let id else { return }
        throttled.insert(id)
        event("«\(active?.title ?? id)»: соединение замирает после \(bytes / 1024) КБ")
        // Замерли два обычных сервера — значит, дело в сети: запоминаем (мобильная — на 20 мин, Wi‑Fi — на 2 ч).
        if pool?.group(of: id) == "regular", regularFrozenCount >= 2 {
            let ttl: TimeInterval = (memoryKey ?? "").hasPrefix("cellular") ? 20 * 60 : 2 * 3600
            memory.update(memoryKey) { $0.freezeUntil = Date().addingTimeInterval(ttl) }
            event("обычные серверы в этой сети замирают — берём мосты")
        }
    }

    /// Новая сеть и обычный сервер: один раз в сутки проверяем объёмом (≈100 КБ), не «замирает» ли.
    private func checkPayloadIfNeeded() async {
        let start = await onWork { () -> (port: Int, launched: Date?)? in
            guard self.report.running, let id = self.active?.id, self.pool?.group(of: id) == "regular" else { return nil }
            let entry = self.memory.entry(self.memoryKey)
            if entry?.frozen == true { return nil }
            if let at = entry?.payloadAt, Date().timeIntervalSince(at) < 86400 { return nil }
            return (self.healthPort, self.launchedAt)
        }
        guard let start else { return }
        let verdict = await LatencyProbe.payload(port: start.port)
        await onWork {
            // Ядро перезапускали посреди замера — он ничего не значит.
            guard self.launchedAt == start.launched, !self.evaluating else { return }
            switch verdict {
            case .ok(let speed):
                if let id = self.active?.id { self.payloadOK[id] = Date() }
                self.memory.update(self.memoryKey) { $0.payloadAt = Date(); $0.freezeUntil = nil }
                self.event("проверка объёмом: ок, \(speed) КБ/с")
            case .stalled(let bytes):
                self.markFrozen(self.active?.id, bytes: bytes)
                self.scheduleCheck(.stall, delay: 0)
            case .inconclusive:
                break
            }
            self.memory.save()
        }
    }

    static func describe(_ s: Survey, _ ctx: CheckContext) -> String {
        let active = s.activeMS.map { "\($0) мс" } ?? (s.activeChecked ? "нет ответа" : "—")
        var text = "\(ctx.reason.rawValue): рабочий \(active)"
        if !s.ok.isEmpty || !s.failed.isEmpty {
            text += ", запасные \(s.ok.count)/\(s.ok.count + s.failed.count)"
        }
        text += String(format: ", %.1f с", s.seconds)
        return text
    }

    /// На очереди work: итог проверки, память, повтор при неудаче.
    private func finishCheck(_ ctx: CheckContext, survey: Survey, switched: (AutoCandidate, Int)?, alive: Bool, summary: String) {
        let elapsed = LatencyProbe.elapsedMS(since: ctx.started)
        lastCheck = Date()
        report.healthy = alive
        if let pair = switched {
            let candidate = pair.0
            report.pingMS = pair.1
            report.lastSwitchMS = elapsed
            event("\(summary) → «\(candidate.title)» за \(String(format: "%.1f", Double(elapsed) / 1000)) с")
            if ctx.reason != .start {
                let kind = Self.groupTitle(candidate.group)
                let old = pool?.candidates.first { $0.id == ctx.activeProbe.id }?.title ?? "Сервер"
                if ctx.reason == .network {
                    post("Сеть сменилась — подключили «\(candidate.title)»\(kind)")
                } else if ctx.reason == .dns {
                    post("Через «\(old)» не открывались сайты — подключили «\(candidate.title)»\(kind)")
                } else if survey.activeChecked && survey.activeMS == nil {
                    post("«\(old)» перестал отвечать — подключили «\(candidate.title)»\(kind)")
                } else {
                    post("Подключили «\(candidate.title)»\(kind) — он работает лучше")
                }
            }
        } else {
            if let ms = survey.activeMS { report.pingMS = ms }
            event(summary)
        }
        if alive {
            retryStep = 0
            failureNoted = false
            if let id = active?.id {
                memory.lastActive = id
                memory.update(memoryKey) { $0.best = id }
            }
            if ctx.reason == .stall && switched == nil { stallSpacing = min(stallSpacing * 2, 320) }
        } else {
            if !failureNoted && ctx.reason != .start && ctx.auto {
                post("В этой сети серверы не отвечают — пробуем снова")
            }
            failureNoted = true
            scheduleRetry()
        }
        memory.save()
        evaluating = false
        report.checking = false
        finishStart()
        publishStatus()
        TunnelSignal.post()
    }

    static func groupTitle(_ group: String) -> String {
        switch group {
        case "bridge": return " (мост)"
        case "reserve": return " (обход белых списков)"
        default: return ""
        }
    }
}
