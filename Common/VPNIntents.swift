import AppIntents
import Foundation

/// Команды для виджетов, Пункта управления, «Команд» и Siri. Выполняются без открытия приложения.
/// Переключатели виджета и Пункта управления — LiveActivityIntent: iOS выполняет их в процессе самого
/// приложения (запуская его в фоне), где права на VPN есть всегда, даже если сервис переподписи
/// не выдал их расширению виджета.

struct ToggleVPNIntent: AppIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Включить или выключить VPN"
    static let description = IntentDescription("Включает SecretClub, если VPN выключен, и выключает, если включён.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let on = await VPNSwitch.status().isOn
        try await VPNSwitch.set(!on, source: "команда «переключить»")
        return .result(dialog: on ? "SecretClub выключен" : "SecretClub включается")
    }
}

struct ConnectVPNIntent: AppIntent {
    static let title: LocalizedStringResource = "Включить VPN"
    static let description = IntentDescription("Подключает SecretClub к последнему серверу (в «Авто» — к лучшему).")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await VPNSwitch.set(true, source: "команда «включить»")
        return .result(dialog: "SecretClub включается")
    }
}

struct DisconnectVPNIntent: AppIntent {
    static let title: LocalizedStringResource = "Выключить VPN"
    static let description = IntentDescription("Отключает SecretClub.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await VPNSwitch.set(false, source: "команда «выключить»")
        return .result(dialog: "SecretClub выключен")
    }
}

struct VPNStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Состояние VPN"
    static let description = IntentDescription("Сообщает, включён ли SecretClub и через какой сервер.")

    func perform() async throws -> some IntentResult & ReturnsValue<Bool> & ProvidesDialog {
        let snap = await VPNSwitch.snapshot()
        let shared = SharedStatus.load()
        let title = (shared?.running == true ? shared?.routeTitle : nil) ?? snap.routeTitle
        let text: String
        switch snap.status {
        case .on: text = title.map { "SecretClub включён: \($0)" } ?? "SecretClub включён"
        case .connecting: text = "SecretClub подключается"
        case .off: text = "SecretClub выключен"
        case .missing: text = "SecretClub ещё не настроен — откройте приложение и подключитесь"
        }
        return .result(value: snap.status == .on, dialog: "\(text)")
    }
}

/// Переключатель с заданным значением — для виджета и Пункта управления.
struct SetVPNIntent: SetValueIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "VPN SecretClub"
    static let isDiscoverable = false

    @Parameter(title: "Включён")
    var value: Bool

    init() {}

    init(value: Bool) {
        self.value = value
    }

    func perform() async throws -> some IntentResult {
        try await VPNSwitch.set(value, source: "виджет или Пункт управления")
        return .result()
    }
}
