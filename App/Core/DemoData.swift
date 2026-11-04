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
        r("auto", "🌍", "Авто-выбор", .bridge, .xhttp, "XHTTP", "через Россию · XHTTP", 64),
        r("fi-x", "🇫🇮", "Финляндия", .bridge, .xhttp, "XHTTP", "через Россию · XHTTP · 5 Гбит/с", 69),
        r("fi-tcp", "🇫🇮", "Финляндия", .bridge, .reality, "Reality", "через Россию · Reality · 5 Гбит/с", 71),
        r("pl-x", "🇵🇱", "Польша", .bridge, .xhttp, "XHTTP", "через Россию · XHTTP · 1 Гбит/с", 77),
        r("fi-cdn", "🇫🇮", "Финляндия", .bypass, .cdn, "XHTTP", "через CDN · TF-2", 96),
        r("se-cdn", "🇸🇪", "Швеция", .bypass, .cdn, "XHTTP", "через CDN · TF-2", 104),
        r("de-cdn", "🇩🇪", "Германия", .bypass, .cdn, "XHTTP", "через CDN · TF-2", 118),
        r("ru-cdn", "🇷🇺", "Россия", .bypass, .cdn, "XHTTP", "через CDN · 6", 31),
    ]

    static var subscription: SubscriptionInfo {
        let now = Date()
        return SubscriptionInfo(
            plan: "Premium",
            expiresAt: now.addingTimeInterval(23 * 86400 + 3600),
            usedBytes: 19_756_000_000,
            limitBytes: nil,
            devices: [
                Device(id: "1", name: "iPhone · iOS 26.1", kind: .phone, lastSeen: now, isCurrent: true),
                Device(id: "2", name: "MacBook Air", kind: .laptop, lastSeen: now.addingTimeInterval(-3 * 3600), isCurrent: false),
                Device(id: "3", name: "iPad", kind: .tablet, lastSeen: now.addingTimeInterval(-2 * 86400), isCurrent: false),
            ],
            deviceLimit: 5
        )
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
