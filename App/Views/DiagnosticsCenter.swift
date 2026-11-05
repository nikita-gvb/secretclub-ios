import SwiftUI
import UniformTypeIdentifiers

/// Экран «Диагностика»: состояние VPN, журналы приложения и расширения, сбои (MetricKit и аварийные
/// завершения VPN). Отчёт можно скопировать или отправить файлом в поддержку.
struct DiagnosticsCenter: View {
    @Environment(AppModel.self) private var app

    enum Tab: String, CaseIterable, Identifiable {
        case summary = "Сводка", log = "Журнал", incidents = "Сбои"
        var id: String { rawValue }
    }

    enum Filter: String, CaseIterable, Identifiable {
        case all = "Все", tunnel = "VPN", app = "Приложение", important = "Важное"
        var id: String { rawValue }

        func matches(_ line: DiagnosticsData.Line) -> Bool {
            switch self {
            case .all: return true
            case .tunnel: return line.source == .tunnel
            case .app: return line.source == .app
            case .important: return line.important
            }
        }
    }

    @State private var tab: Tab = .summary
    @State private var filter: Filter = .all
    @State private var data = DiagnosticsData()
    @State private var lines: [DiagnosticsData.Line] = []
    @State private var summary = ""
    @State private var fullText = ""
    @State private var loading = false
    @State private var loadedAt: Date?
    @State private var confirmClear = false
    @State private var expanded: Set<String> = []

    private let shownLines = 400

    var body: some View {
        List {
            Section { tiles }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))

