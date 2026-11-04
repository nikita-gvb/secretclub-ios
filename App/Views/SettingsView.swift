import SwiftUI

enum SettingsRoute: Hashable {
    case diagnostics, exceptions
}

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @AppStorage(SettingsKey.theme) private var theme: AppTheme = .dark
    @AppStorage(SettingsKey.autoConnect) private var autoConnect = false
    @AppStorage(SettingsKey.killSwitch) private var killSwitch = false
    @AppStorage(SettingsKey.ruDirect) private var ruDirect = true
    @AppStorage(SettingsKey.energySaver) private var energySaver = true
    @AppStorage(SettingsKey.transport) private var transport: TransportPreference = .auto
    @State private var path: [SettingsRoute] = []
    @State private var appliedInitial = false

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    Picker(selection: $transport) {
                        ForEach(TransportPreference.allCases) { Text($0.title).tag($0) }
                    } label: {
                        SettingsLabel("Протокол", icon: "point.3.connected.trianglepath.dotted", color: Theme.accent)
                    }
                    Toggle(isOn: $autoConnect) {
                        SettingsLabel("Автоподключение", icon: "bolt.fill", color: .orange)
                    }
                    Toggle(isOn: $killSwitch) {
                        SettingsLabel("Без VPN — без сети", icon: "lock.fill", color: .red)
                    }
                } header: {
                    Text("Подключение")
                } footer: {
                    Text("Автоподключение само включит VPN в новой сети. «Без VPN — без сети» не выпустит трафик в обход туннеля.")
                }
                .listRowBackground(Theme.card)

                Section {
                    Toggle(isOn: $ruDirect) {
                        SettingsLabel("Российские сайты напрямую", icon: "house.fill", color: .blue)
                    }
                    NavigationLink(value: SettingsRoute.exceptions) {
                        SettingsLabel("Исключения", icon: "list.bullet", color: .teal)
                    }
                } header: {
                    Text("Маршрутизация")
                } footer: {
                    Text("Госуслуги, банки, маркетплейсы и сайты .ru/.рф открываются без VPN — быстрее и без капч. При белых списках недоступные напрямую сайты пойдут через сервер в России.")
                }
                .listRowBackground(Theme.card)

                Section {
                    Toggle(isOn: $energySaver) {
                        SettingsLabel("Экономия заряда", icon: "leaf.fill", color: .green)
                    }
                } header: {
                    Text("Батарея")
                } footer: {
                    Text("Меньше фоновых проверок и переподключений. Рекомендуем не выключать.")
                }
                .listRowBackground(Theme.card)

                Section("Оформление") {
                    Picker(selection: $theme) {
                        ForEach(AppTheme.allCases) { Text($0.title).tag($0) }
                    } label: {
                        SettingsLabel("Тема", icon: "circle.lefthalf.filled", color: .indigo)
                    }
                }
                .listRowBackground(Theme.card)

                Section("Помощь") {
                    NavigationLink(value: SettingsRoute.diagnostics) {
                        SettingsLabel("Диагностика", icon: "stethoscope", color: .pink)
                    }
                    Link(destination: Config.supportURL) {
                        SettingsLabel("Поддержка в Telegram", icon: "paperplane.fill", color: Theme.telegram)
                    }
                    HStack {
                        SettingsLabel("Версия", icon: "info.circle.fill", color: .gray)
                        Spacer()
                        Text(Config.version).foregroundStyle(.secondary)
                    }
                }
                .listRowBackground(Theme.card)
            }
            .scrollContentBackground(.hidden)
            .background(AppBackground())
            .navigationTitle("Настройки")
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

enum ExceptionTarget: String, CaseIterable, Identifiable {
    case vpn, direct
    var id: String { rawValue }
    var title: String { self == .vpn ? "Через VPN" : "Напрямую" }
}

struct ExceptionsView: View {
    @AppStorage(SettingsKey.vpnDomains) private var vpnRaw = ""
    @AppStorage(SettingsKey.directDomains) private var directRaw = ""
    @State private var newDomain = ""
    @State private var target: ExceptionTarget = .vpn

    var body: some View {
        List {
            Section {
                HStack {
                    TextField("example.com", text: $newDomain)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .onSubmit(add)
                    Button("Добавить", action: add)
                        .disabled(normalized(newDomain) == nil)
                }
                Picker("Куда", selection: $target) {
                    ForEach(ExceptionTarget.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("Правило действует и для поддоменов. Например, example.com включает www.example.com.")
            }
            .listRowBackground(Theme.card)

            Section("Всегда через VPN") { rows(.vpn) }
                .listRowBackground(Theme.card)
            Section("Всегда напрямую") { rows(.direct) }
                .listRowBackground(Theme.card)
        }
        .scrollContentBackground(.hidden)
        .background(AppBackground())
        .navigationTitle("Исключения")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func rows(_ t: ExceptionTarget) -> some View {
        let items = domains(t)
        if items.isEmpty {
            Text("Пока пусто").foregroundStyle(.secondary)
        } else {
            ForEach(items, id: \.self) { Text($0) }
                .onDelete { offsets in
                    var list = domains(t)
                    list.remove(atOffsets: offsets)
                    setDomains(list, for: t)
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
