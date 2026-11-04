import SwiftUI

struct LocationsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        PageScroll {
            PageHeader(title: "Локации")
            autoOption
            ForEach(RouteGroup.allCases) { group in
                section(group)
            }
        }
    }

    private var autoOption: some View {
        Button {
            app.selectAuto()
        } label: {
            HStack(spacing: 12) {
                CellIcon(systemName: "sparkles", color: Theme.tint, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Авто").font(.scHeadline).foregroundStyle(Theme.label)
                    Text("Сам выберет лучший маршрут и переключится, если сеть изменится")
                        .font(.scFoot)
                        .foregroundStyle(Theme.label2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                CheckMark(on: app.autoMode)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(app.autoMode ? Theme.tint.opacity(0.1) : Theme.cell.opacity(0.9), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(app.autoMode ? Theme.tint.opacity(0.75) : Theme.border, lineWidth: app.autoMode ? 1 : 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.2), value: app.autoMode)
    }

    private func section(_ group: RouteGroup) -> some View {
        let items = app.routes.filter { $0.group == group }
        return SCSection(header: group.title, footer: group.subtitle) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, route in
                if index > 0 { SCDivider(inset: 58) }
                RouteRow(route: route, selected: !app.autoMode && app.selectedRouteID == route.id) {
                    app.select(route)
                }
            }
        }
    }
}

struct RouteRow: View {
    let route: Route
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            SCRow(title: route.country, subtitle: route.detail) {
                Flag(code: route.countryCode)
            } trailing: {
                PingLabel(ms: route.ping)
                Image(systemName: "checkmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.tint)
                    .opacity(selected ? 1 : 0)
                    .frame(width: 18)
            }
        }
        .buttonStyle(RowButtonStyle())
    }
}
