import Foundation

enum RouteGroup: String, CaseIterable, Identifiable, Codable {
    case regular, bridge, reserve
    var id: String { rawValue }

    var title: String {
        switch self {
        case .regular: return "Серверы"
        case .bridge: return "Мосты"
        case .reserve: return "Обход белых списков"
        }
    }
    var shortTitle: String {
        switch self {
        case .regular: return "Обычный"
        case .bridge: return "Мост"
        case .reserve: return "Обход БС"
        }
    }
    /// Пометка в капсуле после «Авто»: «Авто · мост», «Авто · обход БС».
    var tag: String {
        switch self {
        case .regular: return ""
        case .bridge: return "мост"
        case .reserve: return "обход БС"
        }
    }
    var subtitle: String {
        switch self {
        case .regular: return "Самые быстрые — для обычного интернета."
        case .bridge: return "Через промежуточный сервер в России — когда зарубежные серверы не открываются напрямую. При белых списках не помогают."
        case .reserve: return "Для мобильного интернета с белыми списками, когда открываются только разрешённые сайты. Включается само, если остальное не работает: трафик ограничен."
        }
    }
    /// Что пишем под кнопкой, пока «Авто» перебирает группу.
    var searchPhase: String {
        switch self {
        case .regular: return "Выбираем самый быстрый сервер"
        case .bridge: return "Пробуем мосты"
        case .reserve: return "Пробуем обход белых списков"
        }
    }
    var icon: String {
        switch self {
        case .regular: return "bolt.fill"
        case .bridge: return "arrow.triangle.branch"
        case .reserve: return "lifepreserver"
        }
    }
}

enum TransportKind: String, Codable {
    case reality, xhttp, hysteria2, cdn, other
}

struct Route: Identifiable, Hashable {
    let id: String
    let emoji: String
    let title: String
    var detail: String
    let group: RouteGroup
    let transport: TransportKind
    let transportTitle: String
    let remarks: String
    var isAutoBalancer: Bool = false
    var ping: Int? = nil
    var unavailable: Bool = false

    var flag: String { emoji }

    /// Качество связи 0…4 по последнему замеру: 0 — недоступен, nil — ещё не мерили.
    var quality: Int? {
        if unavailable { return 0 }
        return ping.map(Self.quality(ms:))
    }

    static func quality(ms: Int) -> Int {
        switch ms {
        case ..<250: return 4
        case ..<500: return 3
        case ..<900: return 2
        default: return 1
        }
    }

    /// Подпись без технических слов: «Быстрый · 5 Гбит/с», «мост», «обход белых списков».
    var humanDetail: String {
        var parts: [String] = []
        switch group {
        case .regular: parts.append(transport == .hysteria2 ? "Быстрый" : "Устойчивый")
        case .bridge: parts.append("мост")
        case .reserve: parts.append("обход белых списков")
        }
        if let r = detail.range(of: #"\d+ Гбит/с"#, options: .regularExpression) { parts.append(String(detail[r])) }
        return parts.joined(separator: " · ")
    }
    /// Подпись для карточки подключения: «Hysteria2», «через CDN» и т. п.
    var shortDetail: String {
        switch group {
        case .regular: return transportTitle
        case .bridge: return "мост · \(transportTitle)"
        case .reserve: return "обход БС"
        }
    }

    static func demo(_ id: String, _ code: String, _ country: String, _ group: RouteGroup, _ transport: TransportKind, _ ping: Int) -> Route {
        let tt: String
        switch transport {
        case .reality: tt = "Reality"
        case .xhttp: tt = "XHTTP"
        case .hysteria2: tt = "Hysteria2"
        case .cdn: tt = "XHTTP"
        case .other: tt = "TLS"
        }
        let detail: String
        switch group {
        case .regular: detail = "\(tt) · напрямую"
        case .bridge: detail = "через Россию · \(tt)"
        case .reserve: detail = "обход БС · через CDN"
        }
        return Route(id: id, emoji: code.flagEmoji, title: country, detail: detail, group: group,
                     transport: transport, transportTitle: tt, remarks: country, ping: ping)
    }
}

enum NetworkMode: String {
    case unknown, normal, whitelist, offline

