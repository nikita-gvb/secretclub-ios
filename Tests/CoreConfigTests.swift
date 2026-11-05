import XCTest

final class CoreConfigTests: XCTestCase {
    /// Конфиг сервера как из подписки: proxy первым, direct/block, правило для .ru и DNS.
    private func server(_ host: String, extraRules: [[String: Any]] = [], first: String = "proxy",
                        balancers: [[String: Any]]? = nil) -> String {
        var outbounds: [[String: Any]] = [
            ["tag": "proxy", "protocol": "vless",
             "settings": ["vnext": [["address": host, "port": 443, "users": [["id": "00000000-0000-0000-0000-000000000000"]]]]],
             "streamSettings": ["network": "tcp", "sockopt": ["dialerProxy": "frag"]]],
            ["tag": "frag", "protocol": "freedom"],
            ["tag": "direct", "protocol": "freedom"],
            ["tag": "block", "protocol": "blackhole"],
            ["tag": "dns-out", "protocol": "dns"],
        ]
        if first != "proxy", let index = outbounds.firstIndex(where: { ($0["tag"] as? String) == first }) {
            outbounds.insert(outbounds.remove(at: index), at: 0)
        }
        var routing: [String: Any] = [
            "domainStrategy": "AsIs",
            "rules": [
                ["type": "field", "domain": ["domain:ru"], "outboundTag": "direct"],
                ["type": "field", "port": "53", "outboundTag": "dns-out"],
                ["type": "field", "network": "udp", "port": "443", "outboundTag": "proxy"],
            ] + extraRules,
        ]
        if let balancers { routing["balancers"] = balancers }
        let root: [String: Any] = [
            "inbounds": [["tag": "tun-in", "protocol": "tun", "settings": [String: Any]()]],
            "outbounds": outbounds,
            "routing": routing,
            "observatory": ["subjectSelector": ["proxy"]],
        ]
        return CoreConfig.text(root)!
    }

    private func rules(_ text: String) -> [[String: Any]] {
        (CoreConfig.object(text)?["routing"] as? [String: Any])?["rules"] as? [[String: Any]] ?? []
    }

    private func inbounds(_ text: String) -> [[String: Any]] {
        CoreConfig.object(text)?["inbounds"] as? [[String: Any]] ?? []
    }

    func testHotComposeRoutesMainTrafficThroughBalancer() throws {
        let built = try CoreConfig.compose(active: server("a.example"), fd: 7, assetDir: "/geo", healthPort: 1000,
                                           extras: [("B", server("b.example")), ("C", server("c.example"))],
                                           ports: [2001, 2002, 2003], activeID: "A", hot: true)
        XCTAssertTrue(built.hot)
        XCTAssertTrue(built.balanced)
        XCTAssertEqual(built.main, "proxy")
        XCTAssertEqual(built.tags, ["A": "proxy", "B": "c0-proxy", "C": "c1-proxy"])
        XCTAssertEqual(built.ports, ["B": 2001, "C": 2002, "A": 2003])

        let root = try XCTUnwrap(CoreConfig.object(built.text))
        let env = try XCTUnwrap(root["env"] as? [String: String])
        XCTAssertEqual(env["xray.tun.fd"], "7")
        XCTAssertEqual(env["xray.location.asset"], "/geo")
        XCTAssertNil(root["observatory"], "наблюдатель не нужен: стратегия random без fallback")

        let routing = try XCTUnwrap(root["routing"] as? [String: Any])
        let balancers = try XCTUnwrap(routing["balancers"] as? [[String: Any]])
        XCTAssertEqual(balancers.count, 1)
        XCTAssertEqual(balancers[0]["tag"] as? String, CoreConfig.routeBalancer)
        XCTAssertEqual(balancers[0]["selector"] as? [String], ["proxy"])
        XCTAssertNil(balancers[0]["fallbackTag"])

        let list = rules(built.text)
        // Никакое правило больше не ведёт прямо в proxy — только через балансировщик.
        XCTAssertFalse(list.contains { ($0["outboundTag"] as? String) == "proxy" && $0["inboundTag"] == nil })
        XCTAssertTrue(list.contains { ($0["port"] as? String) == "443" && ($0["balancerTag"] as? String) == CoreConfig.routeBalancer })
        // Служебные правила не тронуты.
        XCTAssertTrue(list.contains { ($0["outboundTag"] as? String) == "direct" })
        XCTAssertTrue(list.contains { ($0["outboundTag"] as? String) == "dns-out" })
        // Последнее правило — «всё остальное через балансировщик».
        let last = try XCTUnwrap(list.last)
        XCTAssertEqual(last["network"] as? String, "tcp,udp")
        XCTAssertEqual(last["balancerTag"] as? String, CoreConfig.routeBalancer)
        // Проверочные входы: health-in через балансировщик, у каждого сервера свой.
        XCTAssertTrue(list.contains { ($0["inboundTag"] as? [String]) == [CoreConfig.healthTag] && ($0["balancerTag"] as? String) == CoreConfig.routeBalancer })
        XCTAssertTrue(list.contains { ($0["inboundTag"] as? [String]) == ["hc0"] && ($0["outboundTag"] as? String) == "c0-proxy" })
        XCTAssertTrue(list.contains { ($0["inboundTag"] as? [String]) == [CoreConfig.mainProbeTag] && ($0["outboundTag"] as? String) == "proxy" })

        let ports = inbounds(built.text).compactMap { $0["port"] as? Int }
        XCTAssertEqual(Set(ports), [1000, 2001, 2002, 2003])

        // Запасные со своими префиксами, включая dialerProxy.
        let outbounds = try XCTUnwrap(root["outbounds"] as? [[String: Any]])
        let c0 = try XCTUnwrap(outbounds.first { ($0["tag"] as? String) == "c0-proxy" })
        let sock = ((c0["streamSettings"] as? [String: Any])?["sockopt"] as? [String: Any])
        XCTAssertEqual(sock?["dialerProxy"] as? String, "c0-frag")
        XCTAssertFalse(outbounds.contains { ($0["tag"] as? String) == "c0-dns-out" }, "dns-outbound запасных не нужен")
    }

