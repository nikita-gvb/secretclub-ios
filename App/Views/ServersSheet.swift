import SwiftUI

/// Шторка серверов из капсулы: «Авто», обычные, для мобильной сети, резерв.
struct ServersSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var picked: String?
    @State private var showReserveLink = false

    private let autoID = "__auto"

    var body: some View {
        NavigationStack {
            List {
                Section {
                    autoRow
                        .stagger(0, appeared: appeared, reduce: reduceMotion)
                } footer: {
                    Text("Рекомендуем: «Авто» само переключится, если сменится сеть или сервер перестанет отвечать.")
                }

                if app.routes.isEmpty {
                    Section {
                        HStack(spacing: 12) {
                            Image(systemName: "tray").foregroundStyle(Theme.label2)
                            Text(app.isRefreshing ? "Загружаем серверы…" : "Серверы не загружены")
                            Spacer()
                            if app.isRefreshing { ProgressView() }
                        }
                    } footer: {
                        Text(app.refreshError ?? "Потяните вниз, чтобы обновить подписку.")
                    }
                }

                ForEach(Array([RouteGroup.regular, .bridge].enumerated()), id: \.element) { gi, group in
                    let items = app.routes.filter { $0.group == group }
                    if !items.isEmpty {
                        Section {
                            ForEach(Array(items.enumerated()), id: \.element.id) { i, route in
                                row(route)
                                    .stagger(1 + gi * 2 + i, appeared: appeared, reduce: reduceMotion)
                            }
                        } header: {
                            Text(group.title)
                        } footer: {
                            if group == .bridge { Text(group.subtitle) }
                        }
                    }
                }

                reserveSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Серверы")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task { await app.pingAll() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .rotationEffect(.degrees(app.isMeasuring ? 360 : 0))
                            .animation(app.isMeasuring ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: app.isMeasuring)
                    }
                    .disabled(!app.canPing || app.isMeasuring)
                    .accessibilityLabel("Измерить связь")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Закрыть")
                }
            }
            .refreshable {
                await app.refreshSubscription()
                await app.pingAll()
            }
        }
        .tint(Theme.ink)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(38)
        .sensoryFeedback(.selection, trigger: picked)
        .task {
            appeared = true
            await app.pingIfStale()
        }
        .sheet(isPresented: $showReserveLink) { PasteLinkSheet(reserve: true) }
    }

    // MARK: Строки

    private var isAutoSelected: Bool { picked.map { $0 == autoID } ?? app.autoMode }

    private func isSelected(_ route: Route) -> Bool {
        if let picked { return picked == route.id }
        return !app.autoMode && app.selectedRouteID == route.id
    }

    private var live: Bool { app.power == .connected || app.power == .switching }

    private var autoRow: some View {
        Button { choose(nil) } label: {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.onTint)
                    .frame(width: 34, height: 34)
                    .background(Theme.tint, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Авто").font(.scHeadline).foregroundStyle(Theme.label)
                    Text(autoSubtitle)
                        .font(.scFoot)
                        .foregroundStyle(Theme.label2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                CheckIcon(on: isAutoSelected)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var autoSubtitle: String {
        if app.autoMode, live, let route = app.displayRoute { return "Сейчас: \(route.emoji) \(route.title)" }
        return "Выберем самый быстрый и сами сменим, если что-то пойдёт не так"
    }

    private func row(_ route: Route) -> some View {
        let measuring = app.pingingIDs.contains(route.id)
        let q = route.quality
        let isCurrent = live && app.connectedRouteID == route.id
        return Button { choose(route) } label: {
            HStack(spacing: 12) {
                Flag(emoji: route.emoji)
                VStack(alignment: .leading, spacing: 1) {
                    Text(route.title).font(.sc(17, .medium, relativeTo: .body)).foregroundStyle(q == 0 && !measuring ? Theme.label2 : Theme.label)
                    Text(route.humanDetail + (isCurrent && app.autoMode ? " · сейчас" : ""))
                        .font(.scFoot)
                        .foregroundStyle(Theme.label2)
                }
                .lineLimit(1)
                Spacer(minLength: 8)
                if !measuring, route.id == app.fastestRouteID, !isCurrent {
                    Chip(text: "быстрее всех")
                }
                if !measuring, q == 0 {
                    Text("Недоступен").font(.scFoot).foregroundStyle(Theme.label3)
                }
                QualityBars(level: q, measuring: measuring)
                CheckIcon(on: isSelected(route))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(route.title), \(route.humanDetail), связь \(measuring ? "меряем" : Quality.word(q))")
    }

    // MARK: Резерв

    @ViewBuilder private var reserveSection: some View {
        let group = RouteGroup.reserve
        let items = app.routes.filter { $0.group == group }
        if !items.isEmpty {
            Section {
                ForEach(items) { route in row(route) }
            } header: {
                Text(group.title)
            } footer: {
                Text(group.subtitle)
            }
        } else if !app.routes.isEmpty {
            Section {
                if let reserve = app.reserve {
                    Button { openURL(Config.botLink(start: "traffic")) } label: {
                        SettingsRow(icon: "lifepreserver", color: Theme.orange,
                                    title: reserve.status.isUsable ? "Серверы не загрузились" : reserve.status.title,
                                    subtitle: reserve.status.isUsable ? app.reserveError : "Докупите трафик в Telegram")
                    }
                } else if let account = app.account, account.consentAccepted {
                    Button { Task { await app.createReserve() } } label: {
                        SettingsRow(icon: "gift.fill", color: Theme.green, title: "Получить \(account.freeReserveMB) МБ бесплатно",
                                    loading: app.busyAction == "reserve")
                    }
                    .disabled(app.busyAction != nil)
                } else if !app.hasSession {
                    Button { showReserveLink = true } label: {
                        SettingsRow(icon: "link", color: Theme.gray, title: "Добавить ссылку")
                    }
                }
            } header: {
                Text(group.title)
            } footer: {
                Text(group.subtitle)
            }
        }
    }

    // MARK: Выбор

    private func choose(_ route: Route?) {
        picked = route?.id ?? autoID
        Task {
            try? await Task.sleep(for: .milliseconds(320))
            dismiss()
            try? await Task.sleep(for: .milliseconds(350))
            app.choose(route)
        }
    }
}

/// Галочка выбора: появляется пружиной.
struct CheckIcon: View {
    let on: Bool
    var body: some View {
        ZStack {
            if on {
                Image(systemName: "checkmark")
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            }
        }
        .font(.system(size: 16, weight: .bold))
        .foregroundStyle(Theme.ink)
        .frame(width: 22)
        .animation(.spring(response: 0.32, dampingFraction: 0.7), value: on)
    }
}

private struct StaggerModifier: ViewModifier {
    let index: Int
    let appeared: Bool
    let reduce: Bool
    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared || reduce ? 0 : 14)
            .animation(reduce ? .easeOut(duration: 0.2) : .spring(response: 0.45, dampingFraction: 0.85).delay(Double(min(index, 14)) * 0.028), value: appeared)
    }
}

extension View {
    /// Строки появляются лесенкой: +28 мс на строку, подъём на 14 pt.
    fileprivate func stagger(_ index: Int, appeared: Bool, reduce: Bool) -> some View {
        modifier(StaggerModifier(index: index, appeared: appeared, reduce: reduce))
    }
}
