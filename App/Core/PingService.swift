import Foundation

/// Пинг серверов из приложения, пока VPN выключен: поднимаем своё ядро Xray с отдельным
/// HTTP-входом на каждый сервер и меряем все параллельно. Результат приходит по мере готовности.
enum PingService {
    static let concurrency = 8

    /// false — ядро не запустилось с общим конфигом (тогда вызывающий пробует запасной способ).
    static func run(_ items: [(id: String, raw: [String: Any])],
                    update: @escaping @MainActor (String, Int?) -> Void) async -> Bool {
        guard !items.isEmpty else { return true }
        let ports = await freePorts(items.count)
        guard ports.count == items.count,
              let bundle = ConfigBuilder.pingBundle(items, ports: ports) else { return false }
        _ = try? await XrayEngine.call("stopXray")
        do {
            _ = try await XrayEngine.call("runXray", payload: ["xrayJson": bundle.json])
        } catch {
            return false
        }
        // Даём ядру открыть порты.
        try? await Task.sleep(for: .milliseconds(150))
        let order = items.map { $0.id }.compactMap { id in bundle.ports[id].map { (id, $0) } }
        await withTaskGroup(of: Void.self) { group in
            var pending = order.makeIterator()
            for _ in 0..<min(concurrency, order.count) {
                guard let item = pending.next() else { break }
                group.addTask {
                    let ms = await LatencyProbe.viaProxy(port: item.1)
                    await update(item.0, ms)
                }
            }
            while await group.next() != nil {
                guard let item = pending.next() else { continue }
                group.addTask {
                    let ms = await LatencyProbe.viaProxy(port: item.1)
                    await update(item.0, ms)
                }
            }
        }
        _ = try? await XrayEngine.call("stopXray")
        return true
    }

    private static func freePorts(_ count: Int) async -> [Int] {
        guard let data = (try? await XrayEngine.call("getFreePorts", payload: ["count": count])) as? [String: Any],
              let ports = data["ports"] as? [NSNumber] else { return [] }
        return ports.map(\.intValue)
    }
}
