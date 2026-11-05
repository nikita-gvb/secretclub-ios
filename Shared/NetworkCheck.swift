import Foundation
import Network

/// Режим сети: зарубежные сайты открываются (normal), только белый список (whitelist) или ничего.
enum NetKind: String, Codable {
    case normal, whitelist, offline
}

/// Быстрая проверка сети для расширения (его запросы идут мимо туннеля).
enum NetworkCheck {
    private static let domestic = ["https://ya.ru/", "https://vk.com/"]
    private static let foreign = ["https://www.google.com/generate_204", "https://cp.cloudflare.com/generate_204"]

    private enum Event { case domestic(Bool), foreign(Bool), tick }

    /// Не ждёт таймаутов без нужды: ответил зарубежный сайт — «обычный интернет» сразу;
    /// ответил российский, а зарубежные молчат дольше, чем «должны» при такой задержке, — белый список.
    /// Зарубежный ответ засчитывается, только если это именно 204 (заглушка провайдера — не интернет).
    static func kind(timeout: Double = 4) async -> NetKind {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout + 1
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.waitsForConnectivity = false
        cfg.httpMaximumConnectionsPerHost = 2
        let session = URLSession(configuration: cfg)
        defer { session.invalidateAndCancel() }
        let start = DispatchTime.now()
        return await withTaskGroup(of: Event.self) { group -> NetKind in
            for url in domestic {
                group.addTask {
                    var req = URLRequest(url: URL(string: url)!)
                    req.httpMethod = "HEAD"
                    let code = ((try? await session.data(for: req))?.1 as? HTTPURLResponse)?.statusCode ?? 0
                    return .domestic(code > 0 && code < 500)
                }
            }
            for url in foreign {
                group.addTask {
                    let req = URLRequest(url: URL(string: url)!)
                    let code = ((try? await session.data(for: req))?.1 as? HTTPURLResponse)?.statusCode ?? 0
                    return .foreign(code == 204)
                }
            }
            group.addTask { try? await Task.sleep(nanoseconds: 100_000_000); return .tick }
            var pending = domestic.count + foreign.count
            var foreignPending = foreign.count
            var domesticOK = false
            var deadline: Double?
            while let event = await group.next() {
                let now = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
                switch event {
                case .foreign(let ok):
                    pending -= 1
                    foreignPending -= 1
                    if ok {
                        group.cancelAll()
                        return .normal
                    }
                case .domestic(let ok):
                    pending -= 1
                    if ok && !domesticOK {
                        domesticOK = true
                        // Зарубежный сайт при живом интернете отвечает не сильно позже российского.
                        deadline = now + max(0.9, now * 1.5)
                    }
                case .tick:
                    if pending > 0 { group.addTask { try? await Task.sleep(nanoseconds: 100_000_000); return .tick } }
                }
                if domesticOK, foreignPending == 0 || (deadline.map { now >= $0 } ?? false) {
                    group.cancelAll()
                    return .whitelist
                }
                if pending == 0 {
                    group.cancelAll()
                    return domesticOK ? .whitelist : .offline
                }
            }
            return domesticOK ? .whitelist : .offline
        }
    }

    /// Какой физический интерфейс сейчас основной: «wifi:en0», «cellular:pdp_ip0»;
    /// «none» — сети нет, «other» — виден только туннель.
    static func signature(_ path: NWPath) -> String {
        guard path.status == .satisfied else { return "none" }
        if let i = physical(path) { return "\(i.type):\(i.name)" }
        return "other"
    }

    static func physical(_ path: NWPath) -> NWInterface? {
        path.availableInterfaces.first { $0.type != .other && $0.type != .loopback }
    }

    /// Отпечаток сети: интерфейс и свой адрес. Сменился адрес на том же Wi‑Fi-интерфейсе
    /// (другая точка доступа) — это тоже новая сеть: старые соединения ядра к серверу мертвы.
    static func fingerprint(_ path: NWPath) -> String? {
        guard path.status == .satisfied, let i = physical(path) else { return nil }
        var parts = ["\(i.type)", i.name]
        if let address = localAddress(i.name) { parts.append(address) }
        return parts.joined(separator: "|")
    }

    /// Ключ для памяти «что работало в этой сети»: Wi‑Fi различаем по шлюзу, мобильная сеть — одна.
    static func memoryKey(_ path: NWPath) -> String? {
        guard path.status == .satisfied, let i = physical(path) else { return nil }
        switch i.type {
        case .wifi, .wiredEthernet:
            let gw = gateways(path)
            return "\(i.type)|" + (gw.isEmpty ? (localAddress(i.name).map(subnet) ?? "?") : gw.joined(separator: ","))
        default:
            return "\(i.type)"
        }
    }

    private static func gateways(_ path: NWPath) -> [String] {
        path.gateways.compactMap { endpoint -> String? in
            guard case let .hostPort(host, _) = endpoint else { return nil }
            let text = "\(host)"
            return text.hasPrefix("198.18.") || text.hasPrefix("fd66:5c00") ? nil : text
        }.sorted()
    }

    private static func subnet(_ address: String) -> String {
        address.split(separator: ".").prefix(3).joined(separator: ".")
    }

    /// IPv4-адрес интерфейса (en0, pdp_ip0…).
    static func localAddress(_ name: String) -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let item = cursor {
            let ifa = item.pointee
            cursor = ifa.ifa_next
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  String(cString: ifa.ifa_name) == name else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            return host.withUnsafeBufferPointer { ptr in ptr.baseAddress.map { String(cString: $0) } }
        }
        return nil
    }
}
