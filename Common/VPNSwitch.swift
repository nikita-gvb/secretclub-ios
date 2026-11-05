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

    /// Включить или выключить. source — откуда (для журнала диагностики).
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
            DiagLog.warn("\(source): профиль VPN не прочитан: \(error.localizedDescription)", to: .app)
            throw SwitchError(message: "Не удалось прочитать настройки VPN: \(error.localizedDescription)")
        }
        let autoConnect = AppGroup.defaults?.bool(forKey: SharedKey.autoConnect) ?? false
        do {
            if on {
                // Выключали отсюда же — возвращаем «Подключаться само», если оно включено в приложении.
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
                DiagLog.write("\(source): включение VPN", to: .app)
                await wait(m, until: { $0 != .disconnected && $0 != .invalid }, timeout: 2)
            } else {
                // Иначе «Подключаться само» тут же включит VPN обратно.
                if m.isOnDemandEnabled {
                    m.isOnDemandEnabled = false
                    try await m.saveToPreferences()
                }
                m.connection.stopVPNTunnel()
                DiagLog.write("\(source): выключение VPN", to: .app)
                await wait(m, until: { $0 == .disconnected || $0 == .invalid }, timeout: 2)
            }
        } catch {
            DiagLog.warn("\(source): не удалось \(on ? "включить" : "выключить") VPN: \(error.localizedDescription)", to: .app)
            throw SwitchError(message: "Не удалось \(on ? "включить" : "выключить") VPN: \(error.localizedDescription)")
        }
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
