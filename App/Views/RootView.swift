import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
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
        .task {
            await app.vpn.load()
            await app.refreshNetwork()
        }
    }
}

struct MainTabView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        TabView(selection: $app.selectedTab) {
            HomeView()
                .tabItem { Label("Главная", systemImage: "power.circle.fill") }
                .tag(AppTab.home)
            LocationsView()
                .tabItem { Label("Локации", systemImage: "globe.europe.africa.fill") }
                .tag(AppTab.locations)
            SubscriptionView()
                .tabItem { Label("Подписка", systemImage: "crown.fill") }
                .tag(AppTab.subscription)
            SettingsView()
                .tabItem { Label("Настройки", systemImage: "gearshape.fill") }
                .tag(AppTab.settings)
        }
    }
}
