import AppIntents

/// Готовые команды для Siri и приложения «Команды» (появляются сами, настраивать не нужно).
struct SecretClubShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ConnectVPNIntent(),
                    phrases: ["Включи \(.applicationName)", "Включить VPN в \(.applicationName)", "Подключи \(.applicationName)"],
                    shortTitle: "Включить VPN", systemImageName: "lock.shield.fill")
        AppShortcut(intent: DisconnectVPNIntent(),
                    phrases: ["Выключи \(.applicationName)", "Выключить VPN в \(.applicationName)", "Отключи \(.applicationName)"],
                    shortTitle: "Выключить VPN", systemImageName: "shield.slash")
        AppShortcut(intent: ToggleVPNIntent(),
                    phrases: ["Переключи \(.applicationName)", "Переключить VPN в \(.applicationName)"],
                    shortTitle: "Вкл./выкл. VPN", systemImageName: "power")
        AppShortcut(intent: VPNStatusIntent(),
                    phrases: ["Включён ли \(.applicationName)", "Состояние \(.applicationName)"],
                    shortTitle: "Состояние VPN", systemImageName: "info.circle")
    }
}
