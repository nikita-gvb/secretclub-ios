import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase

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
