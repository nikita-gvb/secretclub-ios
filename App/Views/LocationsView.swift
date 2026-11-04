import SwiftUI

struct LocationsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    autoCard
                    ForEach(RouteGroup.allCases) { group in
                        section(group)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 28)
            }
            .scrollIndicators(.hidden)
            .background(AppBackground())
            .navigationTitle("Локации")
        }
    }

    private var autoCard: some View {
        Button {
            app.selectAuto()
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(Theme.gradient)
                    Image(systemName: "sparkles")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 46, height: 46)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Авто").font(.headline)
                    Text("Сам выберет лучший маршрут и переключится, если сеть изменится")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                SelectionMark(selected: app.autoMode)
            }
            .card()
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(app.autoMode ? Theme.accent.opacity(0.6) : .clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }

    private func section(_ group: RouteGroup) -> some View {
        let items = app.routes.filter { $0.group == group }
        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Image(systemName: group.icon).foregroundStyle(group.color)
                    Text(group.title).font(.headline)
                }
                Text(group.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)

            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, route in
                    RouteRow(route: route, selected: !app.autoMode && app.selectedRouteID == route.id) {
                        app.select(route)
                    }
                    if index < items.count - 1 {
                        Divider().padding(.leading, 64)
                    }
                }
            }
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Theme.cardStroke))
        }
    }
}

struct RouteRow: View {
    let route: Route
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                FlagBadge(code: route.countryCode, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(route.country).font(.body.weight(.medium))
                    Text(route.detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                PingLabel(ms: route.ping)
                SelectionMark(selected: selected)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