            Section {
                Picker("Раздел", selection: $tab) {
                    ForEach(Tab.allCases) { item in
                        Text(item == .incidents && data.recentIncidents > 0 ? "Сбои · \(data.recentIncidents)" : item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))

            switch tab {
            case .summary: summarySection
            case .log: logSections
            case .incidents: incidentSection
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Диагностика")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { menu } }
        .safeAreaInset(edge: .bottom) { actions }
        .refreshable { await load() }
        .task { if loadedAt == nil { await load() } }
        .confirmationDialog("Очистить журналы и список сбоев?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Очистить", role: .destructive) { clear() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Удалятся записи приложения\(AppGroup.identifier != nil ? " и VPN" : ""). Новые начнут копиться сразу.")
        }
        .sensoryFeedback(.selection, trigger: tab)
    }

    // MARK: Плитки состояния

    private var tiles: some View {
        let report = app.vpn.report
        let connected = app.vpn.state == .connected
        let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
        return LazyVGrid(columns: columns, spacing: 10) {
            DiagTile(icon: "power", title: "VPN",
                     value: VPNController.title(app.vpn.state).capitalizedFirst,
                     detail: connected ? (report?.routeTitle ?? app.activeRoute?.remarks) : nil,
                     tone: connected ? (app.tunnelHealthy == false ? .warn : .good) : .neutral)
            DiagTile(icon: "bolt.horizontal.fill", title: "Связь с расширением",
                     value: linkValue, detail: app.vpn.pollFailures > 0 ? "сбоев подряд: \(app.vpn.pollFailures)" : nil,
                     tone: !connected ? .neutral : (app.vpn.pollFailures > 2 ? .bad : .good))
            DiagTile(icon: "memorychip", title: "Память VPN",
                     value: report?.memoryMB.map { "\(Int($0.rounded())) МБ" } ?? "—", detail: "лимит iOS — 50 МБ",
                     tone: (report?.memoryMB ?? 0) >= 40 ? .warn : (report?.memoryMB == nil ? .neutral : .good))
            DiagTile(icon: "exclamationmark.triangle.fill", title: "Сбои за 7 дней",
                     value: data.recentIncidents == 0 ? "Нет" : "\(data.recentIncidents)",
                     detail: data.incidents.first.map { Self.dateText($0.date) },
                     tone: data.recentIncidents == 0 ? .good : .bad)
            DiagTile(icon: "arrow.triangle.2.circlepath", title: "Смена сервера",
                     value: report?.hot == true ? "Без обрыва" : (report?.multi == true ? "Перезапуском" : "—"),
                     detail: report?.lastSwitchMS.map { String(format: "последняя %.1f с", Double($0) / 1000) },
                     tone: report?.hot == true ? .good : .neutral)
            DiagTile(icon: "globe", title: "DNS через VPN",
                     value: connected ? (report?.dnsOK.map { $0 ? "Отвечает" : "Не отвечает" } ?? "—") : "—",
                     detail: connected ? (report?.dnsOK == false ? "сайты не откроются" : report?.dnsMS.map { "\($0) мс" }) : nil,
                     tone: !connected ? .neutral : (report?.dnsOK.map { $0 ? DiagTile.Tone.good : DiagTile.Tone.bad } ?? .neutral))
            DiagTile(icon: "chart.bar.fill", title: "Счётчики трафика",
                     value: report?.counters == "core" ? "Ядро" : (report?.counters == "utun" ? "Интерфейс" : "—"),
                     detail: report.map { "↓ \(Format.bytes($0.downlink)) ↑ \(Format.bytes($0.uplink))" },
                     tone: report?.counters == "core" ? .good : .neutral)
        }
    }

    private var linkValue: String {
        guard app.vpn.state == .connected else { return "—" }
        guard let at = app.vpn.lastReportAt else { return "Нет ответа" }
        let seconds = Int(Date().timeIntervalSince(at))
        return seconds < 2 ? "Сейчас" : "\(seconds) с назад"
    }

    // MARK: Разделы

    private var summarySection: some View {
        Section {
            Text(summary.isEmpty ? "Собираем…" : summary)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(Theme.label)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
        } footer: {
            Text("Личные данные и история сайтов в отчёт не попадают: только состояние VPN, серверы и решения «Авто».")
        }
    }

    @ViewBuilder private var logSections: some View {
        Section {
            Picker("Фильтр", selection: $filter) {
                ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.menu)
            .tint(Theme.ink)
            if data.tunnelLogMissing {
                Label("Журнал VPN появится, когда VPN включён", systemImage: "info.circle")
                    .font(.scFoot)
                    .foregroundStyle(Theme.label2)
            }
        }
        let filtered = lines.filter { filter.matches($0) }
        let visible = Array(filtered.suffix(shownLines).reversed())
        if visible.isEmpty {
            Section {
                Text(loading ? "Загружаем…" : "Записей пока нет")
                    .foregroundStyle(Theme.label2)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            }
        } else {
            let groups = Self.days(visible)
            ForEach(groups, id: \.day) { group in
                Section {
                    ForEach(group.lines) { LogRow(line: $0) }
                } header: {
                    Text(Self.dayTitle(group.day))
                } footer: {
                    if group.day == groups.last?.day, filtered.count > shownLines {
                        Text("Показаны последние \(shownLines) из \(filtered.count). Полный журнал — в файле «Отправить».")
                    }
                }
            }
        }
    }

    @ViewBuilder private var incidentSection: some View {
        if data.incidents.isEmpty {
            Section {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(Theme.green)
                    Text("Сбоев не было").font(.scHeadline).foregroundStyle(Theme.label)
                    Text("Здесь появятся сбои и зависания приложения из отчётов iOS (приходят раз в сутки) и аварийные завершения VPN.")
                        .font(.scFoot)
                        .foregroundStyle(Theme.label2)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
            }
        } else {
            Section {
                ForEach(data.incidents) { item in
                    IncidentRow(incident: item, expanded: expanded.contains(item.id)) {
                        withAnimation(.snappy) {
                            if expanded.contains(item.id) { expanded.remove(item.id) } else { expanded.insert(item.id) }
                        }
                    }
                    .contextMenu {
                        Button {
                            copy("\(Self.dateText(item.date)) \(item.title): \(item.detail)", toast: "Скопировано")
                        } label: { Label("Скопировать", systemImage: "doc.on.doc") }
                        if let url = fileURL(item) {
                            ShareLink(item: url) { Label("Отправить отчёт iOS", systemImage: "square.and.arrow.up") }
                        }
                    }
                }
            } footer: {
                Text("Удерживайте сбой, чтобы скопировать или отправить полный отчёт iOS.")
            }
        }
    }

    // MARK: Действия

    private var actions: some View {
        HStack(spacing: 10) {
            Button { copy(compactText(), toast: "Отчёт скопирован — вставьте его в чат поддержки") } label: {
                Label("Скопировать", systemImage: "doc.on.doc")
            }
            .buttonStyle(.scSecondary)
            ShareLink(item: ReportFile(text: fullText.isEmpty ? summary : fullText, name: Self.fileName()),
                      preview: SharePreview("Отчёт SecretClub", image: Image(systemName: "doc.text"))) {
                Label("Отправить", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.scPrimary)
            .disabled(loading && fullText.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(.bar)
    }

    private var menu: some View {
        Menu {
            Button { copy(summary, toast: "Сводка скопирована") } label: { Label("Скопировать сводку", systemImage: "list.bullet.rectangle") }
            Button { copy(data.logText { filter.matches($0) }, toast: "Журнал скопирован") } label: {
                Label(filter == .all ? "Скопировать журнал" : "Скопировать журнал («\(filter.rawValue)»)", systemImage: "text.alignleft")
            }
            Button { copy(data.incidentsText(), toast: "Список сбоев скопирован") } label: { Label("Скопировать сбои", systemImage: "exclamationmark.triangle") }
            Button { Task { await load() } } label: { Label("Обновить", systemImage: "arrow.clockwise") }
            Link(destination: Config.supportURL) { Label("Написать в поддержку", systemImage: "paperplane") }
            Divider()
            Button(role: .destructive) { confirmClear = true } label: { Label("Очистить журналы", systemImage: "trash") }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }

    // MARK: Данные

    private func load() async {
        loading = true
        let fresh = await DiagnosticsData.load(vpn: app.vpn)
        let text = app.supportReport()
        data = fresh
        summary = text
        lines = fresh.lines
        fullText = await Task.detached { fresh.fullReport(summary: text) }.value
        loadedAt = Date()
        loading = false
        app.recentIncidents = fresh.recentIncidents
    }

    private func clear() {
        DiagLog.clear()
        Incidents.clear()
        DiagLog.write("журналы очищены", to: .app)
        app.recentIncidents = 0
        app.showToast("Журналы очищены", icon: "trash", tone: .good)
        Task { await load() }
    }

    /// Для вставки в чат: сводка, сбои и последние записи журнала (полный — файлом).
    private func compactText() -> String {
        let tail = lines.suffix(150).map { "\($0.stamp) [\($0.source.title)] \($0.text)" }.joined(separator: "\n")
        return [summary, "", "Сбои:", data.incidentsText(), "", "Журнал (последние записи):", tail].joined(separator: "\n")
    }

    private func copy(_ text: String, toast: String) {
        UIPasteboard.general.string = text
        app.showToast(toast, icon: "doc.on.doc.fill", tone: .good)
    }

    private func fileURL(_ incident: Incident) -> URL? {
        guard let file = incident.file, let url = DiagLog.directory?.appendingPathComponent(file),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    static func fileName() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmm"
        return "SecretClub-report-\(f.string(from: Date())).txt"
    }

    static func dateText(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }

    static func days(_ lines: [DiagnosticsData.Line]) -> [(day: String, lines: [DiagnosticsData.Line])] {
        var out: [(day: String, lines: [DiagnosticsData.Line])] = []
        for line in lines {
            if out.last?.day == line.day { out[out.count - 1].lines.append(line) } else { out.append((line.day, [line])) }
        }
        return out
    }

    static func dayTitle(_ day: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        guard let date = f.date(from: day) else { return day }
        if Calendar.current.isDateInToday(date) { return "Сегодня" }
        if Calendar.current.isDateInYesterday(date) { return "Вчера" }
        return date.formatted(.dateTime.day().month(.wide))
    }
}

/// Файл отчёта для «Отправить» (Telegram, почта, «Файлы»).
struct ReportFile: Transferable {
    let text: String
    let name: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .plainText) { file in
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(file.name)
            try Data(file.text.utf8).write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
    }
}

private struct DiagTile: View {
    enum Tone { case good, warn, bad, neutral }

    let icon: String
    let title: String
    let value: String
    var detail: String? = nil
    var tone: Tone = .neutral

    private var color: Color {
        switch tone {
        case .good: return Theme.green
        case .warn: return Theme.orange
        case .bad: return Theme.red
        case .neutral: return Theme.gray
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(color)
                    .frame(width: 22, height: 22)
                    .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text(title)
                    .font(.sc(12, .medium, relativeTo: .caption))
                    .foregroundStyle(Theme.label2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            Text(value)
                .font(.sc(17, .semibold, relativeTo: .headline))
                .foregroundStyle(Theme.label)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .contentTransition(.numericText())
            Text(detail ?? " ")
                .font(.sc(12, .regular, relativeTo: .caption))
                .foregroundStyle(Theme.label2)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Theme.cell, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.border, lineWidth: 0.5))
        .accessibilityElement(children: .combine)
    }
}

private struct LogRow: View {
    let line: DiagnosticsData.Line

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(line.time)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(Theme.label2)
                Text(line.source.title)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(line.source == .tunnel ? Theme.ink : Theme.blue)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background((line.source == .tunnel ? Theme.tint : Theme.blue).opacity(0.15), in: Capsule())
            }
            Text(line.important ? String(line.text.dropFirst(2)) : line.text)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(line.important ? Theme.orange : Theme.label)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }
}

private struct IncidentRow: View {
    let incident: Incident
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(alignment: .top, spacing: 12) {
                SquareIcon(systemName: incident.source == .tunnel ? "shield.slash.fill" : "exclamationmark.triangle.fill",
                           color: incident.title.hasPrefix("Сбой") || incident.source == .tunnel ? Theme.red : Theme.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text(incident.title).font(.scBody.weight(.semibold)).foregroundStyle(Theme.label)
                    Text(DiagnosticsCenter.dateText(incident.date)).font(.scFoot).foregroundStyle(Theme.label2)
                    Text(incident.detail)
                        .font(.scFoot)
                        .foregroundStyle(Theme.label2)
                        .lineLimit(expanded ? nil : 2)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.label3)
                    .rotationEffect(.degrees(expanded ? 180 : 0))
                    .padding(.top, 4)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
