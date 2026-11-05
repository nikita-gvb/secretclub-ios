import Foundation

/// Журнал для диагностики: строки «дата время текст» в файлах общей папки.
/// tunnel — расширение VPN, app — приложение, виджеты и команды. Пишется из любого потока, не блокирует.
enum DiagLog {
    enum Source: String, CaseIterable, Codable {
        case tunnel, app

        var title: String { self == .tunnel ? "VPN" : "Приложение" }
    }

    /// Предел одного файла: дальше текущий становится «.1», старый «.1» удаляется (итого ≤ 2 × limit).
    static let limit = 192 * 1024
    private static let queue = DispatchQueue(label: "com.secretclub.diaglog", qos: .utility)
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static var directory: URL? { AppGroup.directory("Diagnostics") }

    static func url(_ source: Source, old: Bool = false) -> URL? {
        directory?.appendingPathComponent(old ? "\(source.rawValue).1.log" : "\(source.rawValue).log")
    }

    /// Предупреждения помечаем «⚠︎» — экран диагностики выделяет их цветом и фильтром «Важное».
    static func warn(_ text: String, to source: Source) { write("⚠︎ " + text, to: source) }

    static func write(_ text: String, to source: Source) {
        let date = Date()
        queue.async {
            let line = "\(stamp.string(from: date)) \(text.replacingOccurrences(of: "\n", with: " · "))\n"
            append(line, source)
        }
    }

    /// Дождаться записи (перед чтением или выходом).
    static func flush() { queue.sync {} }

    /// Журнал целиком (старая часть + текущая), не больше maxBytes с конца.
    static func read(_ source: Source, maxBytes: Int = 512 * 1024) -> String {
        queue.sync {
            var data = Data()
            for url in [url(source, old: true), url(source)].compactMap({ $0 }) {
                if let part = try? Data(contentsOf: url) { data.append(part) }
            }
            if data.count > maxBytes {
                data = data.suffix(maxBytes)
                // Начинаем с целой строки.
                if let newline = data.firstIndex(of: 0x0A) { data = data.suffix(from: data.index(after: newline)) }
            }
            return String(decoding: data, as: UTF8.self)
        }
    }

    static func clear() {
        queue.sync {
            for source in Source.allCases {
                for url in [url(source), url(source, old: true)].compactMap({ $0 }) { try? FileManager.default.removeItem(at: url) }
            }
        }
    }

    private static func append(_ line: String, _ source: Source) {
        guard let url = url(source) else { return }
        let fm = FileManager.default
        let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        if size > limit, let old = Self.url(source, old: true) {
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: url, to: old)
        }
        let data = Data(line.utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }
}

/// Сбой или аварийное завершение: из MetricKit или замеченное расширением VPN.
struct Incident: Codable, Identifiable, Equatable {
    var id: String
    var date: Date
    var source: DiagLog.Source
    var title: String
    var detail: String
    /// Полный отчёт MetricKit (JSON) в папке диагностики.
    var file: String?
}

enum Incidents {
    private static let lock = NSLock()
    static let keep = 60

    private static var url: URL? { DiagLog.directory?.appendingPathComponent("incidents.json") }

    static func all() -> [Incident] {
        lock.lock()
        defer { lock.unlock() }
        return load()
    }

    /// false — такой уже есть (MetricKit присылает прошлые отчёты повторно).
    @discardableResult
    static func add(_ incident: Incident) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var list = load()
        guard !list.contains(where: { $0.id == incident.id }) else { return false }
        list.append(incident)
        list.sort { $0.date > $1.date }
        if list.count > keep {
            for dropped in list[keep...] {
                if let file = dropped.file, let dir = DiagLog.directory { try? FileManager.default.removeItem(at: dir.appendingPathComponent(file)) }
            }
            list = Array(list.prefix(keep))
        }
        save(list)
        return true
    }

    static func recent(days: Double = 7) -> [Incident] {
        all().filter { Date().timeIntervalSince($0.date) < days * 86400 }
    }

    static func clear() {
        lock.lock()
        defer { lock.unlock() }
        for item in load() {
            if let file = item.file, let dir = DiagLog.directory { try? FileManager.default.removeItem(at: dir.appendingPathComponent(file)) }
        }
        if let url { try? FileManager.default.removeItem(at: url) }
    }

    private static func load() -> [Incident] {
        guard let url, let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Incident].self, from: data)) ?? []
    }

    private static func save(_ list: [Incident]) {
        guard let url else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(list) { try? data.write(to: url, options: .atomic) }
    }
}

/// Сеанс расширения VPN: метка «запущен» живёт, пока туннель работает. Осталась от прошлого
/// запуска — значит, расширение завершилось без stopTunnel (выгрузила iOS, например по памяти, или сбой).
enum TunnelSession {
    struct State: Codable {
        var started: Date
        var alive: Date
        var peakMB: Double
        var route: String?
        var version: String
        /// Сборка приложения: другая при следующем запуске — значит, приложение обновили, это не сбой.
        var build: String? = nil
    }

    private static var url: URL? { DiagLog.directory?.appendingPathComponent("tunnel-session.json") }

    static func load() -> State? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(State.self, from: data)
    }

    static func save(_ state: State) {
        guard let url else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(state) { try? data.write(to: url, options: .atomic) }
    }

    static func end() {
        if let url { try? FileManager.default.removeItem(at: url) }
    }
}
