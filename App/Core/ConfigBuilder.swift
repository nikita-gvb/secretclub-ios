import Foundation

struct BuildOptions {
    var ruDirect = true
    var vpnDomains: [String] = []
    var directDomains: [String] = []
    var quietLog = true
}

/// Готовит конфиг из подписки к запуску в расширении: TUN-вход вместо SOCKS/HTTP,
/// перехват DNS, исключения пользователя, только доступные geo-коды.
enum ConfigBuilder {
    static let tunTag = "tun"
    static let dnsOutTag = "dns-out"
    /// Что есть в geoip.dat / geosite.dat из комплекта (sub.scvpn.app/geo).
    static let availableGeo: Set<String> = ["geoip:ru", "geoip:private", "geosite:ru-inside"]
    static let localDomains: Set<String> = ["domain:local", "domain:lan", "domain:home.arpa", "localhost"]

    static func json(_ obj: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static var tunInbound: [String: Any] {
        let settings: [String: Any] = ["name": "utun", "mtu": 1500, "userLevel": 8]
        let sniffing: [String: Any] = ["enabled": true, "routeOnly": true, "destOverride": ["http", "tls", "quic"]]
        return ["tag": tunTag, "protocol": "tun", "port": 0, "settings": settings, "sniffing": sniffing]
    }

    static func runtime(_ raw: [String: Any], options: BuildOptions) -> [String: Any] {
        var c = raw
        for key in ["remarks", "remnawave", "metrics", "stats", "api", "reverse"] { c.removeValue(forKey: key) }
        c["log"] = ["loglevel": options.quietLog ? "error" : "warning", "access": "none"]
        c["inbounds"] = [tunInbound]

        var outbounds = c["outbounds"] as? [[String: Any]] ?? []
        let tags = Set(outbounds.compactMap { $0["tag"] as? String })
        if !tags.contains("direct") { outbounds.append(["tag": "direct", "protocol": "freedom"]) }
        if !tags.contains("block") { outbounds.append(["tag": "block", "protocol": "blackhole"]) }
        if !tags.contains(dnsOutTag) { outbounds.append(["tag": dnsOutTag, "protocol": "dns"]) }
        c["outbounds"] = outbounds

        var routing = c["routing"] as? [String: Any] ?? [:]
        let original = routing["rules"] as? [[String: Any]] ?? []
        let target = proxyTarget(outbounds: outbounds, rules: original)
        var rules = original.compactMap { sanitize(rule: $0) }
        if !options.ruDirect { rules = rules.compactMap { stripRussianDirect($0) } }

        var head: [[String: Any]] = [
            ["type": "field", "inboundTag": [tunTag], "port": "53", "outboundTag": dnsOutTag],
        ]
        if !options.directDomains.isEmpty {
            head.append(["type": "field", "domain": options.directDomains.map { "domain:\($0)" }, "outboundTag": "direct"])
        }
        if !options.vpnDomains.isEmpty {
            var rule: [String: Any] = ["type": "field", "domain": options.vpnDomains.map { "domain:\($0)" }]
            rule.merge(target) { $1 }
            head.append(rule)
        }
        routing["rules"] = head + rules
        if routing["domainStrategy"] == nil { routing["domainStrategy"] = "IPIfNonMatch" }
        c["routing"] = routing

        if var dns = c["dns"] as? [String: Any] {
            if let servers = dns["servers"] as? [Any] {
                dns["servers"] = servers.compactMap { sanitize(dnsServer: $0) }
            }
            c["dns"] = dns
        } else {
            c["dns"] = ["servers": ["https://1.1.1.1/dns-query", "77.88.8.8"], "queryStrategy": "UseIPv4"]
        }
        return c
    }

    /// Копия для testXray в приложении: без TUN-входа (его открывает только расширение).
    static func validation(_ runtime: [String: Any], assetDir: String?) -> String? {
        var c = runtime
        c["inbounds"] = [[String: Any]]()
        if let assetDir { c["env"] = ["xray.location.asset": assetDir] }
        return json(c)
    }

    /// Только outbounds — для пакетной проверки задержки.
    static func pingConfig(_ raw: [String: Any]) -> (json: String, tag: String)? {
        guard let outbounds = raw["outbounds"] as? [[String: Any]],
              let main = RouteClassifier.mainOutbound(outbounds),
              let json = json(["outbounds": outbounds]) else { return nil }
        return (json, main["tag"] as? String ?? "proxy")
    }

    /// Один конфиг Xray для пинга многих серверов сразу: у каждого сервера свой HTTP-вход
    /// на 127.0.0.1 и свои outbounds (теги с префиксом, чтобы не пересекались).
    static func pingBundle(_ items: [(id: String, raw: [String: Any])], ports: [Int]) -> (json: String, ports: [String: Int])? {
        var inbounds: [[String: Any]] = []
        var outbounds: [[String: Any]] = [["tag": "ping-block", "protocol": "blackhole"]]
        var rules: [[String: Any]] = []
        var map: [String: Int] = [:]
        let skipped: Set<String> = ["dns", "loopback"]
        for (index, item) in items.enumerated() where index < ports.count {
            guard let list = item.raw["outbounds"] as? [[String: Any]],
                  let main = RouteClassifier.mainOutbound(list) else { continue }
            let prefix = "p\(index)-"
            let mainTag = prefix + (main["tag"] as? String ?? "proxy")
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
                outbounds.append(o)
            }
            let inTag = "in\(index)"
            inbounds.append(["tag": inTag, "listen": "127.0.0.1", "port": ports[index], "protocol": "http",
                             "settings": [String: Any]()])
            rules.append(["type": "field", "inboundTag": [inTag], "outboundTag": mainTag])
            map[item.id] = ports[index]
        }
        guard !map.isEmpty else { return nil }
        let config: [String: Any] = [
            "log": ["loglevel": "none", "access": "none"],
            "inbounds": inbounds,
            "outbounds": outbounds,
            "routing": ["domainStrategy": "AsIs", "rules": rules],
        ]
        guard let text = json(config) else { return nil }
        return (text, map)
    }

