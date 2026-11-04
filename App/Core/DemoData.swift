import Foundation

/// Данные для демо-режима (-demo YES) — скриншоты в CI и показ без подписки.
enum DemoData {
    private static func r(_ id: String, _ emoji: String, _ title: String, _ group: RouteGroup, _ transport: TransportKind,
                          _ tt: String, _ detail: String, _ ping: Int?) -> Route {
        Route(id: id, emoji: emoji, title: title, detail: detail, group: group, transport: transport,
              transportTitle: tt, remarks: title, ping: ping, unavailable: ping == nil)
    }

    static let routes: [Route] = [
        r("fi-hy", "🇫🇮", "Финляндия", .regular, .hysteria2, "Hysteria2", "Hysteria2 · 5 Гбит/с", 38),
        r("se-hy", "🇸🇪", "Швеция", .regular, .hysteria2, "Hysteria2", "Hysteria2 · 100 Гбит/с", 46),
        r("pl-hy", "🇵🇱", "Польша", .regular, .hysteria2, "Hysteria2", "Hysteria2 · 1 Гбит/с", 54),
        r("de-hy", "🇩🇪", "Германия 2", .regular, .hysteria2, "Hysteria2", "Hysteria2 · 1 Гбит/с", 61),
        r("ua", "🇺🇦", "Украина", .regular, .reality, "Reality", "Reality", nil),
        r("fi-x", "🇫🇮", "Финляндия", .bridge, .xhttp, "XHTTP", "через Россию · XHTTP · 5 Гбит/с", 69),
        r("fi-tcp", "🇫🇮", "Финляндия", .bridge, .reality, "Reality", "через Россию · Reality · 5 Гбит/с", 71),
        r("pl-x", "🇵🇱", "Польша", .bridge, .xhttp, "XHTTP", "через Россию · XHTTP · 1 Гбит/с", 77),
        r("r|fi-cdn", "🇫🇮", "Финляндия", .reserve, .cdn, "XHTTP", "через CDN · TF-2", 96),
        r("se-cdn", "🇸🇪", "Швеция", .reserve, .cdn, "XHTTP", "через CDN · TF-2", 104),
        r("de-cdn", "🇩🇪", "Германия", .reserve, .cdn, "XHTTP", "через CDN · TF-2", 118),
        r("ru-cdn", "🇷🇺", "Россия", .reserve, .cdn, "XHTTP", "через CDN · 6", 31),
    ]

    private static func ms(_ offset: TimeInterval) -> Int64 { Int64(Date().addingTimeInterval(offset).timeIntervalSince1970 * 1000) }
    private static func iso(_ offset: TimeInterval) -> String {
        ISO8601DateFormatter().string(from: Date().addingTimeInterval(offset))
    }

    static var accountJSON: [String: Any] {
        [
            "user": ["telegramId": "100200300", "username": "secretclub_demo", "firstName": "Никита"],
            "consent": ["accepted": true, "version": "2026-01", "terms": "https://lk.scvpn.app/terms.html", "privacy": "https://lk.scvpn.app/privacy.html"] as [String: Any],
            "links": ["botUsername": "secvmbot", "support": "https://t.me/aioap"],
            "hasSubscription": true,
            "subscription": [
                "url": "https://sub.scvpn.app/demo", "kind": "paid", "status": "active", "daysLeft": 24,
                "lifetime": false, "expireAt": ms(23 * 86400 + 3600), "usedBytes": 19_756_000_000,
                "deviceCount": 3, "deviceLimit": 5,
                "devices": [
                    ["hwid": DeviceInfo.hwid, "platform": "iOS", "osVersion": "26.1", "deviceModel": "iPhone17,1", "updatedAt": iso(0)],
                    ["hwid": "mac-1", "platform": "macOS", "osVersion": "15.5", "deviceModel": "MacBook Air", "updatedAt": iso(-3 * 3600)],
                    ["hwid": "ipad-1", "platform": "iPadOS", "osVersion": "18.4", "deviceModel": "iPad14,1", "updatedAt": iso(-2 * 86400)],
                ],
            ] as [String: Any],
            "extra": [
                "url": "https://sub.scvpn.app/demo-reserve", "kind": "paid", "status": "active", "lifetime": true,
                "usedBytes": 61_000_000, "totalBytes": 209_715_200, "deviceCount": 1, "deviceLimit": 5, "devices": [[String: Any]](),
            ] as [String: Any],
            "trial": ["available": false, "days": 7] as [String: Any],
            "freeExtraMb": 200,
        ]
    }

    static var account: AccountMe { AccountMe(json: accountJSON) }

    static var subscription: SubscriptionInfo {
        account.subscription.map(SubscriptionInfo.init(account:)) ?? .empty
    }

    static var reserve: SubscriptionInfo? {
        account.reserve.map(SubscriptionInfo.init(account:))
    }

    static var loginTicket: LoginTicket {
        LoginTicket(code: "demo", verifier: "demo", botURL: URL(string: "https://t.me/secvmbot?start=app_demo")!,
                    tgURL: nil, expiresAt: Date().addingTimeInterval(300))
    }

    static let probes: [ProbeResult] = [
        ProbeResult(id: "ya.ru", title: "ya.ru", ms: 24, isDomestic: true),
        ProbeResult(id: "vk.com", title: "vk.com", ms: 31, isDomestic: true),
        ProbeResult(id: "google.com", title: "google.com", ms: 118, isDomestic: false),
        ProbeResult(id: "cloudflare.com", title: "cloudflare.com", ms: 92, isDomestic: false),
    ]

    static let permissionSteps: [DiagnosticStep] = [
        DiagnosticStep(ok: true, text: "VPN подключён"),
        DiagnosticStep(ok: true, text: "Ядро Xray 26.10.31 работает"),
        DiagnosticStep(ok: true, text: "Память расширения: 21 МБ из 50"),
        DiagnosticStep(ok: true, text: "Интернет через VPN: IP 95.217.10.24, 🇫🇮 Финляндия, 142 мс"),
    ]
}
