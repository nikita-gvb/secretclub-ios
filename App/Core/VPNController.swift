import Foundation
import NetworkExtension
import Observation

struct ConnectRequest {
    let config: String
    let routeID: String
    let routeTitle: String
    let onDemand: Bool
    let killSwitch: Bool
    /// JSON AutoPool — запасные серверы, на которые расширение переключится само.
    var pool: String? = nil
}

struct VPNError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

@MainActor
@Observable
final class VPNController {
    enum State: Equatable {
        case disconnected, preparing, connecting, connected, disconnecting, invalid
    }

    var state: State = .disconnected
    var connectedSince: Date?
    var lastError: String?
    var bytesIn: Int64 = 0
    var bytesOut: Int64 = 0
    var report: TunnelReport?
    /// Скорость сейчас (байт/с) и история за последние ~40 секунд — для сводки.
    var rateIn: Double = 0
    var rateOut: Double = 0
    var rateHistory: [Double] = Array(repeating: 0, count: 40)
    @ObservationIgnored private var lastSample: (date: Date, down: Int64, up: Int64)?

    @ObservationIgnored private var manager: NETunnelProviderManager?
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var statsTask: Task<Void, Never>?
    @ObservationIgnored private var foreground = true
    @ObservationIgnored private(set) var isDemo = false
    /// Каждый свежий отчёт расширения (сервер мог смениться сам).
    @ObservationIgnored var onReport: (@MainActor (TunnelReport) -> Void)?

    static var tunnelBundleID: String {
        (Bundle.main.bundleIdentifier ?? "com.secretclub.app") + ".tunnel"
    }

    /// Туннель поднят или поднимается.
    var isActive: Bool { state == .connected || state == .connecting || state == .preparing }
    var isBusy: Bool { state == .connecting || state == .disconnecting || state == .preparing }

    func enableDemo(connected: Bool) {
        isDemo = true
        if connected {
            state = .connected
            connectedSince = Date().addingTimeInterval(-(42 * 60 + 17))
            bytesIn = 2_576_980_378
            bytesOut = 327_155_712
            rateIn = 4.4 * 1_048_576
            rateOut = 0.6 * 1_048_576
            rateHistory = (0..<40).map { i in
                let x = Double(i)
                return (3.2 + 1.1 * sin(x / 3.1) + 0.6 * sin(x / 1.3 + 1) + 0.25 * cos(x * 1.7)) * 1_048_576
            }
            startDemoTicker()
        }
    }