    func testColdComposeKeepsOriginalRouting() throws {
        let built = try CoreConfig.compose(active: server("a.example"), fd: 3, assetDir: nil, healthPort: 1000,
                                           extras: [("B", server("b.example"))], ports: [2001, 2002], activeID: "A", hot: false)
        XCTAssertFalse(built.hot)
        XCTAssertFalse(built.balanced)
        XCTAssertTrue(built.tags.isEmpty)
        XCTAssertEqual(built.ports, ["B": 2001])
        let routing = CoreConfig.object(built.text)?["routing"] as? [String: Any]
        XCTAssertNil(routing?["balancers"])
        XCTAssertTrue(rules(built.text).contains { ($0["port"] as? String) == "443" && ($0["outboundTag"] as? String) == "proxy" })
        XCTAssertFalse(inbounds(built.text).contains { ($0["tag"] as? String) == CoreConfig.mainProbeTag })
    }

    func testOwnBalancerDisablesHotMode() throws {
        let config = server("a.example", balancers: [["tag": "auto", "selector": ["proxy"]]])
        let built = try CoreConfig.compose(active: config, fd: 3, assetDir: nil, healthPort: 1000,
                                           extras: [("B", server("b.example"))], ports: [2001, 2002], activeID: "A", hot: true)
        XCTAssertFalse(built.hot)
        XCTAssertFalse(built.balanced)
        let root = try XCTUnwrap(CoreConfig.object(built.text))
        XCTAssertNotNil(root["observatory"], "свой балансировщик сервера может опираться на наблюдатель")
        let balancers = (root["routing"] as? [String: Any])?["balancers"] as? [[String: Any]]
        XCTAssertEqual(balancers?.count, 1)
        XCTAssertEqual(balancers?.first?["tag"] as? String, "auto")
    }

    func testNoCatchAllWhenDefaultOutboundIsNotProxy() throws {
        let config = server("a.example", first: "direct")
        let built = try CoreConfig.compose(active: config, fd: 3, assetDir: nil, healthPort: 1000,
                                           extras: [("B", server("b.example"))], ports: [2001, 2002], activeID: "A", hot: true)
        XCTAssertTrue(built.hot)
        XCTAssertFalse(rules(built.text).contains { ($0["network"] as? String) == "tcp,udp" },
                       "трафик без правила по-прежнему идёт в первый outbound (direct)")
    }

