import SwiftUI

@main
struct SecretClubApp: App {
    @State private var model = AppModel()

    init() {
        Appearance.apply()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .tint(Theme.tint)
                .font(.scBody)
                .onOpenURL { model.handle(url: $0) }
        }
    }
}
