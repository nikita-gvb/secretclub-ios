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
    case reality, xhttp, hysteria2, cdn
    var title: String {
        switch self {
        case .reality: return "Reality"
        case .xhttp: return "XHTTP"
        case .hysteria2: return "Hysteria2"
        case .cdn: return "CDN"
        }
    }
}

struct Route: Identifiable, Hashable, Codable {
    let id: String
    let country: String
    let countryCode: String
    let group: RouteGroup
    let transport: TransportKind
    var ping: Int?

    var flag: String { countryCode.flagEmoji }

    var detail: String {
        switch group {
        case .regular: return "\(transport.title) · напрямую"
        case .bridge: return "через Россию · \(transport.title)"
        case .bypass: return "через CDN · белые списки"
        }
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
    var startedAt: Date
    var expiresAt: Date
    var usedBytes: Int64
    var limitBytes: Int64?
    var devices: [Device]
    var deviceLimit: Int

    var isActive: Bool { expiresAt > Date() }
    var daysLeft: Int { max(0, Calendar.current.dateComponents([.day], from: Date(), to: expiresAt).day ?? 0) }
    var progress: Double {
        let total = expiresAt.timeIntervalSince(startedAt)
        guard total > 0 else { return 0 }
        return min(1, max(0, expiresAt.timeIntervalSinceNow / total))
    }
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
