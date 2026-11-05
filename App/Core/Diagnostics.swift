import Foundation
import MetricKit
import WidgetKit

/// Отчёты iOS о сбоях, зависаниях и аварийных выходах (MetricKit). Приходят раз в сутки
/// или при следующем запуске; сохраняем их в папку диагностики и в список сбоев.
final class MetricsCollector: NSObject, MXMetricManagerSubscriber {
    static let shared = MetricsCollector()
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        MXMetricManager.shared.add(self)
        let past = MXMetricManager.shared.pastDiagnosticPayloads
        if !past.isEmpty { DispatchQueue.global(qos: .utility).async { self.process(past) } }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) { process(payloads) }

    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            guard let exits = payload.applicationExitMetrics else { continue }
            let bg = exits.backgroundExitData
            let fg = exits.foregroundExitData
            let crashes = bg.cumulativeAbnormalExitCount + fg.cumulativeAbnormalExitCount
            let memory = bg.cumulativeMemoryResourceLimitExitCount + fg.cumulativeMemoryResourceLimitExitCount
            let watchdog = bg.cumulativeAppWatchdogExitCount + fg.cumulativeAppWatchdogExitCount
            let text = "MetricKit за сутки: аварийных выходов \(crashes), по памяти \(memory), по сторожу \(watchdog)"
            if crashes + memory + watchdog > 0 { DiagLog.warn(text, to: .app) } else { DiagLog.write(text, to: .app) }
        }
    }

    private func process(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            var items: [(kind: String, code: String, diagnostic: MXDiagnostic, detail: String)] = []
            for crash in payload.crashDiagnostics ?? [] {
                var parts: [String] = []
                if let type = crash.exceptionType { parts.append("исключение \(type)") }
                if let code = crash.exceptionCode { parts.append("код \(code)") }
                if let signal = crash.signal { parts.append("сигнал \(signal)") }
                if let reason = crash.terminationReason, !reason.isEmpty { parts.append(reason) }
                items.append(("Сбой", "crash", crash, parts.joined(separator: ", ")))
            }
            for hang in payload.hangDiagnostics ?? [] {
                let seconds = hang.hangDuration.converted(to: .seconds).value
                items.append(("Зависание", "hang", hang, String(format: "интерфейс не отвечал %.1f с", seconds)))
            }
            for cpu in payload.cpuExceptionDiagnostics ?? [] {
                let seconds = cpu.totalCPUTime.converted(to: .seconds).value
                items.append(("Перегрузка процессора", "cpu", cpu, String(format: "%.0f с процессорного времени", seconds)))
            }
            for disk in payload.diskWriteExceptionDiagnostics ?? [] {
                let mb = disk.totalWritesCaused.converted(to: .megabytes).value
                items.append(("Много записи на диск", "disk", disk, String(format: "%.0f МБ", mb)))
            }
            for (index, item) in items.enumerated() {
                let json = item.diagnostic.jsonRepresentation()
                let text = String(decoding: json, as: UTF8.self)
                let tunnel = text.contains("PacketTunnel") || text.contains(".tunnel")
                let stamp = Int(payload.timeStampEnd.timeIntervalSince1970)
                let id = "mx-\(stamp)-\(item.code)-\(index)"
                let file = "metrickit-\(stamp)-\(index).json"
                let meta = item.diagnostic.metaData
                let detail = [item.detail, "версия \(meta.applicationBuildVersion)", "iOS \(meta.osVersion)", meta.deviceType]
                    .filter { !$0.isEmpty }.joined(separator: " · ")
                let incident = Incident(id: id, date: payload.timeStampEnd, source: tunnel ? .tunnel : .app,
                                        title: "\(item.kind)\(tunnel ? " VPN" : " приложения")", detail: detail, file: file)
                if Incidents.add(incident) {
                    if let dir = DiagLog.directory { try? json.write(to: dir.appendingPathComponent(file), options: .atomic) }
                    DiagLog.warn("MetricKit: \(incident.title) — \(detail)", to: .app)
                }
            }
        }
    }
}

/// Обновление виджетов и переключателя в Пункте управления (с небольшой задержкой — состояния идут пачкой).
@MainActor
enum WidgetSync {
    private static var task: Task<Void, Never>?

