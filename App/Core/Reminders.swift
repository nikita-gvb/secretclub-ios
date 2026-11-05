import Foundation
import UserNotifications

/// Напоминания о продлении подписки (локальные уведомления): за 3 дня, за день и когда закончилась.
@MainActor
enum Reminders {
    static let ids = ["sub-3d", "sub-1d", "sub-end"]
    private static let askedKey = "notificationsAsked"

    static var enabled: Bool { UserDefaults.standard.object(forKey: SettingsKey.reminders) as? Bool ?? true }

    /// Нажатие на уведомление открывает нужный экран.
    static func install(_ open: @escaping @MainActor (URL) -> Void) {
        NotificationRouter.shared.open = open
        UNUserNotificationCenter.current().delegate = NotificationRouter.shared
    }

    /// Разрешение спрашиваем один раз — после первого удачного подключения, а не на старте.
    static func askOnce() async {
        guard enabled, !UserDefaults.standard.bool(forKey: askedKey) else { return }
        _ = await ask()
    }

    @discardableResult
    static func ask() async -> Bool {
        UserDefaults.standard.set(true, forKey: askedKey)
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        case .denied: return false
        default: return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        }
    }

    /// Перепланировать по сроку подписки (вызывается при каждом обновлении подписки).
    static func update(expiresAt: Date?, lifetime: Bool) async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ids)
        guard enabled, let end = expiresAt, !lifetime, end > Date() else { return }
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        let plan: [(id: String, date: Date, title: String, body: String)] = [
            ("sub-3d", dayBefore(end, 3), "Подписка закончится через 3 дня",
             "Продлите заранее — VPN продолжит работать без перерыва."),
            ("sub-1d", dayBefore(end, 1), "Подписка закончится завтра",
             "Продлите сейчас, чтобы VPN не отключился. Это минута в Telegram."),
            ("sub-end", end.addingTimeInterval(60), "Подписка закончилась",
             "VPN не подключится, пока подписка не продлена. Нажмите, чтобы продлить."),
        ]
        for item in plan where item.date > Date().addingTimeInterval(60) {
            let content = UNMutableNotificationContent()
            content.title = item.title
            content.body = item.body
            content.sound = .default
            content.userInfo = ["url": "secretclub://subscription"]
            let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: item.date)
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: item.id, content: content, trigger: trigger))
        }
    }

    static func cancelAll() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
    }

    /// За n дней до конца, в 12:00 того дня, но не позже чем за час до окончания.
    private static func dayBefore(_ end: Date, _ n: Int) -> Date {
        let cal = Calendar.current
        guard let day = cal.date(byAdding: .day, value: -n, to: end),
              let noon = cal.date(bySettingHour: 12, minute: 0, second: 0, of: day) else {
            return end.addingTimeInterval(Double(-n) * 86400)
        }
        return min(noon, end.addingTimeInterval(-3600))
    }
}

/// Нажатие на уведомление → экран из ссылки; при открытом приложении уведомление тоже показываем.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = NotificationRouter()
    var open: (@MainActor (URL) -> Void)?

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let text = response.notification.request.content.userInfo["url"] as? String,
              let url = URL(string: text) else { return }
        let open = self.open
        await MainActor.run { open?(url) }
    }
}
