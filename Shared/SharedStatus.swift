import Foundation

/// Что показывают виджеты: последнее известное состояние туннеля. Пишет расширение VPN
/// (при запуске, смене сервера, после проверки, при остановке) в общую папку.
/// Включён ли VPN на самом деле, виджет уточняет у системы (NETunnelProviderManager).
struct SharedStatus: Codable, Equatable {
    var running = false
    var routeID: String?
    /// «🇩🇪 Германия» — флаг первым символом, как в приложении.
    var routeTitle: String?
    var pingMS: Int?
    var healthy: Bool?
    /// normal, whitelist, offline.
    var network: String?
    var auto: Bool?
    var since: Date?
    var updatedAt = Date()

    private static var url: URL? { AppGroup.container?.appendingPathComponent("status.json") }

    static func load() -> SharedStatus? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SharedStatus.self, from: data)
    }

    func save() {
        guard let url = Self.url else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(self) { try? data.write(to: url, options: .atomic) }
    }

    /// То же самое, не считая времени записи.
    func same(as other: SharedStatus?) -> Bool {
        guard var other else { return false }
        other.updatedAt = updatedAt
        return other == self
    }

    /// «🇩🇪 Германия» → ("🇩🇪", "Германия").
    static func split(_ title: String?) -> (flag: String?, name: String?) {
        guard let title = title?.trimmingCharacters(in: .whitespaces), !title.isEmpty else { return (nil, nil) }
        guard let first = title.first,
              first.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation || (0x1F1E6...0x1F1FF).contains($0.value) }) else {
            return (nil, title)
        }
        let rest = title.dropFirst().trimmingCharacters(in: .whitespaces)
        return (String(first), rest.isEmpty ? nil : rest)
    }
}
