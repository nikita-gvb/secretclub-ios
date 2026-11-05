import Foundation

/// Сборка конфигурации ядра в расширении: рабочий сервер + проверочные входы для запасных.
///
/// У каждого запасного сервера свой HTTP-вход на 127.0.0.1 и свои outbounds (теги с префиксом),
/// поэтому расширение проверяет их все параллельно и по-настоящему (через само ядро),
/// не трогая трафик пользователя. Переключение — ровно один перезапуск ядра.
enum CoreConfig {
    static let healthTag = "health-in"
    static let serviceProtocols: Set<String> = ["freedom", "blackhole", "dns", "loopback"]

    static func object(_ text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }

    static func text(_ object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Основной outbound сервера: с тегом proxy или первый не служебный.
    static func mainOutbound(_ outbounds: [[String: Any]]) -> [String: Any]? {
        if let proxy = outbounds.first(where: { ($0["tag"] as? String) == "proxy" }) { return proxy }
        return outbounds.first { !serviceProtocols.contains(($0["protocol"] as? String ?? "").lowercased()) }
    }

    /// Outbounds сервера с префиксом в тегах (и в ссылках dialerProxy / proxySettings) —
    /// чтобы несколько серверов жили в одном конфиге. Возвращает их и тег основного.
    static func prefixed(_ config: [String: Any], prefix: String) -> (outbounds: [[String: Any]], main: String)? {
        guard let list = config["outbounds"] as? [[String: Any]], let main = mainOutbound(list) else { return nil }
        let skipped: Set<String> = ["dns", "loopback"]
        var out: [[String: Any]] = []
        for outbound in list {
            let proto = (outbound["protocol"] as? String ?? "").lowercased()
            if skipped.contains(proto) { continue }
            var o = outbound
            o["tag"] = prefix + (outbound["tag"] as? String ?? "proxy")
            if var stream = o["streamSettings"] as? [String: Any],
               var sock = stream["sockopt"] as? [String: Any],
               let dialer = sock["dialerProxy"] as? String, !dialer.isEmpty {
                sock["dialerProxy"] = prefix + dialer
                stream["sockopt"] = sock
                o["streamSettings"] = stream
            }
            if var proxy = o["proxySettings"] as? [String: Any], let tag = proxy["tag"] as? String {
                proxy["tag"] = prefix + tag
                o["proxySettings"] = proxy
            }
            out.append(o)
        }
        return (out, prefix + (main["tag"] as? String ?? "proxy"))
    }

    /// Готовый к запуску конфиг: дескриптор туннеля, geo-файлы, проверочный вход рабочего сервера
    /// и (если есть) проверочные входы запасных. Возвращает текст и карту «id запасного → порт».
    static func compose(active text: String, fd: Int32, assetDir: String?, healthPort: Int,
                        extras: [(id: String, config: String)], ports: [Int]) throws -> (text: String, ports: [String: Int]) {
        guard var root = object(text) else { throw XrayError(message: "некорректная конфигурация") }
        var env = root["env"] as? [String: Any] ?? [:]
        env["xray.tun.fd"] = String(fd)
        if let assetDir { env["xray.location.asset"] = assetDir }
        root["env"] = env

        var inbounds = root["inbounds"] as? [[String: Any]] ?? []
        let health: [String: Any] = ["tag": healthTag, "listen": "127.0.0.1", "port": healthPort,
                                     "protocol": "http", "settings": [String: Any]()]
        if let index = inbounds.firstIndex(where: { ($0["tag"] as? String) == healthTag }) {
            inbounds[index] = health
        } else {
            inbounds.append(health)
        }
        for key in ["stats", "metrics", "api"] { root.removeValue(forKey: key) }
        // Наблюдатель (пинг серверов по таймеру) нужен только балансировщику — без него не будим сеть.
        let routingObject = root["routing"] as? [String: Any]
        if (routingObject?["balancers"] as? [Any] ?? []).isEmpty {
            root.removeValue(forKey: "observatory")
            root.removeValue(forKey: "burstObservatory")
        }

        var map: [String: Int] = [:]
        if !extras.isEmpty {
            var outbounds = root["outbounds"] as? [[String: Any]] ?? []
            var routing = routingObject ?? [:]
            var rules = routing["rules"] as? [[String: Any]] ?? []
            var head: [[String: Any]] = []
            for (index, extra) in extras.enumerated() where index < ports.count {
                guard let config = object(extra.config),
                      let part = prefixed(config, prefix: "c\(index)-") else { continue }
                let inTag = "hc\(index)"
                inbounds.append(["tag": inTag, "listen": "127.0.0.1", "port": ports[index], "protocol": "http",
                                 "settings": [String: Any]()])
                outbounds += part.outbounds
                head.append(["type": "field", "inboundTag": [inTag], "outboundTag": part.main])
                map[extra.id] = ports[index]
            }
            rules = head + rules
            routing["rules"] = rules
            root["routing"] = routing
            root["outbounds"] = outbounds
        }
        root["inbounds"] = inbounds
        guard let result = Self.text(root) else { throw XrayError(message: "не удалось собрать конфигурацию") }
        return (result, map)
    }
}
