import Foundation

enum DeviceInfo {
    static var hwid: String {
        if let v = Keychain.read("hwid") { return v }
        let v = UUID().uuidString.lowercased()
        Keychain.save(v, for: "hwid")
        return v
    }

    static var model: String {
        var info = utsname()
        uname(&info)
        let bytes = Mirror(reflecting: info.machine).children.compactMap { $0.value as? Int8 }
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion)" + (v.patchVersion > 0 ? ".\(v.patchVersion)" : "")
    }

    static var displayName: String {
        let kind = model.hasPrefix("iPad") ? "iPad" : "iPhone"
        return "\(kind) · iOS \(osVersion)"
    }

    /// Заголовки для Remnawave (HWID-учёт устройств).
    static var headers: [String: String] {
        [
            "User-Agent": "SecretClub/\(Config.shortVersion) (iOS \(osVersion))",
            "x-hwid": hwid,
            "x-device-os": "iOS",
            "x-ver-os": osVersion,
            "x-device-model": model,
        ]
    }
}
