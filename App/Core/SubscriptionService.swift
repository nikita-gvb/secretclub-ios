import Foundation

enum SubscriptionError: LocalizedError {
    case http(Int)
    case format
    case noServers(String?)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .http(let code):
            return code == 404 ? "Подписка не найдена. Проверьте ссылку." : "Сервер подписки ответил ошибкой \(code)."
        case .format:
            return "Не удалось прочитать ответ сервера подписки."
        case .noServers(let remark):
            if let remark { return "Сервер не выдал конфигурацию: \(remark)" }
            return "В подписке нет серверов."
        case .network(let message):
            return "Нет связи с сервером подписки: \(message)"
        }
    }
}

struct ParsedSubscription {
    var routes: [Route]
    var configs: [String: [String: Any]]

    static let empty = ParsedSubscription(routes: [], configs: [:])
}

/// Основная подписка и резервное подключение (отдельная подписка с ограниченным трафиком).
enum SubscriptionSlot: String {
    case primary, reserve

    var keychainKey: String { self == .primary ? Keychain.subscriptionKey : Keychain.reserveKey }
    var filePrefix: String { self == .primary ? "" : "reserve-" }
}

enum SubscriptionService {
    static func jsonURL(from base: URL) -> URL {
        base.lastPathComponent == "json" ? base : base.appendingPathComponent("json")
    }

