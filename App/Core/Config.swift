import SwiftUI

enum Config {
    /// TODO: заменить на реальный username бота.
    static let botUsername = "secretclub_bot"
    static var botURL: URL { URL(string: "https://t.me/\(botUsername)")! }
    static var botLoginURL: URL { URL(string: "https://t.me/\(botUsername)?start=app")! }
    static var supportURL: URL { URL(string: "https://t.me/\(botUsername)?start=support")! }

    static var version: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }
}

enum SettingsKey {
    static let theme = "theme"
    static let autoConnect = "autoConnect"
    static let killSwitch = "killSwitch"
    static let ruDirect = "ruDirect"
    static let energySaver = "energySaver"
    static let transport = "preferredTransport"
    static let vpnDomains = "vpnDomains"
    static let directDomains = "directDomains"
}

enum AppTheme: String, CaseIterable, Identifiable {
    case system, dark, light
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "Как в системе"
        case .dark: return "Тёмная"
        case .light: return "Светлая"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .dark: return .dark
        case .light: return .light
        }
    }
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
