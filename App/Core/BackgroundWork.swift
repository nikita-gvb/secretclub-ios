import UIKit

/// Фоновое время iOS на операцию приложения: подключение, смену сервера, выключение, проверку.
/// Свернули или закрыли приложение посреди операции — iOS даёт её доделать (до ~30 с),
/// а не замораживает на полпути (например, между «выключить» и «включить» при смене сервера).
@MainActor
final class BackgroundWork {
    private var id: UIBackgroundTaskIdentifier = .invalid

    static func begin(_ name: String) -> BackgroundWork {
        let work = BackgroundWork()
        work.id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak work] in
            work?.end()
        }
        return work
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
