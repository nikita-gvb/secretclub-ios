import Foundation

enum DemoData {
    static let routes: [Route] = [
        Route(id: "fi-reality", country: "Финляндия", countryCode: "FI", group: .regular, transport: .reality, ping: 38),
        Route(id: "se-reality", country: "Швеция", countryCode: "SE", group: .regular, transport: .reality, ping: 46),
        Route(id: "pl-xhttp", country: "Польша", countryCode: "PL", group: .regular, transport: .xhttp, ping: 54),
        Route(id: "de-reality", country: "Германия", countryCode: "DE", group: .regular, transport: .reality, ping: 61),
        Route(id: "fi-hy2", country: "Финляндия", countryCode: "FI", group: .regular, transport: .hysteria2, ping: 41),
        Route(id: "fi-bridge", country: "Финляндия", countryCode: "FI", group: .bridge, transport: .xhttp, ping: 72),
        Route(id: "se-bridge", country: "Швеция", countryCode: "SE", group: .bridge, transport: .xhttp, ping: 79),
        Route(id: "fi-cdn", country: "Финляндия", countryCode: "FI", group: .bypass, transport: .cdn, ping: 96),
        Route(id: "se-cdn", country: "Швеция", countryCode: "SE", group: .bypass, transport: .cdn, ping: 104),
        Route(id: "pl-cdn", country: "Польша", countryCode: "PL", group: .bypass, transport: .cdn, ping: 118),
        Route(id: "de-cdn", country: "Германия", countryCode: "DE", group: .bypass, transport: .cdn, ping: 125),
        Route(id: "ru-cdn", country: "Россия", countryCode: "RU", group: .bypass, transport: .cdn, ping: 31),
    ]

    static var subscription: SubscriptionInfo {
        let now = Date()
        return SubscriptionInfo(
            plan: "Premium",
            startedAt: now.addingTimeInterval(-7 * 86400),
            expiresAt: now.addingTimeInterval(23 * 86400 + 3600),
            usedBytes: 19_756_000_000,
            limitBytes: nil,
            devices: [
                Device(id: "1", name: "iPhone", kind: .phone, lastSeen: now, isCurrent: true),
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
        DiagnosticStep(ok: true, text: "VPN-профиль создан"),
        DiagnosticStep(ok: true, text: "Пробный туннель запущен"),
        DiagnosticStep(ok: true, text: "Расширение отвечает"),
    ]
}
