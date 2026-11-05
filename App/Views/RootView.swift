import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(SettingsKey.appearance) private var appearance: AppAppearance = .system

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
        .overlay(alignment: .top) {
            if let toast = app.toast {
                ToastView(toast: toast)
                    .id(toast.id)
                    .padding(.top, 2)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onTapGesture { app.dismissToast() }
                    .gesture(DragGesture(minimumDistance: 6).onEnded { value in
                        if value.translation.height < 0 { app.dismissToast() }
                    })
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.72), value: app.toast)
        .sheet(isPresented: $app.showLogin, onDismiss: { app.cancelLogin() }) {
            TelegramLoginSheet()
        }
        .onAppear { AppearanceController.apply(appearance) }
        .onChange(of: appearance) { _, value in AppearanceController.apply(value) }
        .onChange(of: app.power) { old, new in app.powerChanged(from: old, to: new) }
        .task {
            await app.start()
            if app.isDemo { await Self.markRendered() }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                AppearanceController.apply(appearance)
                Task { await app.becameActive() }
            case .background:
                app.vpn.setForeground(false)
                app.scheduleBackgroundRefresh()
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

/// Две вкладки: Главная (кнопка ↔ сводка) и Настройки. Системный таб-бар (на iOS 26 — Liquid Glass).
struct MainTabView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        TabView(selection: $app.selectedTab) {
            HomeView()
                .tabItem { Label("Главная", systemImage: "power") }
                .tag(AppTab.home)
            SettingsView()
                .tabItem { Label("Настройки", systemImage: "gearshape.fill") }
                .tag(AppTab.settings)
        }
        .tint(Theme.ink)
        .sensoryFeedback(.selection, trigger: app.selectedTab)
    }
}