    static func fetch(_ base: URL) async throws -> (Data, SubscriptionMeta) {
        var req = URLRequest(url: jsonURL(from: base), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        for (key, value) in DeviceInfo.headers { req.setValue(value, forHTTPHeaderField: key) }
        let result: (Data, URLResponse)
        do {
            result = try await URLSession.shared.data(for: req)
        } catch {
            throw SubscriptionError.network(error.localizedDescription)
        }
        guard let http = result.1 as? HTTPURLResponse else { throw SubscriptionError.format }
        guard (200..<300).contains(http.statusCode) else { throw SubscriptionError.http(http.statusCode) }
        return (result.0, meta(from: http))
    }

    static func meta(from http: HTTPURLResponse) -> SubscriptionMeta {
        var m = SubscriptionMeta()
        m.title = decoded(http.value(forHTTPHeaderField: "profile-title"))
        m.announce = decoded(http.value(forHTTPHeaderField: "announce"))
        m.supportURL = http.value(forHTTPHeaderField: "support-url")
        if let support = m.supportURL, !support.isEmpty { UserDefaults.standard.set(support, forKey: "supportURL") }
        if let info = http.value(forHTTPHeaderField: "subscription-userinfo") {
            for part in info.split(separator: ";") {
                let kv = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard kv.count == 2, let v = Int64(kv[1]) else { continue }
                switch kv[0] {
                case "upload": m.upload = v
                case "download": m.download = v
                case "total": m.total = v
                case "expire": if v > 0 { m.expire = Date(timeIntervalSince1970: TimeInterval(v)) }
                default: break
                }
            }
        }
        m.updatedAt = Date()
        return m
    }

    static func decoded(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        guard value.hasPrefix("base64:") else { return value }
        var b64 = String(value.dropFirst(7))
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64), let s = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func parse(_ data: Data, slot: SubscriptionSlot = .primary) throws -> ParsedSubscription {
        let object = try? JSONSerialization.jsonObject(with: data)
        let list: [[String: Any]]
        if let array = object as? [[String: Any]] {
            list = array
        } else if let one = object as? [String: Any] {
            list = [one]
        } else {
            throw SubscriptionError.format
        }
        var routes: [Route] = []
        var configs: [String: [String: Any]] = [:]
        var seen = Set<String>()
        for (index, cfg) in list.enumerated() {
            let remarks = (cfg["remarks"] as? String) ?? "Сервер \(index + 1)"
            guard let outbounds = cfg["outbounds"] as? [[String: Any]],
                  let proxy = RouteClassifier.mainOutbound(outbounds),
                  !RouteClassifier.isPlaceholder(proxy),
                  !RouteClassifier.isPlaceholder(remarks: remarks),
                  !RouteClassifier.isHidden(remarks: remarks, config: cfg) else { continue }
            var id = slot == .reserve ? "r|" + remarks : remarks
            if seen.contains(id) { id += "#\(index)" }
            seen.insert(id)
            routes.append(RouteClassifier.route(id: id, remarks: remarks, proxy: proxy, reserve: slot == .reserve))
            configs[id] = cfg
        }
        if routes.isEmpty { throw SubscriptionError.noServers(list.first?["remarks"] as? String) }
        RouteClassifier.disambiguate(&routes)
        return ParsedSubscription(routes: routes, configs: configs)
    }

    // MARK: - Кэш

    private static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("subscription", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func save(data: Data?, meta: SubscriptionMeta, slot: SubscriptionSlot = .primary) {
        let configsURL = directory.appendingPathComponent(slot.filePrefix + "configs.json")
        if let data { try? data.write(to: configsURL, options: .atomic) } else { try? FileManager.default.removeItem(at: configsURL) }
        if let encoded = try? JSONEncoder().encode(meta) {
            try? encoded.write(to: directory.appendingPathComponent(slot.filePrefix + "meta.json"), options: .atomic)
        }
    }

    static func loadCache(_ slot: SubscriptionSlot = .primary) -> (Data?, SubscriptionMeta)? {
        guard let metaData = try? Data(contentsOf: directory.appendingPathComponent(slot.filePrefix + "meta.json")),
              let meta = try? JSONDecoder().decode(SubscriptionMeta.self, from: metaData) else { return nil }
        return (try? Data(contentsOf: directory.appendingPathComponent(slot.filePrefix + "configs.json")), meta)
    }

    static func clearCache(_ slot: SubscriptionSlot) {
        for name in ["configs.json", "meta.json"] {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(slot.filePrefix + name))
        }
    }

    static func clearCache() {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Раскладывает серверы из подписки по группам по названию и транспорту.
enum RouteClassifier {
    static func mainOutbound(_ outbounds: [[String: Any]]) -> [String: Any]? {
        CoreConfig.mainOutbound(outbounds)
    }

    static func address(_ outbound: [String: Any]) -> String {
        let settings = outbound["settings"] as? [String: Any]
        if let vnext = settings?["vnext"] as? [[String: Any]], let a = vnext.first?["address"] as? String { return a }
        if let servers = settings?["servers"] as? [[String: Any]], let a = servers.first?["address"] as? String { return a }
        if let a = settings?["address"] as? String { return a }
        return ""
    }

    static func port(_ outbound: [String: Any]) -> Int {
        let settings = outbound["settings"] as? [String: Any]
        let raw: Any? = (settings?["vnext"] as? [[String: Any]])?.first?["port"]
            ?? (settings?["servers"] as? [[String: Any]])?.first?["port"]
            ?? settings?["port"]
        if let n = raw as? NSNumber { return n.intValue }
        if let s = raw as? String {
            let digits = s.prefix { $0.isNumber }
            return Int(digits) ?? 0
        }
        return 0
    }

    /// Заглушки Remnawave: «❗️ Данное приложение не поддерживается», «Лимит устройств» и т. п.
    static func isPlaceholder(remarks: String) -> Bool {
        let lower = remarks.lowercased()
        return remarks.hasPrefix("❗") || lower.contains("не поддерживается") || lower.contains("лимит устройств")
            || lower.contains("подписка истекла") || lower.contains("expired")
    }

    /// Не показываем: «Авто-выбор» для Happ (балансировщик) и «Резервный доступ (FAQ)».
    static func isHidden(remarks: String, config: [String: Any]) -> Bool {
        let lower = remarks.lowercased()
        if lower.contains("авто-выбор") || lower.contains("автовыбор") || lower.contains("auto-select") { return true }
        if remarks.hasPrefix("🆘") || lower.contains("резервный доступ") || lower.contains("faq") { return true }
        if remarks.hasPrefix("BAL-") { return true }
        let routing = config["routing"] as? [String: Any]
        let balancers = routing?["balancers"] as? [[String: Any]] ?? []
        let proxies = (config["outbounds"] as? [[String: Any]] ?? []).filter {
            !["freedom", "blackhole", "dns", "loopback"].contains(($0["protocol"] as? String ?? "").lowercased())
        }
        return !balancers.isEmpty && proxies.count > 1
    }

    /// Одинаковые названия в одной группе нумеруем: «Финляндия», «Финляндия · 2».
    static func disambiguate(_ routes: inout [Route]) {
        var seen: [String: Int] = [:]
        for i in routes.indices {
            let key = "\(routes[i].group.rawValue)|\(routes[i].title)|\(routes[i].detail)"
            let n = (seen[key] ?? 0) + 1
            seen[key] = n
            if n > 1 { routes[i].detail += " · \(n)" }
        }
    }

    static func isPlaceholder(_ outbound: [String: Any]) -> Bool {
        let a = address(outbound)
        return a.isEmpty || a == "0.0.0.0"
    }

    static func route(id: String, remarks: String, proxy: [String: Any], reserve: Bool = false) -> Route {
        let text = remarks
            .replacingOccurrences(of: #"\s*\^~\d+~\^"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let (emoji, rest) = splitEmoji(text)
        let lower = text.lowercased()
        let addr = address(proxy).lowercased()

        let group: RouteGroup
        if reserve || lower.contains("обход") || lower.contains(" бс") || lower.contains("cdn") {
            group = .reserve
        } else if lower.contains("мост") || lower.contains("через рф") || addr.contains("ru-entry") {
            group = .bridge
        } else {
            group = .regular
        }
        let (transport, transportTitle) = transportOf(proxy, group: group)

        var title = rest
        if let code = regionCode(emoji), let name = Locale(identifier: "ru_RU").localizedString(forRegionCode: code) {
            title = name
            let dupPattern = group == .reserve ? #"\((\d)\)\s*$"# : #"\((\d)\)"#
            if let n = firstMatch(dupPattern, in: rest) { title += " \(n)" }
        }

        let speed = firstMatch(#"(?i)(\d+)\s*/\s*GBIT"#, in: rest).map { "\($0) Гбит/с" }
        let variant = group == .reserve ? firstMatch(#"\(([^)]*[A-Za-z][^)]*|\d+)\)"#, in: rest) : nil
        var parts: [String]
        switch group {
        case .regular: parts = [transportTitle]
        case .bridge: parts = ["через Россию", transportTitle]
        case .reserve: parts = ["через CDN"]
        }
        if let speed { parts.append(speed) }
        if let variant, variant.count > 1 || group == .reserve { parts.append(variant) }

        return Route(id: id,
                     emoji: emoji.isEmpty ? "🌐" : emoji,
                     title: title.isEmpty ? text : title,
                     detail: parts.joined(separator: " · "),
                     group: group,
                     transport: transport,
                     transportTitle: transportTitle,
                     remarks: remarks)
    }

    static func transportOf(_ outbound: [String: Any], group: RouteGroup) -> (TransportKind, String) {
        let proto = (outbound["protocol"] as? String ?? "").lowercased()
        let stream = outbound["streamSettings"] as? [String: Any] ?? [:]
        let network = (stream["network"] as? String ?? "tcp").lowercased()
        let security = (stream["security"] as? String ?? "none").lowercased()
        if proto.contains("hysteria") || network.contains("hysteria") { return (.hysteria2, "Hysteria2") }
        if security == "reality" { return (.reality, network == "xhttp" ? "Reality · XHTTP" : "Reality") }
        if network == "xhttp" || network == "splithttp" { return (group == .reserve ? .cdn : .xhttp, "XHTTP") }
        switch network {
        case "ws": return (.other, "WebSocket")
        case "grpc": return (.other, "gRPC")
        case "httpupgrade": return (.other, "HTTPUpgrade")
        default: return (.other, security == "tls" ? "TLS" : network.uppercased())
        }
    }

    static func splitEmoji(_ s: String) -> (String, String) {
        guard let first = s.first,
              first.unicodeScalars.contains(where: { $0.properties.isEmoji && $0.value > 0x2000 }) else { return ("", s) }
        return (String(first), s.dropFirst().trimmingCharacters(in: .whitespaces))
    }

    static func regionCode(_ emoji: String) -> String? {
        let scalars = emoji.unicodeScalars.filter { (0x1F1E6...0x1F1FF).contains($0.value) }
        guard scalars.count == 2 else { return nil }
        return String(String.UnicodeScalarView(scalars.compactMap { UnicodeScalar($0.value - 127397) }))
    }

    static func firstMatch(_ pattern: String, in s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }
}