    func testSingleServerHasNoExtras() throws {
        let built = try CoreConfig.compose(active: server("a.example"), fd: 3, assetDir: nil, healthPort: 1000,
                                           extras: [], ports: [], activeID: "A", hot: true)
        XCTAssertFalse(built.hot)
        XCTAssertTrue(built.ports.isEmpty)
        let root = try XCTUnwrap(CoreConfig.object(built.text))
        let system = (root["policy"] as? [String: Any])?["system"] as? [String: Bool]
        XCTAssertEqual(system?["statsInboundUplink"], true)
        XCTAssertEqual(system?["statsOutboundDownlink"], true)
        XCTAssertNotNil(root["stats"])
        XCTAssertTrue(inbounds(built.text).contains { ($0["tag"] as? String) == CoreConfig.healthTag && ($0["port"] as? Int) == 1000 })
    }

    func testInvalidConfigThrows() {
        XCTAssertThrowsError(try CoreConfig.compose(active: "not json", fd: 3, assetDir: nil, healthPort: 1,
                                                    extras: [], ports: []))
    }

    func testCounterNames() throws {
        let names = try XCTUnwrap(CoreConfig.counterNames(server("a.example")))
        XCTAssertEqual(names.up, "inbound>>>tun-in>>>traffic>>>uplink")
        XCTAssertEqual(names.down, "inbound>>>tun-in>>>traffic>>>downlink")
        XCTAssertEqual(names.server, "outbound>>>proxy>>>traffic>>>downlink")
        XCTAssertNil(CoreConfig.counterNames(#"{"inbounds":[]}"#))
    }

    func testMainOutboundSkipsServiceProtocols() {
        let list: [[String: Any]] = [["tag": "direct", "protocol": "freedom"], ["tag": "x", "protocol": "hysteria2"]]
        XCTAssertEqual(CoreConfig.mainOutbound(list)?["tag"] as? String, "x")
    }

    func testDNSProbeInboundGoesToDNSOutbound() throws {
        let built = try CoreConfig.compose(active: server("a.example"), fd: 3, assetDir: nil, healthPort: 1000,
                                           extras: [("B", server("b.example"))], ports: [2001, 2002],
                                           activeID: "A", hot: true, dnsPort: 3000)
        XCTAssertTrue(built.dns)
        XCTAssertTrue(built.hot)
        let probe = try XCTUnwrap(inbounds(built.text).first { ($0["tag"] as? String) == CoreConfig.dnsProbeTag })
        XCTAssertEqual(probe["port"] as? Int, 3000)
        XCTAssertEqual(probe["listen"] as? String, "127.0.0.1")
        XCTAssertEqual(probe["protocol"] as? String, "dokodemo-door")
        XCTAssertEqual((probe["settings"] as? [String: Any])?["network"] as? String, "udp")
        let first = try XCTUnwrap(rules(built.text).first)
        XCTAssertEqual(first["inboundTag"] as? [String], [CoreConfig.dnsProbeTag])
        XCTAssertEqual(first["outboundTag"] as? String, "dns-out")
    }

    func testNoDNSProbeWithoutPortOrDNSOutbound() throws {
        let plain = try CoreConfig.compose(active: server("a.example"), fd: 3, assetDir: nil, healthPort: 1000,
                                           extras: [], ports: [])
        XCTAssertFalse(plain.dns)
        XCTAssertFalse(inbounds(plain.text).contains { ($0["tag"] as? String) == CoreConfig.dnsProbeTag })
        let noDNS = CoreConfig.text(["outbounds": [["tag": "proxy", "protocol": "vless"]]])!
        let built = try CoreConfig.compose(active: noDNS, fd: 3, assetDir: nil, healthPort: 1000, extras: [], ports: [], dnsPort: 3000)
        XCTAssertFalse(built.dns)
    }

    func testDNSProbePacket() {
        let q = DNSProbe.query(name: "sc-x.google.com", id: 0x1234)
        XCTAssertEqual(Array(q.prefix(4)), [0x12, 0x34, 0x01, 0x00])
        XCTAssertEqual(q.count, 12 + (1 + 4) + (1 + 6) + (1 + 3) + 1 + 4)
        XCTAssertEqual(Array(q.suffix(5)), [0x00, 0x00, 0x01, 0x00, 0x01])
        XCTAssertFalse(DNSProbe.isResponse(q, id: 0x1234), "сам запрос — не ответ")
        var answer = q
        answer[2] |= 0x80
        answer[3] = 0x83
        XCTAssertTrue(DNSProbe.isResponse(answer, id: 0x1234), "«такого имени нет» — тоже ответ")
        XCTAssertFalse(DNSProbe.isResponse(answer, id: 0x4321))
        XCTAssertTrue(DNSProbe.randomName().hasSuffix(".google.com"))
        XCTAssertNotEqual(DNSProbe.randomName(), DNSProbe.randomName())
    }
}
