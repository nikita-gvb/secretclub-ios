import Foundation
import NetworkExtension
import os

/// Туннель SecretClub: поднимает utun и запускает ядро Xray с TUN-входом прямо на его дескрипторе.
/// Собственный трафик расширения (подключения к серверам) идёт мимо туннеля — так устроен iOS.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let log = Logger(subsystem: "com.secretclub.app.tunnel", category: "provider")
    /// Все обращения к ядру и к report — только на этой очереди.
    private let work = DispatchQueue(label: "com.secretclub.tunnel.work", qos: .userInitiated)
    private var report = TunnelReport()
    private var metricsPort = 0

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
                    try self.startCore(config)
                    self.report.routeID = routeID
                    self.report.routeTitle = routeTitle
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
            refreshStats {
                completionHandler?(TunnelCoding.encode(self.report))
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
                } catch {
                    self.report.error = error.localizedDescription
                }
                self.reasserting = false
                completionHandler?(TunnelCoding.encode(self.report))
            }
        }
    }

    // MARK: - Ядро

    /// Вызывать на очереди work, после setTunnelNetworkSettings.
    private func startCore(_ config: String) throws {
        if report.coreVersion.isEmpty { report.coreVersion = XrayEngine.version }
        guard let fd = Self.tunnelFileDescriptor() else {
            throw Self.error("не найден дескриптор utun")
        }
        if metricsPort == 0 { metricsPort = XrayEngine.freePort() ?? 49227 }
        let prepared = try Self.prepare(config, fd: fd, metricsPort: metricsPort)
        try XrayEngine.runSync(prepared)
        report.running = true
        report.startedAt = Date()
        report.error = nil
        report.uplink = 0
        report.downlink = 0
        log.info("xray started, fd \(fd), metrics \(self.metricsPort)")
    }

    /// Подставляет в конфиг дескриптор туннеля, путь к geo-файлам и счётчики трафика.
    static func prepare(_ text: String, fd: Int32, metricsPort: Int) throws -> String {
        guard var root = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else {
            throw error("некорректная конфигурация")
        }
        var env = root["env"] as? [String: Any] ?? [:]
        env["xray.tun.fd"] = String(fd)
        if let resources = Bundle.main.resourcePath { env["xray.location.asset"] = resources }
        root["env"] = env

        root["stats"] = [String: Any]()
        root["metrics"] = ["listen": "127.0.0.1:\(metricsPort)"]
        var policy = root["policy"] as? [String: Any] ?? [:]
        var system = policy["system"] as? [String: Any] ?? [:]
        system["statsInboundUplink"] = true
        system["statsInboundDownlink"] = true
        policy["system"] = system
        root["policy"] = policy

        let data = try JSONSerialization.data(withJSONObject: root)
        return String(decoding: data, as: UTF8.self)
    }

    /// Счётчики трафика из встроенного metrics-сервера Xray (/debug/vars).
    private func refreshStats(_ done: @escaping () -> Void) {
        work.async {
            guard self.report.running, self.metricsPort > 0,
                  let url = URL(string: "http://127.0.0.1:\(self.metricsPort)/debug/vars") else {
                self.report.memoryMB = Self.footprintMB
                done()
                return
            }
            let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 2)
            URLSession.shared.dataTask(with: request) { data, _, _ in
                self.work.async {
                    if let data,
                       let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                       let stats = root["stats"] as? [String: Any],
                       let inbound = stats["inbound"] as? [String: Any],
                       let tun = inbound["tun"] as? [String: Any] {
                        self.report.uplink = (tun["uplink"] as? NSNumber)?.int64Value ?? self.report.uplink
                        self.report.downlink = (tun["downlink"] as? NSNumber)?.int64Value ?? self.report.downlink
                    }
                    self.report.memoryMB = Self.footprintMB
                    done()
                }
            }.resume()
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
    static func tunnelFileDescriptor() -> Int32? {
        var buf = [CChar](repeating: 0, count: Int(IFNAMSIZ))
        for fd: Int32 in 0...1024 {
            var len = socklen_t(buf.count)
            // 2 = SYSPROTO_CONTROL, 2 = UTUN_OPT_IFNAME
            guard getsockopt(fd, 2, 2, &buf, &len) == 0 else { continue }
            let name = buf.withUnsafeBufferPointer { ptr -> String in
                guard let base = ptr.baseAddress else { return "" }
                return String(cString: base)
            }
            if name.hasPrefix("utun") { return fd }
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
