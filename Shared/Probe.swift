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

/// Простое соединение на NWConnection с общим дедлайном: по его истечении (или при отмене задачи)
/// соединение закрывается и все ожидающие операции сразу завершаются неудачей.
final class ProbeConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.secretclub.probe")
    private let lock = NSLock()
    private var closed = false
    private var progress = 0

    init?(host: String, port: Int, parameters: NWParameters) {
        guard let p = NWEndpoint.Port(rawValue: UInt16(clamping: port)), port > 0 else { return nil }
        connection = NWConnection(host: NWEndpoint.Host(host), port: p, using: parameters)
    }

    private var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    /// Открывает соединение. false — не удалось (отказ, нет маршрута, таймаут, отмена).
    func open(timeout: Double) async -> Bool {
        if isClosed { return false }
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.close() }
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
            if isClosed { once.resume(false) }
        }
    }

    /// Закрыть соединение, если за seconds не будет нового вызова armIdle (данные перестали идти).
    func armIdle(_ seconds: Double) {
        lock.lock()
        progress += 1
        let mark = progress
        lock.unlock()
        queue.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let same = self.progress == mark
            self.lock.unlock()
            if same { self.close() }
        }
    }

    /// Можно вызывать сколько угодно раз и с любого потока.
    func close() {
        lock.lock()
        closed = true
        lock.unlock()
        connection.cancel()
    }

    func send(_ text: String) async -> Bool { await send(data: Data(text.utf8)) }

    func send(data: Data) async -> Bool {
        if isClosed { return false }
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            connection.send(content: data, completion: .contentProcessed { error in
                cont.resume(returning: error == nil)
            })
        }
    }

    func receiveChunk() async -> Data? {
        if isClosed { return nil }
        return await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                if let data, !data.isEmpty { cont.resume(returning: data) } else { cont.resume(returning: nil) }
            }
        }
    }

    /// Читает HTTP-ответ целиком (заголовки и тело по Content-Length), возвращает заголовки.
    func readHTTPHead() async -> String? {
        guard let start = await readHead() else { return nil }
        let head = start.0
        var remaining = Self.contentLength(head) - start.1
        while remaining > 0 {
            guard let more = await receiveChunk() else { return nil }
            remaining -= more.count
        }
        return head
    }

    /// Заголовки ответа и сколько байт тела уже пришло вместе с ними.
    func readHead() async -> (String, Int)? {
        var buffer = Data()
        let separator = Data("\r\n\r\n".utf8)
        while true {
            guard let chunk = await receiveChunk() else { return nil }
            buffer.append(chunk)
            if let range = buffer.range(of: separator) {
                let head = String(decoding: buffer[buffer.startIndex..<range.lowerBound], as: UTF8.self)
                return (head, buffer.endIndex - range.upperBound)
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

    /// Код ответа: «HTTP/1.1 204 No Content» → 204.
    static func status(_ head: String) -> Int? {
        guard head.hasPrefix("HTTP/") else { return nil }
        let parts = head.split(separator: " ", maxSplits: 2)
        return parts.count >= 2 ? Int(parts[1]) : nil
    }
}

/// Итог проверки «большим» запросом через сервер.
enum PayloadVerdict: Equatable {
    /// Скачали целиком; скорость, КБ/с.
    case ok(Int)
    /// Соединение «замерло» после стольких байт — похоже на блокировку по объёму (~16 КБ).
    case stalled(Int)
    /// Проверочный сайт не ответил как надо — по этому замеру ничего сказать нельзя.
    case inconclusive
}

enum LatencyProbe {
    static func elapsedMS(since start: DispatchTime) -> Int {
        max(1, Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000))
    }

    /// Выполняет body, закрывая соединение при отмене задачи (ранний выход из параллельных замеров).
    static func using<T>(_ c: ProbeConnection, _ body: () async -> T) async -> T {
        await withTaskCancellationHandler {
            let result = await body()
            c.close()
            return result
        } onCancel: {
            c.close()
        }
    }

    /// Время установки TCP-соединения с сервером.
    static func tcp(host: String, port: Int, timeout: Double) async -> Int? {
        guard let c = ProbeConnection(host: host, port: port, parameters: .tcp) else { return nil }
        return await using(c) {
            let start = DispatchTime.now()
            guard await c.open(timeout: timeout) else { return nil }
            return elapsedMS(since: start)
        }
    }

    /// Время QUIC-рукопожатия (Hysteria2 отвечает как обычный HTTP/3-сервер).
    static func quic(host: String, port: Int, sni: String?, timeout: Double) async -> Int? {
        let options = NWProtocolQUIC.Options(alpn: ["h3"])
        let security = options.securityProtocolOptions
        sec_protocol_options_set_verify_block(security, { _, _, complete in complete(true) }, DispatchQueue.global())
        if let sni, !sni.isEmpty { sec_protocol_options_set_tls_server_name(security, sni) }
        guard let c = ProbeConnection(host: host, port: port, parameters: NWParameters(quic: options)) else { return nil }
        return await using(c) {
            let start = DispatchTime.now()
            guard await c.open(timeout: timeout) else { return nil }
            return elapsedMS(since: start)
        }
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
    /// Ответ должен быть именно 204: так заглушка провайдера или чужая страница не сойдут за «работает».
    static func viaProxy(port: Int, timeout: Double = 5) async -> Int? {
        guard let c = ProbeConnection(host: "127.0.0.1", port: port, parameters: .tcp) else { return nil }
        return await using(c) {
            let host = "www.gstatic.com"
            guard await c.open(timeout: timeout),
                  await c.send("CONNECT \(host):80 HTTP/1.1\r\nHost: \(host):80\r\n\r\n"),
                  let connected = await c.readHTTPHead(), ProbeConnection.status(connected) == 200 else { return nil }
            let request = "GET /generate_204 HTTP/1.1\r\nHost: \(host)\r\nUser-Agent: SecretClub\r\nAccept: */*\r\nConnection: keep-alive\r\n\r\n"
            let first = DispatchTime.now()
            guard await c.send(request), let r1 = await c.readHTTPHead(), ProbeConnection.status(r1) == 204 else { return nil }
            let firstMS = elapsedMS(since: first)
            let second = DispatchTime.now()
            guard await c.send(request), let r2 = await c.readHTTPHead(), ProbeConnection.status(r2) == 204 else { return firstMS }
            return elapsedMS(since: second)
        }
    }

    /// Сайты для «большой» проверки: обычный HTTP (внутри туннеля всё равно шифруется), ~100 КБ.
    private static let payloadTargets: [(host: String, path: String)] = [
        ("cachefly.cachefly.net", "/100kb.test"),
        ("speedtest.tele2.net", "/100KB.zip"),
    ]

    /// Скачивает ~100 КБ через сервер. Маленькая проверка (204) проходит и там, где провайдер
    /// «замораживает» соединение после ~16 КБ, — эта нет.
    static func payload(port: Int, timeout: Double = 10) async -> PayloadVerdict {
        for target in payloadTargets {
            let verdict = await payloadOnce(port: port, host: target.host, path: target.path, timeout: timeout)
            if verdict != .inconclusive { return verdict }
            if Task.isCancelled { break }
        }
        return .inconclusive
    }

    private static func payloadOnce(port: Int, host: String, path: String, timeout: Double) async -> PayloadVerdict {
        guard let c = ProbeConnection(host: "127.0.0.1", port: port, parameters: .tcp) else { return .inconclusive }
        return await using(c) {
            guard await c.open(timeout: timeout),
                  await c.send("CONNECT \(host):80 HTTP/1.1\r\nHost: \(host):80\r\n\r\n"),
                  let connected = await c.readHTTPHead(), ProbeConnection.status(connected) == 200 else { return .inconclusive }
            let request = "GET \(path) HTTP/1.1\r\nHost: \(host)\r\nUser-Agent: SecretClub\r\nAccept: */*\r\nConnection: close\r\n\r\n"
            let start = DispatchTime.now()
            guard await c.send(request), let response = await c.readHead(),
                  let code = ProbeConnection.status(response.0), code == 200 || code == 206 else { return .inconclusive }
            let head = response.0
            let first = response.1
            let expected = ProbeConnection.contentLength(head)
            guard expected >= 32768 else { return .inconclusive }
            let goal = min(expected, 98304)
            var received = first
            while received < goal {
                // «Замёрзшее» соединение не рвётся, а просто молчит — не ждём общий таймаут.
                c.armIdle(3)
                guard let chunk = await c.receiveChunk() else { break }
                received += chunk.count
            }
            let ms = elapsedMS(since: start)
            // Блокировка по объёму обрывает на ~16–20 КБ; медленная, но живая сеть успевает больше.
            if received >= goal || received >= 40960 {
                return .ok(max(1, received * 1000 / 1024 / ms))
            }
            return .stalled(received)
        }
    }
}

/// Проверка DNS через ядро: A-запрос на проверочный вход dns-probe проходит тем же путём, что и
/// DNS-запросы приложений (dns-out → DNS ядра → DNS-серверы из подписки, обычно через сервер).
/// Имя каждый раз новое — кэш ядра не отвечает за сеть. Любой ответ (и «такого имени нет») — DNS работает.
enum DNSProbe {
    static func randomName() -> String {
        let letters = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        let label = String((0..<12).map { _ in letters.randomElement()! })
        return "sc-\(label).google.com"
    }

    /// DNS-запрос A-записи (RD=1).
    static func query(name: String, id: UInt16) -> Data {
        var d = Data([UInt8(id >> 8), UInt8(id & 0xff), 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        for label in name.split(separator: ".") {
            let bytes = Array(label.utf8.prefix(63))
            d.append(UInt8(bytes.count))
            d.append(contentsOf: bytes)
        }
        d.append(contentsOf: [0x00, 0x00, 0x01, 0x00, 0x01])
        return d
    }

    /// Ответ на наш запрос: тот же id и флаг QR.
    static func isResponse(_ data: Data, id: UInt16) -> Bool {
        let b = [UInt8](data.prefix(4))
        guard b.count == 4 else { return false }
        return (UInt16(b[0]) << 8 | UInt16(b[1])) == id && b[2] & 0x80 != 0
    }

    /// Миллисекунды до ответа или nil — DNS через ядро не ответил за timeout.
    static func viaCore(port: Int, timeout: Double = 5) async -> Int? {
        guard let c = ProbeConnection(host: "127.0.0.1", port: port, parameters: .udp) else { return nil }
        let id = UInt16.random(in: 1...UInt16.max)
        let start = DispatchTime.now()
        let ok: Bool = await LatencyProbe.using(c) {
            guard await c.open(timeout: timeout), await c.send(data: query(name: randomName(), id: id)) else { return false }
            while let data = await c.receiveChunk() {
                if isResponse(data, id: id) { return true }
            }
            return false
        }
        return ok ? LatencyProbe.elapsedMS(since: start) : nil
    }
}
