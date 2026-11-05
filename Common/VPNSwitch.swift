import Foundation
import NetworkExtension

/// Включение и выключение VPN без интерфейса приложения: виджеты, Пункт управления, «Команды».
/// Берёт профиль, который создало приложение: расширение VPN запустится с последним сервером
/// (в «Авто» — с последним рабочим из списка запасных).
enum VPNSwitch {
    enum Status: String {
        case on, connecting, off
        /// Профиля VPN ещё нет — нужно один раз подключиться в приложении.
        case missing

        var isOn: Bool { self == .on || self == .connecting }
    }

    struct Snapshot {
        var status: Status
        /// Последний выбранный в приложении сервер (имя профиля VPN).
        var routeTitle: String?
        var connectedDate: Date?
    }

    struct SwitchError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func manager() async throws -> NETunnelProviderManager? {
        let all = try await NETunnelProviderManager.loadAllFromPreferences()
        return all.first {
            ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier?.hasSuffix(".tunnel") == true
        } ?? all.first
    }

    static func status(of manager: NETunnelProviderManager) -> Status {
        switch manager.connection.status {
        case .connected: return .on
        case .connecting, .reasserting: return .connecting
        default: return .off
        }
    }

    static func snapshot() async -> Snapshot {
        guard let m = try? await manager() else { return Snapshot(status: .missing) }
        let title = (m.protocolConfiguration as? NETunnelProviderProtocol)?.serverAddress
        return Snapshot(status: status(of: m), routeTitle: title == "SecretClub" ? nil : title,
                        connectedDate: m.connection.status == .connected ? m.connection.connectedDate : nil)
    }

    static func status() async -> Status { await snapshot().status }

    /// Где выполняется команда: в приложении (iOS запускает его в фоне) или в расширении виджета.
    static var process: String { Bundle.main.bundleURL.pathExtension == "appex" ? "виджет" : "приложение" }

    /// Включить или выключить. source — откуда (для журнала диагностики).
    /// Ждёт итога (до ~15 с), чтобы виджет и Пункт управления сразу показали настоящее состояние.
    static func set(_ on: Bool, source: String) async throws {
        let m: NETunnelProviderManager
        do {
            guard let found = try await manager() else {
                throw SwitchError(message: "Откройте SecretClub и подключитесь один раз — после этого VPN можно включать отсюда.")
            }
            m = found
        } catch let error as SwitchError {
            throw error
        } catch {
            DiagLog.warn("\(source) (\(process)): профиль VPN не прочитан: \(error.localizedDescription)", to: .app)
            throw SwitchError(message: "Не удалось прочитать настройки VPN: \(error.localizedDescription)")
        }
        // Подписка закончилась — не держим VPN включённым насильно: без неё сервер не пустит,
        // а постоянные попытки переподключения оставили бы телефон без интернета.
        let usable = AppGroup.defaults?.object(forKey: SharedKey.subscriptionUsable) as? Bool ?? true
        let autoConnect = SharedKey.keepOn && usable
        do {
            if on {
                // Выключали отсюда же — возвращаем «Держать VPN включённым», если оно включено в приложении.
                let needsOnDemand = autoConnect && !m.isOnDemandEnabled
                if !m.isEnabled || needsOnDemand {
                    m.isEnabled = true
                    if needsOnDemand {
                        if m.onDemandRules?.isEmpty ?? true {
                            let rule = NEOnDemandRuleConnect()
                            rule.interfaceTypeMatch = .any
                            m.onDemandRules = [rule]
                        }
                        m.isOnDemandEnabled = true
                    }
                    try await m.saveToPreferences()
                    try await m.loadFromPreferences()
                }
                if status(of: m).isOn { return }
                try m.connection.startVPNTunnel()
                DiagLog.write("\(source) (\(process)): включение VPN", to: .app)
                // «Подключено» расширение сообщает после проверки сервера (обычно 1–3 с, не дольше 9 с).
                let result = await outcome(m, timeout: 15)
                if result != .connected {
                    DiagLog.warn("\(source): VPN не включился (статус \(result.rawValue))", to: .app)
                }
            } else {
                // Иначе «Держать VPN включённым» тут же включит VPN обратно.
                if m.isOnDemandEnabled {
                    m.isOnDemandEnabled = false
                    try await m.saveToPreferences()
                }
                m.connection.stopVPNTunnel()
                DiagLog.write("\(source) (\(process)): выключение VPN", to: .app)
                await wait(m, until: { $0 == .disconnected || $0 == .invalid }, timeout: 6)
            }
        } catch {
            DiagLog.warn("\(source) (\(process)): не удалось \(on ? "включить" : "выключить") VPN: \(error.localizedDescription)", to: .app)
            throw SwitchError(message: "Не удалось \(on ? "включить" : "выключить") VPN: \(error.localizedDescription)")
        }
    }

    /// Итог включения: подключён, или туннель начал подниматься и снова выключился (ошибка), или таймаут.
    private static func outcome(_ m: NETunnelProviderManager, timeout: Double) async -> NEVPNStatus {
        let start = Date()
        var moved = false
        while Date().timeIntervalSince(start) < timeout {
            let status = m.connection.status
            switch status {
            case .connected: return status
            case .connecting, .reasserting, .disconnecting: moved = true
            case .disconnected, .invalid:
                if moved || Date().timeIntervalSince(start) > 3 { return status }
            @unknown default: break
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return m.connection.status
    }

    /// Короткое ожидание, чтобы виджет сразу показал новое состояние.
    private static func wait(_ m: NETunnelProviderManager, until done: (NEVPNStatus) -> Bool, timeout: Double) async {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if done(m.connection.status) { return }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
    }
}
