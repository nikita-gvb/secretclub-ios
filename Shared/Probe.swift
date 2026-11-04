import Foundation
import Network
import Security

/// Продолжение, которое можно безопасно «возобновить» несколько раз (срабатывает первое).
final class ResumeOnce<T>: @unchecked Sendable {
    private var continuation: CheckedContinuation<T, Never>?
    private let lock = NSLock()
    init(_ continuation: CheckedContinuation<T, Never>) { self.continuation = continuation }
    func resume(_ value: T) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(returning: value)
    }
}

/// Простое соединение на NWConnection с общим дедлайном: по его истечении
/// соединение закрывается и все ожидающие операции завершаются неудачей.
final class ProbeConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.secretclub.probe")

    init?(host: String, port: Int, parameters: NWParameters) {
        guard let p = NWEndpoint.Port(rawValue: UInt16(clamping: port)), port > 0 else { return nil }
        connection = NWConnection(host: NWEndpoint.Host(host), port: p, using: parameters)
    }

    /// Открывает соединение. false — не удалось (отказ, нет маршрута, таймаут).
    func open(timeout: Double) async -> Bool {
        queue.asyncAfter(deadline: .now() + timeout) { [connection] in connection.cancel() }
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let once = ResumeOnce(cont)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: once.resume(true)
                case .failed, .cancelled, .waiting: once.resume(false)
                default: break
                }
            }
            connection.start(queue: queue)
        }
    }

    func close() {
        connection.stateUpdateHandler = nil
        connection.cancel()
    }

    func send(_ text: String) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            connection.send(content: Data(text.utf8), completion: .contentProcessed { error in
                cont.resume(returning: error == nil)
            })
        }
    }

    private func receiveChunk() async -> Data? {
        await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, _ in
                if let data, !data.isEmpty { cont.resume(returning: data) } else { cont.resume(returning: nil) }
            }
        }
    }

    /// Читает HTTP-ответ целиком (заголовки и тело по Content-Length), возвращает заголовки.
    func readHTTPHead() async -> String? {
        var buffer = Data()
        let separator = Data("\r\n\r\n".utf8)
        while true {
            guard let chunk = await receiveChunk() else { return nil }
            buffer.append(chunk)
            if let range = buffer.range(of: separator) {
                let head = String(decoding: buffer[buffer.startIndex..<range.lowerBound], as: UTF8.self)
                var remaining = Self.contentLength(head) - (buffer.endIndex - range.upperBound)
                while remaining > 0 {
                    guard let more = await receiveChunk() else { return nil }
                    remaining -= more.count
                }
                return head
            }
            if buffer.count > 65536 { return nil }
        }
    }

    static func contentLength(_ head: String) -> Int {
        for line in head.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                return Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        return 0
    }
}

enum LatencyProbe {
    static func elapsedMS(since start: DispatchTime) -> Int {
        max(1, Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000))
    }

    /// Время установки TCP-соединения с сервером.
    static func tcp(host: String, port: Int, timeout: Double) async -> Int? {
        guard let c = ProbeConnection(host: host, port: port, parameters: .tcp) else { return nil }
        defer { c.close() }
        let start = DispatchTime.now()
        guard await c.open(timeout: timeout) else { return nil }
        return elapsedMS(since: start)
    }

    /// Время QUIC-рукопожатия (Hysteria2 отвечает как обычный HTTP/3-сервер).
    static func quic(host: String, port: Int, sni: String?, timeout: Double) async -> Int? {
        let options = NWProtocolQUIC.Options(alpn: ["h3"])
        let security = options.securityProtocolOptions
        sec_protocol_options_set_verify_block(security, { _, _, complete in complete(true) }, DispatchQueue.global())
        if let sni, !sni.isEmpty { sec_protocol_options_set_tls_server_name(security, sni) }
        guard let c = ProbeConnection(host: host, port: port, parameters: NWParameters(quic: options)) else { return nil }
        defer { c.close() }
        let start = DispatchTime.now()
        guard await c.open(timeout: timeout) else { return nil }
        return elapsedMS(since: start)
    }

    /// Замер до самих серверов, параллельно. Используется расширением, пока VPN включён.
    static func direct(_ targets: [PingTarget], timeout: Double = 3) async -> [String: Int] {
        await withTaskGroup(of: (String, Int?).self) { group -> [String: Int] in
            for t in targets {
                group.addTask {
                    let ms: Int?
                    if t.udp {
                        ms = await quic(host: t.host, port: t.port, sni: t.sni, timeout: timeout)
                    } else {
                        ms = await tcp(host: t.host, port: t.port, timeout: timeout)
                    }
                    return (t.id, ms)
                }
            }
            var out: [String: Int] = [:]
            for await (id, ms) in group { if let ms { out[id] = ms } }
            return out
        }
    }

    /// Задержка через локальный HTTP-вход Xray: CONNECT, первый запрос (рукопожатие с сервером)
    /// и второй по уже открытому туннелю — он и есть «пинг». nil — сервер не ответил.
    static func viaProxy(port: Int, timeout: Double = 5) async -> Int? {
        guard let c = ProbeConnection(host: "127.0.0.1", port: port, parameters: .tcp) else { return nil }
        defer { c.close() }
        let host = "www.gstatic.com"
        guard await c.open(timeout: timeout),
              await c.send("CONNECT \(host):80 HTTP/1.1\r\nHost: \(host):80\r\n\r\n"),
              let connected = await c.readHTTPHead(), isOK(connected) else { return nil }
        let request = "GET /generate_204 HTTP/1.1\r\nHost: \(host)\r\nUser-Agent: SecretClub\r\nAccept: */*\r\nConnection: keep-alive\r\n\r\n"
        let first = DispatchTime.now()
        guard await c.send(request), let r1 = await c.readHTTPHead(), r1.hasPrefix("HTTP/") else { return nil }
        let firstMS = elapsedMS(since: first)
        let second = DispatchTime.now()
        guard await c.send(request), let r2 = await c.readHTTPHead(), r2.hasPrefix("HTTP/") else { return firstMS }
        return elapsedMS(since: second)
    }

    private static func isOK(_ head: String) -> Bool {
        let status = head.split(separator: " ").dropFirst().first
        return status == "200"
    }
}