    static func reload() {
        task?.cancel()
        task = Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            WidgetCenter.shared.reloadAllTimelines()
            if #available(iOS 18.0, *) { ControlCenter.shared.reloadAllControls() }
        }
    }
}

/// Всё для экрана диагностики и отчёта: журналы обеих частей, сбои, отчёты MetricKit.
struct DiagnosticsData {
    struct Line: Identifiable, Hashable {
        let id: Int
        let source: DiagLog.Source
        /// «2025-01-02 12:03:04».
        let stamp: String
        let text: String
        var important: Bool { text.hasPrefix("⚠︎") }
        var time: String { stamp.count >= 19 ? String(stamp.suffix(8)) : stamp }
        var day: String { String(stamp.prefix(10)) }
    }

    var tunnelLog = ""
    var appLog = ""
    var incidents: [Incident] = []
    /// Журнал VPN не получен: нет общей папки, а VPN выключен.
    var tunnelLogMissing = false
    var tunnelReport: TunnelReport?

    /// Строки обоих журналов по времени (новые внизу).
    var lines: [Line] {
        var all: [(source: DiagLog.Source, stamp: String, text: String, order: Int)] = []
        var order = 0
        for (source, text) in [(DiagLog.Source.tunnel, tunnelLog), (.app, appLog)] {
            for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
                let line = String(raw)
                let stamp = line.count > 20 ? String(line.prefix(19)) : ""
                let body = stamp.isEmpty ? line : String(line.dropFirst(20))
                all.append((source, stamp, body, order))
                order += 1
            }
        }
        all.sort { $0.stamp == $1.stamp ? $0.order < $1.order : $0.stamp < $1.stamp }
        return all.enumerated().map { Line(id: $0.offset, source: $0.element.source, stamp: $0.element.stamp, text: $0.element.text) }
    }

    static func load(vpn: VPNController) async -> DiagnosticsData {
        var data = DiagnosticsData()
        let shared = AppGroup.identifier != nil
        data.appLog = await Task.detached { DiagLog.read(.app, maxBytes: 256 * 1024) }.value
        var incidents = await Task.detached { Incidents.all() }.value
        if shared {
            data.tunnelLog = await Task.detached { DiagLog.read(.tunnel, maxBytes: 256 * 1024) }.value
        }
        if let report = await vpn.fetchTunnelLog() {
            data.tunnelReport = report
            if !shared { data.tunnelLog = report.logTail ?? "" }
            for item in report.incidents ?? [] where !incidents.contains(where: { $0.id == item.id }) { incidents.append(item) }
        } else if !shared {
            data.tunnelLogMissing = true
        }
        data.incidents = incidents.sorted { $0.date > $1.date }
        return data
    }

    var recentIncidents: Int { incidents.filter { Date().timeIntervalSince($0.date) < 7 * 86400 }.count }

    func logText(_ filter: ((Line) -> Bool)? = nil) -> String {
        lines.filter { filter?($0) ?? true }
            .map { "\($0.stamp) [\($0.source.title)] \($0.text)" }
            .joined(separator: "\n")
    }

    func incidentsText() -> String {
        guard !incidents.isEmpty else { return "Сбоев не было." }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return incidents.map { "\(f.string(from: $0.date)) [\($0.source.title)] \($0.title): \($0.detail)" }.joined(separator: "\n")
    }

    /// Полный отчёт для поддержки: сводка, сбои, журнал и последние отчёты MetricKit.
    func fullReport(summary: String) -> String {
        var parts = ["=== Сводка ===", summary, "", "=== Сбои ===", incidentsText(), "", "=== Журнал ==="]
        if tunnelLogMissing { parts.append("(журнал VPN недоступен: включите VPN и обновите отчёт)") }
        parts.append(logText())
        if let dir = DiagLog.directory {
            for incident in incidents.prefix(3) {
                guard let file = incident.file, let json = try? String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8) else { continue }
                parts += ["", "=== MetricKit: \(incident.title) ===", String(json.prefix(60_000))]
            }
        }
        return parts.joined(separator: "\n")
    }
}
