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
    /// JSON AutoPool — запасные серверы для «Авто».
    static let pool = "pool"
}

/// Сигнал расширения приложению (Darwin-уведомление): отчёт изменился — сменился сервер,
/// появилось сообщение или итог проверки. Приложение сразу запрашивает свежий статус.
enum TunnelSignal {
    static let changed = "com.secretclub.tunnel.changed"

    static func post() {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(changed as CFString), nil, nil, true)
    }
}

/// Сервер-кандидат для «Авто»: готовый конфиг, чтобы расширение могло само
/// переключиться, если текущий сервер перестал работать (например, сменилась сеть).
struct AutoCandidate: Codable, Hashable {
    var id: String
    var title: String
    /// regular, bridge или reserve (RouteGroup.rawValue).
    var group: String
    var config: String
    var target: PingTarget?
    /// Нагрузка узла 0…1 по данным бэкенда (nil — неизвестно).
    var load: Double? = nil
}

struct AutoPool: Codable {
    /// false — выбран сервер вручную: только проверяем, не переключаем.
    var auto: Bool
    var candidates: [AutoCandidate]
    /// Когда приложение собрало список: расширение берёт самый свежий (из запуска, своего файла или профиля VPN).
    var updatedAt: Date? = nil

    func group(of id: String?) -> String? { candidates.first { $0.id == id }?.group }

    /// Порядок групп для режима сети: резерв — в последнюю очередь (у него ограничен трафик).
    static func order(for network: NetKind) -> [String] {
        network == .whitelist ? ["bridge", "reserve"] : ["regular", "bridge", "reserve"]
    }

    /// Все группы по приоритету: обычные → мосты → резерв.
    static let priority = ["regular", "bridge", "reserve"]
    static func rank(_ group: String) -> Int { priority.firstIndex(of: group) ?? priority.count }

    /// Порядок попыток: до двух лучших из каждой группы (обычные → мосты → резерв), всего до 4 —
    /// чтобы при «общей» беде группы (замирание, белый список) следующим шёл сервер другого типа.
    static func diverse(_ ranked: [AutoCandidate]) -> [AutoCandidate] {
        var counts: [String: Int] = [:]
        var out: [AutoCandidate] = []
        for c in ranked where out.count < 4 {
            let n = counts[c.group, default: 0]
            guard n < 2 else { continue }
            counts[c.group] = n + 1
            out.append(c)
        }
        return out
    }
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
    enum Kind: String, Codable { case status, reload, ping, pool, check, log }
    var kind: Kind
    var config: String? = nil
    var routeID: String? = nil
    var routeTitle: String? = nil
    var targets: [PingTarget]? = nil
    var pool: AutoPool? = nil
    /// Для check: network — сеть сменилась (можно вернуться на более быстрый сервер).
    var reason: String? = nil
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
    /// Режим сети глазами расширения (мимо туннеля): normal, whitelist, offline.
    var network: String? = nil
    /// Последняя проверка выхода в интернет через сервер: nil — ещё не проверяли.
    var healthy: Bool? = nil
    /// Задержка через сервер при последней проверке.
    var pingMS: Int? = nil
    var checking = false
    /// Сообщение для пользователя (например, «переключились на …»); noteID растёт с каждым новым.
    var note: String? = nil
    var noteID = 0
    /// Журнал последних решений расширения (для отчёта поддержке): «12:01:03 сеть wifi→cellular …».
    var events: [String]? = nil
    /// Сколько заняло последнее переключение/выбор сервера, мс.
    var lastSwitchMS: Int? = nil
    /// Ядро держит проверочные входы для всех запасных серверов (быстрая проверка без перезапуска).
    var multi: Bool? = nil
    /// Откуда счётчики трафика: core — из ядра, utun — по интерфейсу (запасной путь).
    var counters: String? = nil
    /// Ядро переключает сервер без перезапуска (все запасные уже внутри).
    var hot: Bool? = nil
    /// Ответ на команду log: конец журнала расширения (когда нет общей папки с приложением).
    var logTail: String? = nil
    /// Общая папка, которую видит расширение (nil — старое расширение, «нет» — не видит).
    var group: String? = nil
    /// Ответ на команду log: сбои, которые заметило само расширение.
    var incidents: [Incident]? = nil
}

enum TunnelCoding {
    static func encode<T: Encodable>(_ value: T) -> Data? { try? JSONEncoder().encode(value) }
    static func decode<T: Decodable>(_ type: T.Type, _ data: Data?) -> T? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
