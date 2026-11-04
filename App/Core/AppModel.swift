import SwiftUI
import Observation

enum AppTab: String, Hashable {
    case home, locations, subscription, settings
}

@MainActor
@Observable
final class AppModel {
    var isLoggedIn: Bool
    var selectedTab: AppTab = .home
    var routes: [Route]
    var autoMode = true
    var selectedRouteID: String?
    var autoRouteID: String?
    var networkMode: NetworkMode = .unknown
    var probes: [ProbeResult] = []
    var subscription: SubscriptionInfo

    let vpn = VPNController()
    let isDemo: Bool
    let initialScreen: String?

    init() {
        let defaults = UserDefaults.standard
        isDemo = defaults.bool(forKey: "demo")
        initialScreen = defaults.string(forKey: "screen")
        routes = DemoData.routes
        subscription = DemoData.subscription
        autoRouteID = DemoData.routes.first?.id

        if isDemo {
            isLoggedIn = initialScreen != "onboarding"
            networkMode = .normal
            probes = DemoData.probes
            vpn.enableDemo(connected: initialScreen != "disconnected")
        } else {
            isLoggedIn = Keychain.read(Keychain.subscriptionKey) != nil
        }

        switch initialScreen {
        case "locations": selectedTab = .locations
        case "subscription": selectedTab = .subscription
        case "settings", "diagnostics", "exceptions": selectedTab = .settings
        default: selectedTab = .home
        }
    }

    var activeRoute: Route? {
        let id = autoMode ? autoRouteID : selectedRouteID
        return routes.first { $0.id == id } ?? routes.first
    }

    func selectAuto() { autoMode = true }

    func select(_ route: Route) {
        autoMode = false
        selectedRouteID = route.id
    }

    func toggleConnection() async {
        switch vpn.state {
        case .connected, .connecting, .disconnecting:
            vpn.disconnect()
        case .disconnected, .invalid:
            await vpn.connect()
        }
    }

    @discardableResult
    func login(with raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let link = Self.extractSubscriptionURL(from: text) else { return false }
        if !isDemo { Keychain.save(link.absoluteString, for: Keychain.subscriptionKey) }
        isLoggedIn = true
        selectedTab = .home
        return true
    }

    func logout() {
        vpn.disconnect()
        Keychain.delete(Keychain.subscriptionKey)
        isLoggedIn = false
    }

    func handle(url: URL) {
        login(with: url.absoluteString)
    }

    /// Принимает https-ссылку подписки или secretclub://import?url=<ссылка>.
    static func extractSubscriptionURL(from text: String) -> URL? {
        guard var comps = URLComponents(string: text) else { return nil }
        if comps.scheme == "secretclub" {
            guard let inner = comps.queryItems?.first(where: { $0.name == "url" })?.value,
                  let innerComps = URLComponents(string: inner) else { return nil }
            comps = innerComps
        }
        guard comps.scheme == "https", let host = comps.host, !host.isEmpty, comps.path.count > 1 else { return nil }
        return comps.url
    }

    func refreshNetwork() async {
        guard !isDemo else { return }
        networkMode = .unknown
        let results = await NetworkProbe.run()
        probes = results
        networkMode = NetworkProbe.classify(results)
    }
}