    /// Адрес и порт основного сервера — для замера из расширения.
    static func pingTarget(id: String, raw: [String: Any], udp: Bool) -> PingTarget? {
        guard let list = raw["outbounds"] as? [[String: Any]], let main = RouteClassifier.mainOutbound(list) else { return nil }
        let host = RouteClassifier.address(main)
        let port = RouteClassifier.port(main)
        guard !host.isEmpty, port > 0 else { return nil }
        let stream = main["streamSettings"] as? [String: Any]
        let tls = (stream?["tlsSettings"] as? [String: Any]) ?? (stream?["realitySettings"] as? [String: Any])
        return PingTarget(id: id, host: host, port: port, udp: udp, sni: tls?["serverName"] as? String)
    }

    /// Куда отправлять «всегда через VPN»: балансировщик или основной outbound.
    static func proxyTarget(outbounds: [[String: Any]], rules: [[String: Any]]) -> [String: Any] {
        let matcherFree: Set<String> = ["type", "network", "outboundTag", "balancerTag", "ruleTag"]
        if let last = rules.last(where: { Set($0.keys).isSubset(of: matcherFree) }) {
            if let b = last["balancerTag"] as? String { return ["balancerTag": b] }
            if let o = last["outboundTag"] as? String, o != "direct", o != "block" { return ["outboundTag": o] }
        }
        if outbounds.contains(where: { ($0["tag"] as? String) == "proxy" }) { return ["outboundTag": "proxy"] }
        if let tag = RouteClassifier.mainOutbound(outbounds)?["tag"] as? String { return ["outboundTag": tag] }
        return ["outboundTag": "proxy"]
    }

    // MARK: - Очистка правил

    private static func filterGeo(_ list: [String]) -> [String] {
        list.filter { item in
            let lower = item.lowercased()
            let prefixes = ["geoip:", "geosite:", "ext:", "ext-ip:", "ext-domain:"]
            guard prefixes.contains(where: { lower.hasPrefix($0) }) else { return true }
            return availableGeo.contains(lower)
        }
    }

    static func sanitize(rule: [String: Any]) -> [String: Any]? {
        var r = rule
        for key in ["ip", "domain", "source"] {
            if let list = r[key] as? [String] {
                let filtered = filterGeo(list)
                if filtered.isEmpty && !list.isEmpty { return nil }
                r[key] = filtered
            }
        }
        return r
    }

    private static func sanitize(dnsServer: Any) -> Any? {
        guard var s = dnsServer as? [String: Any] else { return dnsServer }
        for key in ["domains", "expectIPs", "expectedIPs", "unexpectedIPs"] {
            if let list = s[key] as? [String] {
                let filtered = filterGeo(list)
                if filtered.isEmpty && !list.isEmpty { return nil }
                s[key] = filtered
            }
        }
        return s
    }

    /// «Российские сайты напрямую» выключено: убираем прямые маршруты для РФ,
    /// оставляем локальную сеть и DNS.
    static func stripRussianDirect(_ rule: [String: Any]) -> [String: Any]? {
        guard (rule["outboundTag"] as? String) == "direct" else { return rule }
        if rule["port"] != nil || rule["protocol"] != nil { return rule }
        var r = rule
        if let ips = r["ip"] as? [String] {
            let kept = ips.filter { $0.lowercased() != "geoip:ru" }
            if kept.isEmpty { return nil }
            r["ip"] = kept
        }
        if let domains = r["domain"] as? [String] {
            let kept = domains.filter { localDomains.contains($0.lowercased()) }
            if kept.isEmpty { return nil }
            r["domain"] = kept
        }
        return r
    }
}