    /// Демо: живые цифры скорости и трафика.
    private func startDemoTicker() {
        statsTask?.cancel()
        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                guard self.state == .connected else { continue }
                let next = max(0.4, min(7.5, self.rateIn / 1_048_576 + Double.random(in: -0.9...0.95))) * 1_048_576
                self.rateIn = next
                self.rateOut = next * Double.random(in: 0.1...0.2)
                self.bytesIn += Int64(next)
                self.bytesOut += Int64(self.rateOut)
                self.rateHistory.append(next)
                self.rateHistory.removeFirst()
            }
        }
    }

    /// Новые счётчики трафика от расширения → скорость.
    private func sample(_ r: TunnelReport) {
        let now = Date()
        if let last = lastSample {
            let dt = now.timeIntervalSince(last.date)
            if dt > 0.3 {
                rateIn = max(0, Double(r.downlink - last.down) / dt)
                rateOut = max(0, Double(r.uplink - last.up) / dt)
                rateHistory.append(rateIn)
                if rateHistory.count > 40 { rateHistory.removeFirst(rateHistory.count - 40) }
            }
        }
        lastSample = (now, r.downlink, r.uplink)
    }

    private func resetRates() {
        lastSample = nil
        rateIn = 0
        rateOut = 0
        rateHistory = Array(repeating: 0, count: 40)
    }

    func load() async {
        guard !isDemo else { return }
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            let mine = managers.first {
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == Self.tunnelBundleID
            } ?? managers.first
            if let m = mine {
                manager = m
                observe(m)
                update(m.connection.status)
            }
        } catch {
            lastError = Self.describe(error)
        }
    }

    // MARK: - Подключение

    /// Пока приложение выбирает сервер — показываем «подключаемся».
    func beginPreparing() {
        lastError = nil
        if state == .disconnected || state == .invalid { state = .preparing }
    }

    func cancelPreparing(_ error: String?) {
        if state == .preparing { state = .disconnected }
        lastError = error
    }

    private func prepareManager(_ request: ConnectRequest?) async throws -> NETunnelProviderManager {
        let m = manager ?? NETunnelProviderManager()
        let proto = (m.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
        proto.providerBundleIdentifier = Self.tunnelBundleID
        if let request {
            proto.serverAddress = request.routeTitle
            proto.providerConfiguration = [
                TunnelOption.config: request.config,
                TunnelOption.routeID: request.routeID,
                TunnelOption.routeTitle: request.routeTitle,
            ]
            proto.includeAllNetworks = request.killSwitch
            proto.excludeLocalNetworks = true
            let rule = NEOnDemandRuleConnect()
            rule.interfaceTypeMatch = .any
            m.onDemandRules = [rule]
            m.isOnDemandEnabled = request.onDemand
        } else if proto.serverAddress?.isEmpty ?? true {
            proto.serverAddress = "SecretClub"
        }
        proto.disconnectOnSleep = false
        m.protocolConfiguration = proto
        m.localizedDescription = "SecretClub"
        m.isEnabled = true
        try await m.saveToPreferences()
        try await m.loadFromPreferences()
        manager = m
        observe(m)
        return m
    }

    func connect(_ request: ConnectRequest) async throws {
        lastError = nil
        if isDemo {
            state = .connecting
            try? await Task.sleep(for: .seconds(1.6))
            guard state == .connecting else { return }
            state = .connected
            connectedSince = Date()
            if statsTask == nil { startDemoTicker() }
            return
        }
        state = .connecting
        let m: NETunnelProviderManager
        do {
            m = try await prepareManager(request)
            var options: [String: NSObject] = [
                TunnelOption.config: request.config as NSString,
                TunnelOption.routeID: request.routeID as NSString,
                TunnelOption.routeTitle: request.routeTitle as NSString,
            ]
            if let pool = request.pool { options[TunnelOption.pool] = pool as NSString }
            try m.connection.startVPNTunnel(options: options)
        } catch {
            state = .disconnected
            throw VPNError(Self.describe(error))
        }
        let status = await waitForOutcome(m, timeout: 40)
        update(status)
        guard status == .connected else {
            let reason = await disconnectReason(m)
            throw VPNError(reason ?? "Не удалось подключиться к «\(request.routeTitle)». Попробуйте другой сервер.")
        }
    }

    /// Смена сервера без разрыва туннеля.
    func reload(_ request: ConnectRequest) async -> Bool {
        if isDemo { return true }
        guard state == .connected else { return false }
        let command = TunnelCommand(kind: .reload, config: request.config, routeID: request.routeID, routeTitle: request.routeTitle)
        guard let reply = await send(command, attempts: 1, timeout: 25) else { return false }
        report = reply
        onReport?(reply)
        if let error = reply.error, !reply.running { lastError = "Сервер не запустился: \(error)" }
        return reply.running && reply.error == nil
    }

    func disconnect() async {
        if isDemo {
            state = .disconnected
            connectedSince = nil
            rateIn = 0
            rateOut = 0
            return
        }
        guard let m = manager else { state = .disconnected; return }
        if m.isOnDemandEnabled {
            m.isOnDemandEnabled = false
            try? await m.saveToPreferences()
        }
        m.connection.stopVPNTunnel()
        _ = await waitForOutcome(m, timeout: 8)
    }

    /// Автоподключение (On Demand) можно переключить без переподключения.
    func setOnDemand(_ enabled: Bool) async {
        guard !isDemo, let m = manager, m.protocolConfiguration != nil else { return }
        guard m.isOnDemandEnabled != enabled else { return }
        if enabled, m.onDemandRules?.isEmpty ?? true {
            let rule = NEOnDemandRuleConnect()
            rule.interfaceTypeMatch = .any
            m.onDemandRules = [rule]
        }
        m.isOnDemandEnabled = enabled
        try? await m.saveToPreferences()
    }

    private func waitForOutcome(_ m: NETunnelProviderManager, timeout: Double) async -> NEVPNStatus {
        let start = Date()
        var moved = false
        while Date().timeIntervalSince(start) < timeout {
            let status = m.connection.status
            switch status {
            case .connected:
                return status
            case .connecting, .reasserting, .disconnecting:
                moved = true
            case .disconnected, .invalid:
                if moved || Date().timeIntervalSince(start) > 3 { return status }
            @unknown default:
                break
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return m.connection.status
    }

    private func disconnectReason(_ m: NETunnelProviderManager) async -> String? {
        do {
            try await m.connection.fetchLastDisconnectError()
            return nil
        } catch {
            let ns = error as NSError
            if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
                return underlying.localizedDescription
            }
            return Self.describe(error)
        }
    }

    // MARK: - Сообщения расширению

    func send(_ command: TunnelCommand, attempts: Int = 3, timeout: Double = 4) async -> TunnelReport? {
        guard let data = TunnelCoding.encode(command) else { return nil }
        for attempt in 0..<attempts {
            if let reply = await sendRaw(data, timeout: timeout), let report = TunnelCoding.decode(TunnelReport.self, reply) {
                return report
            }
            if attempt < attempts - 1 { try? await Task.sleep(for: .milliseconds(400 * (attempt + 1))) }
        }
        return nil
    }

    private func sendRaw(_ data: Data, timeout: Double) async -> Data? {
        guard let session = manager?.connection as? NETunnelProviderSession else { return nil }
        return await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            let once = ResumeOnce(cont)
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { once.resume(nil) }
            do {
                try session.sendProviderMessage(data) { reply in once.resume(reply) }
            } catch {
                once.resume(nil)
            }
        }
    }

    /// Передать расширению свежий список запасных серверов.
    func sendPool(_ pool: AutoPool) async {
        guard !isDemo, state == .connected else { return }
        _ = await send(TunnelCommand(kind: .pool, pool: pool), attempts: 2, timeout: 5)
    }

    /// Попросить расширение проверить сервер (network — сменилась сеть).
    func requestCheck(network: Bool) async {
        guard !isDemo, state == .connected else { return }
        _ = await send(TunnelCommand(kind: .check, reason: network ? "network" : "app"), attempts: 1, timeout: 3)
    }

    func setForeground(_ value: Bool) {
        foreground = value
        if value, state == .connected { startStats() } else if !value { stopStats() }
    }

    private func startStats() {
        guard !isDemo, statsTask == nil else { return }
        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let r = await self.send(TunnelCommand(kind: .status), attempts: 1, timeout: 2) {
                    if self.report != r { self.report = r }
                    self.sample(r)
                    self.bytesIn = r.downlink
                    self.bytesOut = r.uplink
                    self.onReport?(r)
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func stopStats() {
        statsTask?.cancel()
        statsTask = nil
        lastSample = nil
    }

    // MARK: - Диагностика

    /// Если VPN включён — проверяет ядро и выход в интернет через туннель.
    /// Если выключен — поднимает пробный туннель без перехвата трафика.
    func selfTest() async -> [DiagnosticStep] {
        if isDemo { return DemoData.permissionSteps }
        var steps: [DiagnosticStep] = []

        if state == .connected {
            steps.append(DiagnosticStep(ok: true, text: "VPN подключён"))
            if let r = await send(TunnelCommand(kind: .status), attempts: 5, timeout: 3) {
                report = r
                if r.running {
                    steps.append(DiagnosticStep(ok: true, text: "Ядро Xray \(r.coreVersion) работает"))
                } else {
                    steps.append(DiagnosticStep(ok: false, text: "Ядро не запущено: \(r.error ?? "причина неизвестна")"))
                }
                if let mb = r.memoryMB {
                    steps.append(DiagnosticStep(ok: mb < 45, text: "Память расширения: \(Int(mb.rounded())) МБ из 50"))
                }
            } else {
                steps.append(DiagnosticStep(ok: false, text: "Расширение не ответило на запрос статуса"))
            }
            if let trace = await NetworkProbe.trace() {
                steps.append(DiagnosticStep(ok: true, text: "Интернет через VPN: IP \(trace.ip)\(trace.location.map { ", \($0)" } ?? ""), \(trace.ms) мс"))
            } else {
                steps.append(DiagnosticStep(ok: false, text: "Через туннель нет доступа в интернет"))
            }
            return steps
        }

        let m: NETunnelProviderManager
        do {
            m = try await prepareManager(nil)
            steps.append(DiagnosticStep(ok: true, text: "VPN-профиль создан"))
        } catch {
            steps.append(DiagnosticStep(ok: false, text: "Профиль не создан: \(Self.describe(error))"))
            return steps
        }
        do {
            try m.connection.startVPNTunnel(options: [TunnelOption.probe: NSNumber(value: true)])
        } catch {
            steps.append(DiagnosticStep(ok: false, text: "Туннель не запустился: \(Self.describe(error))"))
            return steps
        }
        let status = await waitForOutcome(m, timeout: 15)
        guard status == .connected else {
            let reason = await disconnectReason(m)
            steps.append(DiagnosticStep(ok: false, text: "Туннель не поднялся: \(reason ?? "статус \(status.rawValue)"). Возможно, сертификат без Network Extension."))
            return steps
        }
        steps.append(DiagnosticStep(ok: true, text: "Пробный туннель запущен"))
        try? await Task.sleep(for: .milliseconds(500))
        if let r = await send(TunnelCommand(kind: .status), attempts: 5, timeout: 3) {
            steps.append(DiagnosticStep(ok: true, text: "Расширение отвечает, ядро Xray \(r.coreVersion)"))
        } else {
            steps.append(DiagnosticStep(ok: false, text: "Расширение не ответило"))
        }
        m.connection.stopVPNTunnel()
        _ = await waitForOutcome(m, timeout: 5)
        return steps
    }

    // MARK: - Статус

    private func observe(_ m: NETunnelProviderManager) {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: m.connection, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let status = self.manager?.connection.status else { return }
                self.update(status)
            }
        }
    }

    private func update(_ status: NEVPNStatus) {
        let probe = report?.probe == true
        switch status {
        case .connected:
            state = .connected
            connectedSince = manager?.connection.connectedDate ?? Date()
            if foreground && !probe { startStats() }
        case .connecting, .reasserting:
            state = .connecting
        case .disconnecting:
            state = .disconnecting
        case .invalid:
            state = .invalid
            connectedSince = nil
            stopStats()
        default:
            if state != .preparing { state = .disconnected }
            connectedSince = nil
            bytesIn = 0
            bytesOut = 0
            report = nil
            stopStats()
            resetRates()
        }
    }

    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NEVPNErrorDomain, let code = NEVPNError.Code(rawValue: ns.code) {
            switch code {
            case .configurationReadWriteFailed:
                return "нет доступа к настройкам VPN — вероятно, сертификат подписи без Network Extension"
            case .configurationInvalid:
                return "некорректная конфигурация VPN"
            case .configurationDisabled:
                return "VPN-профиль выключен в настройках"
            case .connectionFailed:
                return "не удалось подключиться"
            case .configurationStale:
                return "настройки устарели, попробуйте ещё раз"
            default:
                break
            }
        }
        if ns.domain == "NEConfigurationErrorDomain" {
            return "ошибка конфигурации VPN (\(ns.code)): \(ns.localizedDescription)"
        }
        return ns.localizedDescription
    }
}
