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

    static func kind(timeout: Double = 4) async -> NetKind {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout + 1
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.waitsForConnectivity = false
        let session = URLSession(configuration: cfg)
        defer { session.invalidateAndCancel() }
        return await withTaskGroup(of: (Bool, Bool).self) { group -> NetKind in
            for (list, isForeign) in [(domestic, false), (foreign, true)] {
                for url in list {
                    group.addTask {
                        var req = URLRequest(url: URL(string: url)!)
                        req.httpMethod = "HEAD"
                        let ok = (try? await session.data(for: req)) != nil
                        return (isForeign, ok)
                    }
                }
            }
            var domesticOK = false
            for await (isForeign, ok) in group where ok {
                if isForeign {
                    group.cancelAll()
                    return .normal
                }
                domesticOK = true
            }
            return domesticOK ? .whitelist : .offline
        }
    }

    /// Какой физический интерфейс сейчас основной: «wifi:en0», «cellular:pdp_ip0»;
    /// «none» — сети нет, «other» — виден только туннель.
    static func signature(_ path: NWPath) -> String {
        guard path.status == .satisfied else { return "none" }
        if let i = path.availableInterfaces.first(where: { $0.type != .other && $0.type != .loopback }) {
            return "\(i.type):\(i.name)"
        }
        return "other"
    }
}
