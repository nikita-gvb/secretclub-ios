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
