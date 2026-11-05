import Foundation

enum Format {
    static let ru = Locale(identifier: "ru_RU")

    static func duration(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    static func bytes(_ b: Int64) -> String {
        let units = ["Б", "КБ", "МБ", "ГБ", "ТБ"]
        var v = Double(b)
        var i = 0
        while v >= 1024 && i < units.count - 1 { v /= 1024; i += 1 }
        if i == 0 { return "\(Int(v)) \(units[i])" }
        let num = v < 10 ? String(format: "%.1f", v).replacingOccurrences(of: ".", with: ",") : "\(Int(v.rounded()))"
        return "\(num) \(units[i])"
    }

    static func date(_ d: Date) -> String {
        d.formatted(.dateTime.day().month(.wide).year().locale(ru))
    }

    static func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let n10 = n % 10, n100 = n % 100
        if n10 == 1 && n100 != 11 { return one }
        if (2...4).contains(n10) && !(12...14).contains(n100) { return few }
        return many
    }

    static func lastSeen(_ d: Date) -> String {
        let minutes = Int(Date().timeIntervalSince(d) / 60)
        if minutes < 5 { return "в сети" }
        if minutes < 60 { return "\(minutes) \(plural(minutes, "минуту", "минуты", "минут")) назад" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) \(plural(hours, "час", "часа", "часов")) назад" }
        let days = hours / 24
        return "\(days) \(plural(days, "день", "дня", "дней")) назад"
    }
}

extension Format {
    /// «только что», «5 мин назад», «2 ч назад», «3 дн назад».
    static func ago(_ d: Date) -> String {
        let minutes = Int(Date().timeIntervalSince(d) / 60)
        if minutes < 1 { return "только что" }
        if minutes < 60 { return "\(minutes) мин назад" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) ч назад" }
        return "\(hours / 24) дн назад"
    }
}

extension Format {
    /// Скорость: «4,2» + «МБ/с» (меньше 0,1 МБ/с — в КБ/с).
    static func speedParts(_ bytesPerSecond: Double) -> (number: String, unit: String) {
        let mb = bytesPerSecond / 1_048_576
        if mb >= 0.1 { return (String(format: "%.1f", mb).replacingOccurrences(of: ".", with: ","), "МБ/с") }
        return ("\(Int((bytesPerSecond / 1024).rounded()))", "КБ/с")
    }

    static func speed(_ bytesPerSecond: Double) -> String {
        let p = speedParts(bytesPerSecond)
        return "\(p.number) \(p.unit)"
    }

    /// Объём: «2,4» + «ГБ».
    static func bytesParts(_ b: Int64) -> (number: String, unit: String) {
        let parts = bytes(b).split(separator: " ", maxSplits: 1).map(String.init)
        return (parts.first ?? "0", parts.count > 1 ? parts[1] : "")
    }

    /// «24 дня».
    static func days(_ n: Int) -> String { "\(n) \(plural(n, "день", "дня", "дней"))" }
}
