import XCTest

final class DiagLogTests: XCTestCase {
    override func setUp() {
        super.setUp()
        DiagLog.clear()
        Incidents.clear()
    }

    func testWriteAndRead() {
        DiagLog.write("первая строка", to: .app)
        DiagLog.warn("что-то пошло не так\nвторая часть", to: .app)
        DiagLog.flush()
        let text = DiagLog.read(.app)
        let lines = text.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasSuffix("первая строка"))
        XCTAssertTrue(lines[1].contains("⚠︎ что-то пошло не так · вторая часть"), "перевод строки не ломает журнал")
        XCTAssertTrue(DiagLog.read(.tunnel).isEmpty)
    }

    func testRotationKeepsTailWithinLimit() throws {
        let chunk = String(repeating: "x", count: 1000)
        for index in 0..<450 { DiagLog.write("\(index) \(chunk)", to: .tunnel) }
        DiagLog.flush()
        let old = try XCTUnwrap(DiagLog.url(.tunnel, old: true))
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path), "после предела текущий файл уходит в .1")
        let full = DiagLog.read(.tunnel, maxBytes: 10_000_000)
        XCTAssertTrue(full.hasSuffix("449 \(chunk)\n"))
        XCTAssertLessThanOrEqual(full.utf8.count, 2 * DiagLog.limit + 4000)
        let tail = DiagLog.read(.tunnel, maxBytes: 5000)
        XCTAssertLessThanOrEqual(tail.utf8.count, 5000)
        XCTAssertTrue(tail.hasPrefix("20"), "хвост начинается с целой строки (с даты)")
    }

    func testIncidentsDeduplicateAndSort() {
        let a = Incident(id: "a", date: Date(timeIntervalSinceNow: -100), source: .app, title: "Сбой", detail: "")
        let b = Incident(id: "b", date: Date(), source: .tunnel, title: "VPN", detail: "")
        XCTAssertTrue(Incidents.add(a))
        XCTAssertFalse(Incidents.add(a), "MetricKit присылает старые отчёты повторно")
        XCTAssertTrue(Incidents.add(b))
        XCTAssertEqual(Incidents.all().map(\.id), ["b", "a"])
        XCTAssertEqual(Incidents.recent(days: 1).count, 2)
        Incidents.clear()
        XCTAssertTrue(Incidents.all().isEmpty)
    }

    func testTunnelSessionMarker() {
        TunnelSession.end()
        XCTAssertNil(TunnelSession.load())
        TunnelSession.save(TunnelSession.State(started: Date(), alive: Date(), peakMB: 31.5, route: "🇫🇮 Финляндия", version: "25"))
        XCTAssertEqual(TunnelSession.load()?.peakMB, 31.5)
        TunnelSession.end()
        XCTAssertNil(TunnelSession.load())
    }
}
