import SwiftUI

enum Config {
    /// TODO: заменить на реальный username бота.
    static let botUsername = "secretclub_bot"
    static var botURL: URL { URL(string: "https://t.me/\(botUsername)")! }
    static var botLoginURL: URL { URL(string: "https://t.me/\(botUsername)?start=app")! }
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
}

enum TransportPreference: String, CaseIterable, Identifiable {
    case auto, reality, xhttp, hysteria2
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: return "Авто"
        case .reality: return "Reality"
        case .xhttp: return "XHTTP"
        case .hysteria2: return "Hysteria2"
        }
    }
}
