import Foundation
import LibXray

/// Обёртка над libXray (CGoInvoke, API v3). Используется и приложением (пинг, проверка
/// конфигурации), и расширением (запуск ядра).
enum XrayEngine {
    private static let queue = DispatchQueue(label: "com.secretclub.xray", qos: .userInitiated)

    static func invokeSync(_ method: String, payload: [String: Any]? = nil) throws -> Any? {
        var request: [String: Any] = ["apiVersion": 3, "method": method]
        if let payload { request["payload"] = payload }
        let data = try JSONSerialization.data(withJSONObject: request)
        let text = String(decoding: data, as: UTF8.self)
        let response: String = text.withCString { ptr -> String in
            guard let input = strdup(ptr) else { return "" }
            defer { free(input) }
            guard let out = CGoInvoke(input) else { return "" }
            defer { CGoFree(out) }
            return String(cString: out)
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(response.utf8))) as? [String: Any] else {
            throw XrayError(message: "ядро вернуло некорректный ответ")
        }
        if obj["success"] as? Bool == true { return obj["data"] }
        let message = (obj["error"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "неизвестная ошибка ядра"
        throw XrayError(message: message)
    }

    static func call(_ method: String, payload: [String: Any]? = nil) async throws -> Any? {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Any?, Error>) in
            queue.async {
                do {
                    cont.resume(returning: try invokeSync(method, payload: payload))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    static var version: String {
        let data = (try? invokeSync("xrayVersion")) as? [String: Any]
        return data?["version"] as? String ?? "?"
    }

    static var isRunning: Bool {
        let data = (try? invokeSync("getXrayState")) as? [String: Any]
        return data?["running"] as? Bool ?? false
    }

    static func freePort() -> Int? { freePorts(1).first }

    static func freePorts(_ count: Int) -> [Int] {
        guard count > 0 else { return [] }
        let data = (try? invokeSync("getFreePorts", payload: ["count": count])) as? [String: Any]
        return (data?["ports"] as? [NSNumber])?.map(\.intValue) ?? []
    }

    /// Счётчик статистики запущенного ядра (наша сборка libXray, SecretClubCounter).
    /// nil — ядро не запущено или такого счётчика нет.
    static func counter(_ name: String) -> Int64? {
        let value: Int64 = name.withCString { ptr -> Int64 in
            guard let input = strdup(ptr) else { return -1 }
            defer { free(input) }
            return Int64(SecretClubCounter(input))
        }
        return value >= 0 ? value : nil
    }

    /// Направить трафик балансировщика на outbound с этим тегом (наша сборка libXray).
    /// Смена сервера без перезапуска ядра: соединения через прежний сервер доживают своё, новые идут через новый.
    static func setBalancerTarget(_ balancer: String, _ target: String) -> Bool {
        balancer.withCString { b in
            target.withCString { t in
                guard let bb = strdup(b) else { return false }
                defer { free(bb) }
                guard let tt = strdup(t) else { return false }
                defer { free(tt) }
                return SecretClubSetBalancerTarget(bb, tt) == 1
            }
        }
    }

    static func runSync(_ config: String) throws {
        _ = try invokeSync("runXray", payload: ["xrayJson": config])
    }

    static func stopSync() {
        _ = try? invokeSync("stopXray")
    }

    static func test(_ config: String) async throws {
        _ = try await call("testXray", payload: ["xrayJson": config])
    }

    /// Реальная задержка через сервер: HEAD-запрос через outbound. До 5 конфигов за раз.
    /// Возвращает мс или nil, если сервер не ответил. Нельзя вызывать, пока ядро запущено в этом процессе.
    static func pingChunk(_ items: [(json: String, tag: String)], timeout: Int = 4,
                          url: String = "https://www.gstatic.com/generate_204") async -> [Int?] {
        guard !items.isEmpty else { return [] }
        let list: [[String: String]] = items.prefix(5).map { ["xrayJson": $0.json, "outboundTag": $0.tag] }
        let payload: [String: Any] = ["configs": list, "timeout": timeout, "url": url]
        guard let data = (try? await call("pingBatch", payload: payload)) as? [String: Any],
              let results = data["results"] as? [[String: Any]], results.count == list.count else {
            return Array(repeating: nil, count: list.count)
        }
        return results.map { item -> Int? in
            guard item["success"] as? Bool == true, let delay = (item["delay"] as? NSNumber)?.intValue,
                  delay < 10000 else { return nil }
            return max(1, delay)
        }
    }
}
