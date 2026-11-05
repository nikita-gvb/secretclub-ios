import Foundation
import WidgetKit

/// Виджеты и переключатель в Пункте управления обновляет само расширение VPN: приложение может быть
/// закрыто, а VPN включили из Пункта управления, Настроек iOS, автоподключением или «Авто» сменил сервер.
/// Запросы склеиваются (не чаще раза в 3 с) — у iOS ограничен бюджет обновлений виджетов.
enum WidgetRefresh {
    private static let queue = DispatchQueue(label: "com.secretclub.tunnel.widgets", qos: .utility)
    /// Только на queue.
    private static var pending: DispatchWorkItem?
    private static var last = Date.distantPast

    /// delay — дать системе обновить статус VPN (после «подключено» он меняется не мгновенно).
    static func request(after delay: Double = 0) {
        queue.async {
            pending?.cancel()
            let wait = max(delay, 3 - Date().timeIntervalSince(last), 0)
            let item = DispatchWorkItem {
                pending = nil
                last = Date()
                reload()
            }
            pending = item
            queue.asyncAfter(deadline: .now() + wait, execute: item)
        }
    }

    /// Сразу: VPN выключается, процесс расширения скоро завершится.
    static func now() {
        queue.sync {
            pending?.cancel()
            pending = nil
            last = Date()
        }
        reload()
    }

    private static func reload() {
        WidgetCenter.shared.reloadAllTimelines()
        if #available(iOS 18.0, *) { ControlCenter.shared.reloadAllControls() }
    }
}
