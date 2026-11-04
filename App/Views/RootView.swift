import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var app = app
        Group {
            if app.isLoggedIn {
                MainTabView()
                    .transition(.opacity)
            } else {
                OnboardingView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: app.isLoggedIn)
        .sheet(isPresented: $app.showLogin, onDismiss: { app.cancelLogin() }) {
            TelegramLoginSheet()
        }
        .task {
            await app.start()
            if app.isDemo { await Self.markRendered() }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: Task { await app.becameActive() }
            case .background: app.vpn.setForeground(false)
            default: break
            }
        }
    }
}

extension RootView {
    /// Для скриптов скриншотов в CI: сигнал, что первый экран отрисован.
    static func markRendered() async {
        try? await Task.sleep(for: .seconds(1.5))
        guard let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        try? Data("ok".utf8).write(to: dir.appendingPathComponent("shot-ready"))
    }
}

/// Системный таб-бар iOS (на iOS 26 — Liquid Glass), остальное — в стиле SecretClub.
struct MainTabView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        TabView(selection: $app.selectedTab) {
            HomeView()
                .tabItem { Label("Главная", systemImage: "house") }
                .tag(AppTab.home)
            LocationsView()
                .tabItem { Label("Локации", systemImage: "globe") }
                .tag(AppTab.locations)
            SubscriptionView()
                .tabItem { Label("Подписка", systemImage: "creditcard") }
                .tag(AppTab.subscription)
            SettingsView()
                .tabItem { Label("Настройки", systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
        .tint(Theme.tint)
        .sensoryFeedback(.selection, trigger: app.selectedTab)
    }
}
