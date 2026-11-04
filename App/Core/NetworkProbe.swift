import Foundation

/// Определяет режим сети: доступны ли зарубежные сайты или только белый список.
enum NetworkProbe {
    private struct Target: Sendable {
        let name: String
        let url: String
        let domestic: Bool
    }

    private static let targets: [Target] = [
        Target(name: "ya.ru", url: "https://ya.ru/", domestic: true),
        Target(name: "vk.com", url: "https://vk.com/", domestic: true),
        Target(name: "google.com", url: "https://www.google.com/generate_204", domestic: false),
        Target(name: "cloudflare.com", url: "https://cp.cloudflare.com/generate_204", domestic: false),
    ]

    static func run() async -> [ProbeResult] {
        let results = await withTaskGroup(of: ProbeResult.self) { group -> [ProbeResult] in
            for t in targets {
                group.addTask { await probe(t) }
            }
            var out: [ProbeResult] = []
            for await r in group { out.append(r) }
            return out
        }
        return targets.compactMap { t in results.first { $0.id == t.name } }
    }

    private static func probe(_ t: Target) async -> ProbeResult {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 4
        cfg.timeoutIntervalForResource = 5
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: cfg)
        defer { session.finishTasksAndInvalidate() }
        var req = URLRequest(url: URL(string: t.url)!)
        req.httpMethod = "HEAD"
        let start = Date()
        do {
            _ = try await session.data(for: req)
            return ProbeResult(id: t.name, title: t.name, ms: Int(Date().timeIntervalSince(start) * 1000), isDomestic: t.domestic)
        } catch {
            return ProbeResult(id: t.name, title: t.name, ms: nil, isDomestic: t.domestic)
        }
    }

    static func classify(_ results: [ProbeResult]) -> NetworkMode {
        let domestic = results.contains { $0.isDomestic && $0.ms != nil }
        let foreign = results.contains { !$0.isDomestic && $0.ms != nil }
        if foreign { return .normal }
        if domestic { return .whitelist }
        return .offline
    }
}
