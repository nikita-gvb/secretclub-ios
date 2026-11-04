import Foundation
import NetworkExtension
import Observation

@MainActor
@Observable
final class VPNController {
    enum State: Equatable {
        case disconnected, connecting, connected, disconnecting, invalid
    }

    var state: State = .disconnected
    var connectedSince: Date?
    var lastError: String?
    var bytesIn: Int64 = 0
    var bytesOut: Int64 = 0

    @ObservationIgnored private var manager: NETunnelProviderManager?
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private(set) var isDemo = false

    static var tunnelBundleID: String {
        (Bundle.main.bundleIdentifier ?? "com.secretclub.app") + ".tunnel"
    }

    func enableDemo(connected: Bool) {
        isDemo = true
        if connected {
            state = .connected
            connectedSince = Date().addingTimeInterval(-(42 * 60 + 17))
            bytesIn = 2_576_980_378
            bytesOut = 327_155_712
        }
    }

    func load() async {
        guard !isDemo else { return }
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            if let m = managers.first {
                manager = m
                observe(m)
                update(m.connection.status)
            }
        } catch {
            lastError = Self.describe(error)
        }
    }

    private func prepareManager() async throws -> NETunnelProviderManager {
        let m = manager ?? NETunnelProviderManager()
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = Self.tunnelBundleID
        proto.serverAddress = "SecretClub"
        m.protocolConfiguration = proto
        m.localizedDescription = "SecretClub"
        m.isEnabled = true
        try await m.saveToPreferences()
        try await m.loadFromPreferences()
        manager = m
        observe(m)
        return m
    }

    func connect() async {
        lastError = nil
        if isDemo {
            state = .connecting
            try? await Task.sleep(for: .seconds(1))
            state = .connected
            connectedSince = Date()
            return
        }
        state = .connecting
        do {
            let m = try await prepareManager()
            try m.connection.startVPNTunnel()
        } catch {
            lastError = Self.describe(error)
            state = .disconnected
        }
    }

    func disconnect() {
        if isDemo {
            state = .disconnected
            connectedSince = nil
            return
        }
        manager?.connection.stopVPNTunnel()
    }

    /// Проверка, что подпись приложения позволяет запускать VPN.
    func permissionTest() async -> [DiagnosticStep] {
        if isDemo { return DemoData.permissionSteps }
        var steps: [DiagnosticStep] = []
        let m: NETunnelProviderManager
        do {
            m = try await prepareManager()
            steps.append(DiagnosticStep(ok: true, text: "VPN-профиль создан"))
        } catch {
            steps.append(DiagnosticStep(ok: false, text: "Профиль не создан: \(Self.describe(error))"))
            return steps
        }

        let wasConnected = m.connection.status == .connected
        if !wasConnected {
            do {
                try m.connection.startVPNTunnel()
            } catch {
                steps.append(DiagnosticStep(ok: false, text: "Туннель не запустился: \(Self.describe(error))"))
                return steps
            }
            for _ in 0..<40 {
                if m.connection.status == .connected { break }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        guard m.connection.status == .connected else {
            steps.append(DiagnosticStep(ok: false, text: "Туннель не поднялся (статус \(m.connection.status.rawValue)). Скорее всего, сертификат не поддерживает Network Extension."))
            return steps
        }
        steps.append(DiagnosticStep(ok: true, text: "Пробный туннель запущен"))

        if let session = m.connection as? NETunnelProviderSession {
            let reply: String? = await withCheckedContinuation { cont in
                do {
                    try session.sendProviderMessage(Data("ping".utf8)) { data in
                        cont.resume(returning: data.flatMap { String(data: $0, encoding: .utf8) })
                    }
                } catch {
                    cont.resume(returning: nil)
                }
            }
            let ok = reply == "pong"
            steps.append(DiagnosticStep(ok: ok, text: ok ? "Расширение отвечает" : "Расширение не ответило"))
        }
        if !wasConnected { m.connection.stopVPNTunnel() }
        return steps
    }

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
        switch status {
        case .connected:
            state = .connected
            connectedSince = manager?.connection.connectedDate ?? Date()
        case .connecting, .reasserting:
            state = .connecting
        case .disconnecting:
            state = .disconnecting
        case .invalid:
            state = .invalid
            connectedSince = nil
        default:
            state = .disconnected
            connectedSince = nil
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
