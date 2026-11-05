import Foundation

/// Общая папка приложения, расширения VPN и виджетов (App Group).
/// Сервис переподписи может заменить идентификатор группы — тогда берём его из профиля подписи.
/// Группы нет (сборка без прав) — каждый процесс пишет к себе, а журнал VPN приложение просит у расширения.
enum AppGroup {
    static let preferred = "group.com.secretclub.app"

    static let identifier: String? = {
        let fm = FileManager.default
        if fm.containerURL(forSecurityApplicationGroupIdentifier: preferred) != nil { return preferred }
        return provisionedGroups().first { fm.containerURL(forSecurityApplicationGroupIdentifier: $0) != nil }
    }()

    static let container: URL? = identifier.flatMap {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0)
    }

    static let defaults: UserDefaults? = identifier.flatMap { UserDefaults(suiteName: $0) }

    /// Папка для общих файлов: в группе, а без неё — своя (тогда её видит только этот процесс).
    static func directory(_ name: String) -> URL? {
        let base = container ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        guard let url = base?.appendingPathComponent(name, isDirectory: true) else { return nil }
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    /// Группы из embedded.mobileprovision: внутри CMS-контейнера лежит обычный plist.
    private static func provisionedGroups() -> [String] {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: data.subdata(in: start.lowerBound..<end.upperBound),
                                                                       format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let groups = entitlements["com.apple.security.application-groups"] as? [String] else { return [] }
        let ours = groups.filter { $0.lowercased().contains("secretclub") }
        return ours + groups.filter { !ours.contains($0) }
    }
}

/// Ключи общих настроек (AppGroup.defaults) — их читают виджеты и команды.
enum SharedKey {
    /// «Держать VPN включённым»: виджет, включая VPN, восстанавливает автоподключение.
    static let autoConnect = "autoConnect"
    /// Подписка: окончание (секунды с 1970; 0 — неизвестно), бессрочная, можно ли подключаться.
    static let subscriptionEnds = "subscriptionEnds"
    static let subscriptionLifetime = "subscriptionLifetime"
    static let subscriptionUsable = "subscriptionUsable"

    /// «Держать VPN включённым» — по умолчанию включено.
    static var keepOn: Bool { AppGroup.defaults?.object(forKey: autoConnect) as? Bool ?? true }
}
