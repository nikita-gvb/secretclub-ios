import Foundation

enum RouteGroup: String, CaseIterable, Identifiable, Codable {
    case regular, bridge, bypass
    var id: String { rawValue }

    var title: String {
        switch self {
        case .regular: return "Обычные"
        case .bridge: return "Мост через РФ"
        case .bypass: return "Обход белых списков"
        }
    }
    var shortTitle: String {
        switch self {
        case .regular: return "Прямое"
        case .bridge: return "Мост РФ"
        case .bypass: return "Обход БС"
        }
    }
    var subtitle: String {
        switch self {
        case .regular: return "Прямое подключение — максимальная скорость"
        case .bridge: return "Через сервер в России, если зарубежные адреса режут"
        case .bypass: return "Через CDN — работает, когда включены белые списки"
        }
    }
    var icon: String {
        switch self {
        case .regular: return "bolt.fill"
        case .bridge: return "arrow.triangle.branch"
        case .bypass: return "shield.lefthalf.filled"
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
    /// Подпись для карточки подключения: «Hysteria2», «через CDN» и т. п.
    var shortDetail: String {
        switch group {
        case .regular: return transportTitle
        case .bridge: return "мост · \(transportTitle)"
        case .bypass: return "через CDN"
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
        case .bypass: detail = "через CDN · белые списки"
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
        case .whitelist: return "Белые списки"
        case .offline: return "Нет сети"
        }
    }
    var short: String {
        switch self {
        case .unknown: return "Проверка…"
        case .normal: return "Сеть в порядке"
        case .whitelist: return "Белые списки"
        case .offline: return "Нет сети"
        }
    }
    var explanation: String {
        switch self {
        case .unknown: return "Определяем, какие сайты доступны в этой сети."
        case .normal: return "Открываются и российские, и зарубежные сайты. Используем самый быстрый маршрут."
        case .whitelist: return "Доступны только сайты из белого списка. Подключаемся через CDN."
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
    enum Kind: String { case phone, laptop, tablet, desktop }
    let id: String
    let name: String
    let kind: Kind
    let lastSeen: Date
    let isCurrent: Bool

    var icon: String {
        switch kind {
        case .phone: return "iphone"
        case .laptop: return "laptopcomputer"
        case .tablet: return "ipad"
        case .desktop: return "desktopcomputer"
        }
    }
}

struct SubscriptionInfo: Hashable {
    var plan: String
    var expiresAt: Date?
    var usedBytes: Int64
    var limitBytes: Int64?
    var devices: [Device]
    var deviceLimit: Int?

    static let empty = SubscriptionInfo(plan: "SecretClub", expiresAt: nil, usedBytes: 0, limitBytes: nil, devices: [], deviceLimit: nil)

    var isActive: Bool { expiresAt.map { $0 > Date() } ?? true }
    var daysLeft: Int? {
        expiresAt.map { max(0, Calendar.current.dateComponents([.day], from: Date(), to: $0).day ?? 0) }
    }
    var progress: Double {
        guard let d = daysLeft else { return 1 }
        return min(1, Double(d) / 30)
    }
    var remainingText: String {
        guard let d = daysLeft else { return "бессрочно" }
        return "ещё \(d) \(Format.plural(d, "день", "дня", "дней"))"
    }
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
                  devices: [Device(id: "this", name: DeviceInfo.displayName, kind: .phone, lastSeen: Date(), isCurrent: true)],
                  deviceLimit: nil)
    }
}
