import Foundation
import CryptoKit
import Security

// MARK: - Модели аккаунта (ответ /api/app/me бэкенда мини-аппа)

struct AccountDevice: Identifiable, Hashable {
    let hwid: String
    let platform: String?
    let osVersion: String?
    let model: String?
    let createdAt: Date?
    let updatedAt: Date?

    var id: String { hwid }
    var isCurrent: Bool { hwid == DeviceInfo.hwid }

    var title: String {
        if let model, !model.isEmpty { return DeviceInfo.friendlyModel(model) }
        if let platform, !platform.isEmpty { return platform }
        return "Устройство"
    }

    var system: String? {
        let parts = [platform, osVersion].compactMap { $0?.isEmpty == false ? $0 : nil }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    var kind: Device.Kind {
        let text = "\(platform ?? "") \(model ?? "")".lowercased()
        if text.contains("ipad") || text.contains("tablet") { return .tablet }
        if text.contains("tv") { return .tv }
        if text.contains("mac") || text.contains("windows") || text.contains("linux") { return .laptop }
        return .phone
    }

    var device: Device {
        Device(id: hwid, name: title, kind: kind, lastSeen: updatedAt ?? createdAt, isCurrent: isCurrent, detail: system)
    }

    init(json: [String: Any]) {
        hwid = json.text("hwid") ?? UUID().uuidString
        platform = json.text("platform")
        osVersion = json.text("osVersion")
        model = json.text("deviceModel")
        createdAt = json.date("createdAt")
        updatedAt = json.date("lastSeenAt") ?? json.date("updatedAt")
    }
}

struct AccountSubscription: Hashable {
    var url: String?
    var kind: String?
    var status: SubscriptionStatus
    /// Бэкенд не смог получить данные из панели — показываем текст, ссылку оставляем.
    var error: String?
    var daysLeft: Int?
    var lifetime: Bool
    var expireAt: Date?
    var usedBytes: Int64
    var totalBytes: Int64?
    var deviceCount: Int?
    var deviceLimit: Int?
    var devices: [AccountDevice]

    init(json: [String: Any]) {
        url = json.text("url")
        kind = json.text("kind")
        status = SubscriptionStatus(rawValue: json.text("status") ?? "") ?? .active
        error = json.text("error")
        daysLeft = json.int("daysLeft")
        lifetime = json.bool("lifetime")
        expireAt = json.int64("expireAt").map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
        usedBytes = json.int64("usedBytes") ?? 0
        totalBytes = json.int64("totalBytes").flatMap { $0 > 0 ? $0 : nil }
        deviceCount = json.int("deviceCount")
        deviceLimit = json.int("deviceLimit").flatMap { $0 > 0 ? $0 : nil }
        devices = (json["devices"] as? [[String: Any]] ?? []).map(AccountDevice.init(json:))
    }
}

struct AccountMe: Hashable {
    var telegramId: String?
    var username: String?
    var firstName: String?
    var consentAccepted: Bool
    var consentVersion: String?
    var termsURL: URL?
    var privacyURL: URL?
    var botUsername: String?
    var supportURL: URL?
    var announcement: String?
    var hasSubscription: Bool
    var subscription: AccountSubscription?
    var reserve: AccountSubscription?
    var trialAvailable: Bool
    var trialDays: Int?
    var freeReserveMB: Int

    var displayName: String {
        if let firstName, !firstName.isEmpty { return firstName }
        if let username, !username.isEmpty { return "@\(username)" }
        return "Telegram"
    }

    init(json: [String: Any]) {
        let user = json["user"] as? [String: Any] ?? [:]
        telegramId = user.text("telegramId")
        username = user.text("username")
        firstName = user.text("firstName")
        let consent = json["consent"] as? [String: Any] ?? [:]
        consentAccepted = consent.bool("accepted")
        consentVersion = consent.text("version")
        termsURL = consent.text("terms").flatMap(URL.init(string:))
        privacyURL = consent.text("privacy").flatMap(URL.init(string:))
        let links = json["links"] as? [String: Any] ?? [:]
        botUsername = links.text("botUsername")
        supportURL = links.text("support").flatMap(URL.init(string:))
        announcement = json.text("announcement")
        hasSubscription = json.bool("hasSubscription")
        subscription = (json["subscription"] as? [String: Any]).map(AccountSubscription.init(json:))
        reserve = (json["extra"] as? [String: Any]).map(AccountSubscription.init(json:))
        let trial = json["trial"] as? [String: Any] ?? [:]
        trialAvailable = trial.bool("available")
        trialDays = trial.int("days")
        freeReserveMB = json.int("freeExtraMb") ?? 200
    }
}

/// true/false из JSON приходят как CFBoolean — отличаем их от чисел 0 и 1.
private func isJSONBool(_ value: Any?) -> Bool {
    guard let n = value as? NSNumber else { return false }
    return CFGetTypeID(n as CFTypeRef) == CFBooleanGetTypeID()
}

extension Dictionary where Key == String, Value == Any {
    func text(_ key: String) -> String? {
        if let s = self[key] as? String { return s.isEmpty ? nil : s }
        if let n = self[key] as? NSNumber, !isJSONBool(n) { return n.stringValue }
        return nil
    }
    func int64(_ key: String) -> Int64? {
        if let n = self[key] as? NSNumber, !isJSONBool(n) { return n.int64Value }
        if let s = self[key] as? String { return Int64(s) }
        return nil
    }
    func int(_ key: String) -> Int? { int64(key).map { Int(clamping: $0) } }
    func bool(_ key: String) -> Bool {
        (self[key] as? NSNumber)?.boolValue ?? false
    }
    func date(_ key: String) -> Date? {
        if let ms = int64(key), ms > 0 { return Date(timeIntervalSince1970: TimeInterval(ms) / (ms > 10_000_000_000 ? 1000 : 1)) }
        guard let s = text(key) else { return nil }
        return AccountDate.parse(s)
    }
}

enum AccountDate {
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain = ISO8601DateFormatter()
    static func parse(_ s: String) -> Date? { fractional.date(from: s) ?? plain.date(from: s) }
}

// MARK: - Вход через Telegram

/// Начатый вход: код для бота и секрет (verifier), который знает только это устройство.
struct LoginTicket: Codable, Hashable {
    var code: String
    var verifier: String
    var botURL: URL
    var tgURL: URL?
    var expiresAt: Date

