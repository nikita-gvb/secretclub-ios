import XCTest

final class SharedModelTests: XCTestCase {
    func testSplitTitle() {
        XCTAssertEqual(SharedStatus.split("🇩🇪 Германия").flag, "🇩🇪")
        XCTAssertEqual(SharedStatus.split("🇩🇪 Германия").name, "Германия")
        XCTAssertEqual(SharedStatus.split("🌍 Авто-выбор").flag, "🌍")
        XCTAssertNil(SharedStatus.split("Обход БС").flag)
        XCTAssertEqual(SharedStatus.split("Обход БС").name, "Обход БС")
        XCTAssertNil(SharedStatus.split(nil).name)
        XCTAssertNil(SharedStatus.split("  ").name)
    }

    func testSharedStatusSameIgnoresTimestamp() {
        var a = SharedStatus()
        a.running = true
        a.routeTitle = "🇫🇮 Финляндия"
        var b = a
        b.updatedAt = a.updatedAt.addingTimeInterval(30)
        XCTAssertTrue(a.same(as: b))
        b.pingMS = 40
        XCTAssertFalse(a.same(as: b))
        XCTAssertFalse(a.same(as: nil))
    }

    func testReportRoundTrip() throws {
        var report = TunnelReport()
        report.running = true
        report.routeID = "fi"
        report.hot = true
        report.logTail = "2025-01-01 10:00:00 запуск\n"
        report.incidents = [Incident(id: "tunnel-1", date: Date(timeIntervalSince1970: 1000), source: .tunnel,
                                     title: "VPN завершился аварийно", detail: "память до 48 МБ")]
        let data = try XCTUnwrap(TunnelCoding.encode(report))
        XCTAssertEqual(TunnelCoding.decode(TunnelReport.self, data), report)
        // Старое расширение (без новых полей) тоже читается.
        let old = #"{"probe":false,"running":true,"coreVersion":"25.1","uplink":1,"downlink":2,"checking":false,"noteID":3}"#
        let decoded = try XCTUnwrap(TunnelCoding.decode(TunnelReport.self, Data(old.utf8)))
        XCTAssertNil(decoded.hot)
        XCTAssertEqual(decoded.noteID, 3)
    }

    func testCommandKindsDecode() throws {
        let data = try XCTUnwrap(TunnelCoding.encode(TunnelCommand(kind: .log)))
        XCTAssertEqual(TunnelCoding.decode(TunnelCommand.self, data)?.kind, .log)
    }

    func testDiverseTakesTwoPerGroup() {
        func c(_ id: String, _ group: String) -> AutoCandidate { AutoCandidate(id: id, title: id, group: group, config: "{}") }
        let ranked = [c("r1", "regular"), c("r2", "regular"), c("r3", "regular"), c("b1", "bridge"), c("b2", "bridge"), c("s1", "reserve")]
        XCTAssertEqual(AutoPool.diverse(ranked).map(\.id), ["r1", "r2", "b1", "b2"])
        XCTAssertEqual(AutoPool.diverse([c("b1", "bridge"), c("s1", "reserve")]).map(\.id), ["b1", "s1"])
    }

    func testGroupOrder() {
        XCTAssertEqual(AutoPool.order(for: .whitelist), ["bridge", "reserve"])
        XCTAssertLessThan(AutoPool.rank("regular"), AutoPool.rank("bridge"))
        XCTAssertLessThan(AutoPool.rank("bridge"), AutoPool.rank("reserve"))
        XCTAssertEqual(AutoPool.rank("unknown"), AutoPool.priority.count)
    }
}
