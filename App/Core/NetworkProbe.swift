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
        if t.domestic { req.httpMethod = "HEAD" }
        let start = Date()
        do {
            let (_, response) = try await session.data(for: req)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            // Зарубежная проверка — только настоящий 204: заглушка провайдера или портал входа не считаются.
            let ok = t.domestic ? (code > 0 && code < 500) : code == 204
            return ProbeResult(id: t.name, title: t.name, ms: ok ? Int(Date().timeIntervalSince(start) * 1000) : nil, isDomestic: t.domestic)
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

struct TraceResult {
    let ip: String
    let location: String?
    let ms: Int
}

extension NetworkProbe {
    /// Через какой IP и страну сейчас выходит трафик (Cloudflare trace).
    static func trace() async -> TraceResult? {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 8
        cfg.timeoutIntervalForResource = 10
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: cfg)
        defer { session.finishTasksAndInvalidate() }
        let start = Date()
        guard let url = URL(string: "https://www.cloudflare.com/cdn-cgi/trace"),
              let (data, _) = try? await session.data(from: url),
              let text = String(data: data, encoding: .utf8) else { return nil }
        var fields: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let kv = line.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { fields[kv[0]] = kv[1] }
        }
        guard let ip = fields["ip"] else { return nil }
        let loc = fields["loc"].flatMap { code -> String? in
            guard code.count == 2 else { return nil }
            return "\(code.flagEmoji) \(Locale(identifier: "ru_RU").localizedString(forRegionCode: code) ?? code)"
        }
        return TraceResult(ip: ip, location: loc, ms: Int(Date().timeIntervalSince(start) * 1000))
    }
}