    private static let key = "pendingLogin"

    static func load() -> LoginTicket? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let ticket = try? JSONDecoder().decode(LoginTicket.self, from: data), ticket.expiresAt > Date() else { return nil }
        return ticket
    }
    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
}

enum AccountError: LocalizedError {
    case server(status: Int, code: String?, message: String)
    case network(String)
    case format

    var errorDescription: String? {
        switch self {
        case .server(_, _, let message): return message
        case .network(let message): return "Нет связи с сервером: \(message)"
        case .format: return "Сервер ответил непонятно. Попробуйте позже."
        }
    }

    var status: Int? {
        if case .server(let status, _, _) = self { return status }
        return nil
    }
}

enum AccountAPI {
    enum PollResult {
        case pending
        case ok(token: String, me: [String: Any])
    }

    static func call(_ path: String, method: String = "POST", body: [String: Any]? = nil,
                     token: String? = nil, timeout: TimeInterval = 20) async throws -> [String: Any] {
        guard let url = URL(string: Config.apiBase + path) else { throw AccountError.format }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(DeviceInfo.headers["User-Agent"], forHTTPHeaderField: "User-Agent")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if method != "GET" {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body ?? [String: Any]())
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw AccountError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw AccountError.format }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(http.statusCode) else {
            let message = json?.text("error") ?? "Сервер ответил ошибкой \(http.statusCode)."
            throw AccountError.server(status: http.statusCode, code: json?.text("code"), message: message)
        }
        guard let json else { throw AccountError.format }
        return json
    }

    private static func me(from json: [String: Any]) throws -> [String: Any] {
        guard let me = json["me"] as? [String: Any] else { throw AccountError.format }
        return me
    }

    // PKCE: в бот уходит только код, токен получит лишь устройство, знающее verifier.
    static func makeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            bytes = (0..<32).map { _ in UInt8.random(in: 0...255) }
        }
        return Data(bytes).base64URL
    }

    static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
    }

    static func start() async throws -> LoginTicket {
        let verifier = makeVerifier()
        let device: [String: Any] = [
            "hwid": DeviceInfo.hwid,
            "model": DeviceInfo.model,
            "os": "iOS \(DeviceInfo.osVersion)",
            "app": "SecretClub \(Config.shortVersion)",
        ]
        let json = try await call("/api/native/login/start", body: ["challenge": challenge(for: verifier), "device": device])
        guard let code = json.text("code"), let bot = json.text("botUrl").flatMap(URL.init(string:)) else {
            throw AccountError.format
        }
        if let username = json.text("botUsername") { UserDefaults.standard.set(username, forKey: "botUsername") }
        let expires = json.int64("expiresAt").map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
            ?? Date().addingTimeInterval(300)
        return LoginTicket(code: code, verifier: verifier, botURL: bot,
                           tgURL: json.text("tgUrl").flatMap(URL.init(string:)), expiresAt: expires)
    }

    static func poll(_ ticket: LoginTicket) async throws -> PollResult {
        let json = try await call("/api/native/login/poll", body: ["code": ticket.code, "verifier": ticket.verifier], timeout: 15)
        if json.text("status") == "ok", let token = json.text("token") {
            return .ok(token: token, me: json["me"] as? [String: Any] ?? [:])
        }
        return .pending
    }

    static func me(_ token: String) async throws -> [String: Any] {
        try me(from: try await call("/api/app/me", method: "GET", token: token))
    }

    static func acceptConsent(_ token: String, version: String) async throws -> [String: Any] {
        try me(from: try await call("/api/app/consent", body: ["version": version], token: token))
    }

    static func startTrial(_ token: String) async throws -> [String: Any] {
        try me(from: try await call("/api/app/trial", token: token, timeout: 40))
    }

    static func createReserve(_ token: String) async throws -> [String: Any] {
        try me(from: try await call("/api/app/extra/create", token: token, timeout: 40))
    }

    static func deleteDevice(_ token: String, hwid: String, reserve: Bool) async throws {
        var body: [String: Any] = ["hwid": hwid]
        if reserve { body["target"] = "extra" }
        _ = try await call("/api/app/devices/delete", body: body, token: token, timeout: 30)
    }

    static func logout(_ token: String) async {
        _ = try? await call("/api/native/logout", token: token, timeout: 8)
    }
}

/// Последний ответ /me — чтобы экран подписки открывался сразу, и без сети тоже.
enum AccountStore {
    private static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("account.json")
    }

    static func save(_ me: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(me), let data = try? JSONSerialization.data(withJSONObject: me) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func load() -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func clear() { try? FileManager.default.removeItem(at: url) }
}

extension Data {
    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
