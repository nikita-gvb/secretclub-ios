import SwiftUI

@main
struct SecretClubApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tint(Theme.ink)
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .onOpenURL { model.handle(url: $0) }
        }
        // Подписка обновляется и без открытия приложения: свежие серверы доезжают до VPN и виджета.
        .backgroundTask(.appRefresh(AppModel.refreshTaskID)) { [model] in
            await model.backgroundRefresh()
        }
    }
}
