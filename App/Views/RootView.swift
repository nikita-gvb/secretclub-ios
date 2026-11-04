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
        ZStack(alignment: .bottom) {
            Group {
                switch app.selectedTab {
                case .home: HomeView()
                case .locations: LocationsView()
                case .subscription: SubscriptionView()
                case .settings: SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            SCTabBar(selection: $app.selectedTab)
                .padding(.bottom, 2)
        }
        .background(Theme.background.ignoresSafeArea())
        .ignoresSafeArea(.keyboard)
    }
}
