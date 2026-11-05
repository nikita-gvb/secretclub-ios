import Foundation

struct XrayError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Сборка конфигурации ядра в расширении: рабочий сервер + проверочные входы для запасных.
///
/// У каждого запасного сервера свой HTTP-вход на 127.0.0.1 и свои outbounds (теги с префиксом),
/// поэтому расширение проверяет их все параллельно и по-настоящему (через само ядро),
/// не трогая трафик пользователя. В «горячем» режиме трафик идёт через балансировщик sc-route,
/// и рабочий сервер меняется без перезапуска ядра (SecretClubSetBalancerTarget).
enum CoreConfig {
    static let healthTag = "health-in"
    /// Балансировщик, через который в «горячем» режиме идёт весь трафик рабочего сервера.
    static let routeBalancer = "sc-route"
    /// Проверочный вход самого рабочего сервера (в «горячем» режиме health-in идёт через балансировщик).
    static let mainProbeTag = "hcm"

    /// Собранный конфиг.
    struct Built {
        var text: String
        /// id запасного (и рабочего — в «горячем» режиме) → порт проверочного входа.
        var ports: [String: Int]
        /// «Горячий» режим: id сервера → тег его outbound в ядре. Пусто — переключение только перезапуском.
        var tags: [String: String]
        /// Тег основного outbound рабочего сервера.
        var main: String?
        /// В конфиге есть балансировщик sc-route — его нужно сразу направить на рабочий сервер.
        var balanced = false
        var hot: Bool { balanced && tags.count >= 2 }
    }
    static let serviceProtocols: Set<String> = ["freedom", "blackhole", "dns", "loopback"]

    static func object(_ text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }

    static func text(_ object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Имена счётчиков ядра для этого конфига: отправлено/получено через TUN и получено от сервера.
    static func counterNames(_ text: String) -> (up: String, down: String, server: String)? {
        guard let root = object(text) else { return nil }
        let inbounds = root["inbounds"] as? [[String: Any]] ?? []
        guard let tun = inbounds.first(where: { ($0["protocol"] as? String) == "tun" })?["tag"] as? String,
              !tun.isEmpty else { return nil }
        let main = mainOutbound(root["outbounds"] as? [[String: Any]] ?? [])?["tag"] as? String ?? "proxy"
        return ("inbound>>>\(tun)>>>traffic>>>uplink", "inbound>>>\(tun)>>>traffic>>>downlink",
                "outbound>>>\(main)>>>traffic>>>downlink")
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
    /// и (если есть) проверочные входы запасных. hot — весь трафик рабочего сервера через балансировщик,
    /// чтобы переключаться на запасные без перезапуска. Портов нужно extras.count + 1 (последний — рабочему).
    static func compose(active text: String, fd: Int32, assetDir: String?, healthPort: Int,
                        extras: [(id: String, config: String)], ports: [Int],
                        activeID: String? = nil, hot: Bool = false) throws -> Built {
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
        for key in ["metrics", "api"] { root.removeValue(forKey: key) }
        // Счётчики трафика: вход TUN (всё, что прошло через VPN) и outbounds (ответы сервера).
        root["stats"] = [String: Any]()
        var policy = root["policy"] as? [String: Any] ?? [:]
        var system = policy["system"] as? [String: Any] ?? [:]
        for key in ["statsInboundUplink", "statsInboundDownlink", "statsOutboundDownlink"] { system[key] = true }
        policy["system"] = system
        root["policy"] = policy
        // Наблюдатель (пинг серверов по таймеру) нужен только балансировщику — без него не будим сеть.
        let routingObject = root["routing"] as? [String: Any]
        let ownBalancers = !(routingObject?["balancers"] as? [Any] ?? []).isEmpty
        if !ownBalancers {
            root.removeValue(forKey: "observatory")
            root.removeValue(forKey: "burstObservatory")
        }

        var map: [String: Int] = [:]
        var tags: [String: String] = [:]
        var balanced = false
        var outbounds = root["outbounds"] as? [[String: Any]] ?? []
        let mainTag = mainOutbound(outbounds)?["tag"] as? String
        if !extras.isEmpty {
            var routing = routingObject ?? [:]
            var rules = routing["rules"] as? [[String: Any]] ?? []
            var head: [[String: Any]] = []
            // Свой балансировщик в конфиге сервера — не вмешиваемся, переключаем перезапуском.
            let useHot = hot && !ownBalancers && mainTag != nil
            if useHot, let mainTag {
                rules = rules.map { rule in
                    guard (rule["outboundTag"] as? String) == mainTag else { return rule }
                    var changed = rule
                    changed.removeValue(forKey: "outboundTag")
                    changed["balancerTag"] = routeBalancer
                    return changed
                }
                // Без подходящего правила ядро шлёт трафик в первый outbound — если это рабочий сервер,
                // ведём такой трафик через балансировщик явно.
                if (outbounds.first?["tag"] as? String) == mainTag {
                    rules.append(["type": "field", "network": "tcp,udp", "balancerTag": routeBalancer])
                }
                routing["balancers"] = [["tag": routeBalancer, "selector": [mainTag],
                                         "strategy": ["type": "random"]] as [String: Any]]
                // Проверка рабочего сервера (health-in) идёт тем же путём, что и трафик, — через балансировщик.
                head.append(["type": "field", "inboundTag": [healthTag], "balancerTag": routeBalancer])
                balanced = true
                if let activeID { tags[activeID] = mainTag }
            }
            for (index, extra) in extras.enumerated() where index < ports.count {
                guard let config = object(extra.config),
                      let part = prefixed(config, prefix: "c\(index)-") else { continue }
                let inTag = "hc\(index)"
                inbounds.append(["tag": inTag, "listen": "127.0.0.1", "port": ports[index], "protocol": "http",
                                 "settings": [String: Any]()])
                outbounds += part.outbounds
                head.append(["type": "field", "inboundTag": [inTag], "outboundTag": part.main])
                map[extra.id] = ports[index]
                if useHot { tags[extra.id] = part.main }
            }
            // health-in в «горячем» режиме идёт за балансировщиком, а у самого рабочего — свой вход.
            if useHot, let mainTag, let activeID, extras.count < ports.count {
                inbounds.append(["tag": mainProbeTag, "listen": "127.0.0.1", "port": ports[extras.count],
                                 "protocol": "http", "settings": [String: Any]()])
                head.append(["type": "field", "inboundTag": [mainProbeTag], "outboundTag": mainTag])
                map[activeID] = ports[extras.count]
            }
            rules = head + rules
            routing["rules"] = rules
            root["routing"] = routing
            root["outbounds"] = outbounds
        }
        root["inbounds"] = inbounds
        guard let result = Self.text(root) else { throw XrayError(message: "не удалось собрать конфигурацию") }
        return Built(text: result, ports: map, tags: tags, main: mainTag, balanced: balanced)
    }
}