    var title: String {
        switch self {
        case .unknown: return "Проверяем сеть…"
        case .normal: return "Обычный интернет"
        case .whitelist: return "Сеть ограничена"
        case .offline: return "Нет сети"
        }
    }
    var short: String {
        switch self {
        case .unknown: return "Проверка…"
        case .normal: return "Сеть в порядке"
        case .whitelist: return "Сеть ограничена"
        case .offline: return "Нет сети"
        }
    }
    var explanation: String {
        switch self {
        case .unknown: return "Определяем, какие сайты доступны в этой сети."
        case .normal: return "Открываются и российские, и зарубежные сайты. Используем самый быстрый маршрут."
        case .whitelist: return "Открываются только сайты из белого списка. Подключимся через обход белых списков."
        case .offline: return "Не отвечает ни один сайт. Проверьте Wi‑Fi или мобильный интернет."
        }
    }
    var icon: String {
        switch self {
        case .unknown: return "antenna.radiowaves.left.and.right"
        case .normal: return "checkmark.seal.fill"
        case .whitelist: return "exclamationmark.shield.fill"
        case .offline: return "wifi.slash"
        }
    }
}

enum Quality {
    static func word(_ q: Int?) -> String {
        guard let q else { return "—" }
        return ["Нет связи", "Слабая", "Средняя", "Хорошая", "Отличная"][max(0, min(4, q))]
    }
}

/// Статус узла от бэкенда (/api/app/nodes).
struct NodeStatus: Hashable {
    let online: Bool
    let load: Double?
}

struct ProbeResult: Identifiable, Hashable {
    let id: String
    let title: String
    let ms: Int?
    let isDomestic: Bool
}

struct DiagnosticStep: Identifiable, Hashable {
    let id = UUID()
    let ok: Bool
    let text: String
}

struct Device: Identifiable, Hashable {
    enum Kind: String { case phone, laptop, tablet, desktop, tv }
    let id: String
    let name: String
    let kind: Kind
    let lastSeen: Date?
    let isCurrent: Bool
    var detail: String? = nil

    var icon: String {
        switch kind {
        case .phone: return "iphone"
        case .laptop: return "laptopcomputer"
        case .tablet: return "ipad"
        case .desktop: return "desktopcomputer"
        case .tv: return "appletv"
        }
    }
}

enum SubscriptionStatus: String, Hashable {
    case active, expiring, expired, limited, disabled

    var title: String {
        switch self {
        case .active: return "Активна"
        case .expiring: return "Скоро закончится"
        case .expired: return "Закончилась"
        case .limited: return "Трафик закончился"
        case .disabled: return "Отключена"
        }
    }
    var isUsable: Bool { self == .active || self == .expiring }
}

struct SubscriptionInfo: Hashable {
    var plan: String
    var expiresAt: Date?
    var usedBytes: Int64
    var limitBytes: Int64?
    var devices: [Device]
    var deviceLimit: Int?
    var status: SubscriptionStatus = .active
    var lifetime = false
    /// Данные из аккаунта (а не только из заголовков подписки).
    var fromAccount = false

    static let empty = SubscriptionInfo(plan: "SecretClub", expiresAt: nil, usedBytes: 0, limitBytes: nil, devices: [], deviceLimit: nil)

    var isActive: Bool { status.isUsable && (expiresAt.map { $0 > Date() || lifetime } ?? true) }
    var daysLeft: Int? {
        guard !lifetime else { return nil }
        return expiresAt.map { max(0, Int(ceil($0.timeIntervalSinceNow / 86400))) }
    }
    var progress: Double {
        guard let d = daysLeft else { return 1 }
        return min(1, Double(d) / 30)
    }
    var remainingText: String {
        guard let d = daysLeft else { return "бессрочно" }
        return "ещё \(d) \(Format.plural(d, "день", "дня", "дней"))"
    }
    var leftBytes: Int64? { limitBytes.map { max(0, $0 - usedBytes) } }
    var trafficProgress: Double? { limitBytes.map { min(1, Double(usedBytes) / Double(max(1, $0))) } }
}

struct SubscriptionMeta: Codable, Hashable {
    var title: String?
    var announce: String?
    var supportURL: String?
    var upload: Int64 = 0
    var download: Int64 = 0
    var total: Int64 = 0
    var expire: Date?
    var updatedAt = Date()
}

extension String {
    var flagEmoji: String {
        var s = ""
        for v in uppercased().unicodeScalars {
            if let u = UnicodeScalar(127397 + v.value) { s.unicodeScalars.append(u) }
        }
        return s
    }
}

extension SubscriptionInfo {
    init(meta: SubscriptionMeta) {
        self.init(plan: meta.title ?? "SecretClub",
                  expiresAt: meta.expire,
                  usedBytes: meta.upload + meta.download,
                  limitBytes: meta.total > 0 ? meta.total : nil,
                  devices: [Device(id: DeviceInfo.hwid, name: DeviceInfo.displayName, kind: .phone, lastSeen: Date(), isCurrent: true)],
                  deviceLimit: nil)
        lifetime = (meta.expire?.timeIntervalSinceNow ?? 0) > 50 * 365 * 86400
        if let expire = meta.expire, expire <= Date(), !lifetime {
            status = .expired
        } else if let limit = limitBytes, usedBytes >= limit {
            status = .limited
        } else if let d = daysLeft, d <= 3 {
            status = .expiring
        }
    }

    init(account s: AccountSubscription) {
        self.init(plan: s.kind == "trial" ? "Пробный период" : "SecretClub",
                  expiresAt: s.lifetime ? nil : s.expireAt,
                  usedBytes: s.usedBytes,
                  limitBytes: s.totalBytes,
                  devices: s.devices.map(\.device),
                  deviceLimit: s.deviceLimit)
        status = s.status
        lifetime = s.lifetime
        fromAccount = true
    }
}
