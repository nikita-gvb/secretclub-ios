import SwiftUI

enum SettingsRoute: Hashable {
    case diagnostics, exceptions
}

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @AppStorage(SettingsKey.autoConnect) private var autoConnect = false
    @AppStorage(SettingsKey.killSwitch) private var killSwitch = false
    @AppStorage(SettingsKey.ruDirect) private var ruDirect = true
    @AppStorage(SettingsKey.energySaver) private var energySaver = true
    @AppStorage(SettingsKey.transport) private var transport: TransportPreference = .auto
    @State private var path: [SettingsRoute] = []
    @State private var appliedInitial = false

    var body: some View {
        NavigationStack(path: $path) {
            PageScroll {
                PageHeader(title: "Настройки")

                SCSection(header: "Подключение", footer: "Автоподключение само включит VPN, когда появится сеть. «Без VPN — без сети» не выпустит трафик мимо туннеля — применится при следующем подключении.") {
                    Menu {
                        Picker("Протокол", selection: $transport) {
                            ForEach(TransportPreference.allCases) { Text($0.title).tag($0) }
                        }
                    } label: {
                        SCRow(title: "Протокол", value: transport.title) {
                            CellIcon(systemName: "point.3.connected.trianglepath.dotted")
                        } trailing: {
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.label3)
                        }
                    }
                    .buttonStyle(RowButtonStyle())
                    SCDivider()
                    ToggleRow(title: "Автоподключение", icon: "bolt", isOn: $autoConnect)
                    SCDivider()
                    ToggleRow(title: "Без VPN — без сети", icon: "lock", isOn: $killSwitch)
                }

                SCSection(header: "Маршрутизация", footer: "Госуслуги, банки и сайты .ru/.рф открываются без VPN — быстрее и без капч.") {
                    ToggleRow(title: "Российские сайты напрямую", icon: "house", isOn: $ruDirect)
                    SCDivider()
                    NavigationLink(value: SettingsRoute.exceptions) {
                        SCRow(title: "Исключения", chevron: true) { CellIcon(systemName: "list.bullet") }
                    }
                    .buttonStyle(RowButtonStyle())
                }

                SCSection(header: "Батарея", footer: "Реже обновляет подписку и не проверяет пинг при каждом запуске.") {
                    ToggleRow(title: "Экономия заряда", icon: "leaf", isOn: $energySaver)
                }

                SCSection(header: "Помощь") {
                    NavigationLink(value: SettingsRoute.diagnostics) {
                        SCRow(title: "Диагностика", chevron: true) { CellIcon(systemName: "stethoscope") }
                    }
                    .buttonStyle(RowButtonStyle())
                    SCDivider()
                    Link(destination: Config.supportURL) {
                        SCRow(title: "Поддержка в Telegram") {
                            CellIcon(systemName: "paperplane")
                        } trailing: {
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.label3)
                        }
                    }
                    .buttonStyle(RowButtonStyle())
                    SCDivider()
                    SCRow(title: "Версия", value: Config.version) { CellIcon(systemName: "info") }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .onChange(of: ruDirect) { app.settingsChanged() }
            .onChange(of: autoConnect) { _, on in app.autoConnectChanged(on) }
            .navigationDestination(for: SettingsRoute.self) { route in
                switch route {
                case .diagnostics: DiagnosticsView()
                case .exceptions: ExceptionsView()
                }
            }
            .onAppear {
                guard !appliedInitial else { return }
                appliedInitial = true
                if app.isDemo, app.initialScreen == "diagnostics" { path = [.diagnostics] }
                if app.isDemo, app.initialScreen == "exceptions" { path = [.exceptions] }
            }
        }
    }
}

struct ToggleRow: View {
    let title: String
    let icon: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 12) {
                CellIcon(systemName: icon)
                Text(title).font(.scBody).foregroundStyle(Theme.label).lineLimit(1)
            }
        }
        .tint(Theme.tintStrong)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .frame(minHeight: 52)
    }
}

enum ExceptionTarget: String, CaseIterable, Identifiable {
    case vpn, direct
    var id: String { rawValue }
    var title: String { self == .vpn ? "Через VPN" : "Напрямую" }
}

struct ExceptionsView: View {
    @Environment(AppModel.self) private var app
    @AppStorage(SettingsKey.vpnDomains) private var vpnRaw = ""
    @AppStorage(SettingsKey.directDomains) private var directRaw = ""
    @State private var newDomain = ""
    @State private var target: ExceptionTarget = .vpn
    @FocusState private var focused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(spacing: 10) {
                    HStack(spacing: 8) {
                        TextField("", text: $newDomain, prompt: Text("example.com").foregroundStyle(Theme.label3))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .focused($focused)
                            .onSubmit(add)
                            .scField(focused: focused)
                        Button("Добавить", action: add)
                            .buttonStyle(.sc(.tinted, small: true))
                            .disabled(normalized(newDomain) == nil)
                    }
                    Picker("Куда", selection: $target) {
                        ForEach(ExceptionTarget.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text(verbatim: "Правило действует и для поддоменов: example.com включает www.example.com.")
                        .font(.scFoot)
                        .foregroundStyle(Theme.label2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }
                section(.vpn, header: "Всегда через VPN")
                section(.direct, header: "Всегда напрямую")
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
        }
        .scrollIndicators(.hidden)
        .contentMargins(.bottom, 110, for: .scrollContent)
        .background(AppBackground(glow: 0))
        .navigationTitle("Исключения")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: vpnRaw) { app.settingsChanged() }
        .onChange(of: directRaw) { app.settingsChanged() }
    }

    private func section(_ t: ExceptionTarget, header: String) -> some View {
        let items = domains(t)
        return SCSection(header: header) {
            if items.isEmpty {
                SCRow(title: "Пока пусто", titleColor: Theme.label3)
            } else {
                ForEach(Array(items.enumerated()), id: \.element) { index, domain in
                    if index > 0 { SCDivider(inset: 16) }
                    SCRow(title: domain, leading: { EmptyView() }, trailing: {
                        Button {
                            remove(domain, from: t)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .font(.system(size: 20))
                                .foregroundStyle(Theme.red)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Удалить \(domain)")
                    })
                }
            }
        }
    }

    private func domains(_ t: ExceptionTarget) -> [String] {
        (t == .vpn ? vpnRaw : directRaw).split(separator: "\n").map(String.init)
    }

    private func setDomains(_ list: [String], for t: ExceptionTarget) {
        let raw = list.joined(separator: "\n")
        if t == .vpn { vpnRaw = raw } else { directRaw = raw }
    }

    private func remove(_ domain: String, from t: ExceptionTarget) {
        setDomains(domains(t).filter { $0 != domain }, for: t)
    }

    private func normalized(_ s: String) -> String? {
        var d = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let r = d.range(of: "://") { d = String(d[r.upperBound...]) }
        if let slash = d.firstIndex(of: "/") { d = String(d[..<slash]) }
        guard d.contains("."), !d.contains(" "), d.count >= 3 else { return nil }
        return d
    }

    private func add() {
        guard let d = normalized(newDomain) else { return }
        var list = domains(target)
        if !list.contains(d) { list.append(d) }
        setDomains(list, for: target)
        newDomain = ""
    }
}
