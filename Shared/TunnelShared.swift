import Foundation

/// Ключи, через которые приложение передаёт настройки в расширение
/// (providerConfiguration и options у startVPNTunnel).
enum TunnelOption {
    /// Готовый JSON-конфиг Xray (без tun-дескриптора — его подставляет расширение).
    static let config = "config"
    static let routeID = "routeID"
    static let routeTitle = "routeTitle"
    /// Пробный туннель без ядра — для диагностики подписи.
    static let probe = "probe"
}

/// Сервер для замера задержки из расширения (мимо туннеля).
struct PingTarget: Codable, Hashable {
    var id: String
    var host: String
    var port: Int
    /// Hysteria2 и прочие QUIC-серверы: меряем QUIC-рукопожатие вместо TCP.
    var udp = false
    var sni: String? = nil
}

struct TunnelCommand: Codable {
    enum Kind: String, Codable { case status, reload, ping }
    var kind: Kind
    var config: String? = nil
    var routeID: String? = nil
    var routeTitle: String? = nil
    var targets: [PingTarget]? = nil
}

struct TunnelReport: Codable, Equatable {
    var probe = false
    var running = false
    var coreVersion = ""
    var routeID: String?
    var routeTitle: String?
    var startedAt: Date?
    var uplink: Int64 = 0
    var downlink: Int64 = 0
    var memoryMB: Double?
    var error: String?
    /// Ответ на команду ping: id сервера → мс.
    var pings: [String: Int]? = nil
}

enum TunnelCoding {
    static func encode<T: Encodable>(_ value: T) -> Data? { try? JSONEncoder().encode(value) }
    static func decode<T: Decodable>(_ type: T.Type, _ data: Data?) -> T? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
