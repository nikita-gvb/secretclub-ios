import SwiftUI
import UIKit

enum Config {
    /// Бот SecretClub. Бэкенд может прислать другой username — тогда берём его.
    static var botUsername: String {
        let saved = UserDefaults.standard.string(forKey: "botUsername") ?? ""
        return saved.isEmpty ? "secvmbot" : saved
    }
    static var botURL: URL { URL(string: "https://t.me/\(botUsername)")! }
    /// Открыть нужный экран бота: buy, traffic, devices, extra…
    static func botLink(start: String) -> URL { URL(string: "https://t.me/\(botUsername)?start=\(start)")! }
    /// Бэкенд аккаунта (мини-апп). Для отладки можно переопределить ключом apiBase.
    static var apiBase: String {
        let saved = UserDefaults.standard.string(forKey: "apiBase") ?? ""
        return saved.isEmpty ? "https://lk.scvpn.app" : saved
    }
    /// Поддержка: из заголовка support-url подписки, иначе — через бота.
    static var supportURL: URL {
        if let s = UserDefaults.standard.string(forKey: "supportURL"), let url = URL(string: s) { return url }
        return URL(string: "https://t.me/aioap")!
    }

    static var shortVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    static var version: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }
}

enum SettingsKey {
    static let autoConnect = "autoConnect"
    static let killSwitch = "killSwitch"
    static let ruDirect = "ruDirect"
    static let energySaver = "energySaver"
    static let transport = "preferredTransport"
    static let vpnDomains = "vpnDomains"
    static let directDomains = "directDomains"
    static let autoMode = "autoMode"
    static let selectedRoute = "selectedRoute"
    static let connectedRoute = "connectedRoute"
    static let appearance = "appearance"
}

/// Оформление: как в системе (по умолчанию), светлое или тёмное.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "Как в системе"
        case .light: return "Светлое"
        case .dark: return "Тёмное"
        }
    }
    var style: UIUserInterfaceStyle {
        switch self {
        case .system: return .unspecified
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// «Способ подключения» без технических слов. Raw-значения совместимы с 0.5 (hysteria2/reality).
enum TransportPreference: String, CaseIterable, Identifiable {
    case auto
    case fast = "hysteria2"
    case stable = "reality"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: return "Авто"
        case .fast: return "Быстрый"
        case .stable: return "Устойчивый"
        }
    }
    var subtitle: String {
        switch self {
        case .auto: return "Подберём сами — рекомендуем"
        case .fast: return "Для видео и игр"
        case .stable: return "Если связь часто обрывается"
        }
    }
}
