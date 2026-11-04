import SwiftUI

@main
struct SecretClubApp: App {
    @State private var model = AppModel()
    @AppStorage(SettingsKey.theme) private var theme: AppTheme = .dark

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(theme.colorScheme)
                .tint(Theme.accent)
                .onOpenURL { model.handle(url: $0) }
        }
    }
}
