import SwiftUI

/// Как включать VPN, не открывая приложение: виджеты, экран блокировки, Пункт управления, Siri.
struct WidgetsHelpView: View {
    var body: some View {
        List {
            Section {
                HelpStep(n: 1, text: "Удерживайте пустое место на экране «Домой», пока иконки не начнут покачиваться.")
                HelpStep(n: 2, text: "Нажмите «Изменить» → «Добавить виджет» (или «+» вверху).")
                HelpStep(n: 3, text: "Найдите SecretClub, выберите размер и нажмите «Добавить виджет».")
            } header: {
                HelpHeader(icon: "square.grid.2x2.fill", color: Theme.blue, title: "Экран «Домой»")
            } footer: {
                Text("Кнопка на виджете включает и выключает VPN сразу, без открытия приложения. Виджет показывает сервер и сколько дней осталось у подписки.")
            }

            Section {
                HelpStep(n: 1, text: "Удерживайте экран блокировки и нажмите «Настроить» → «Экран блокировки».")
                HelpStep(n: 2, text: "Нажмите на поле виджетов под часами и выберите SecretClub.")
            } header: {
                HelpHeader(icon: "lock.iphone", color: .indigo, title: "Экран блокировки")
            } footer: {
                Text("Круглый виджет — переключатель: нажмите, чтобы включить или выключить VPN.")
            }

            if #available(iOS 18.0, *) {
                Section {
                    HelpStep(n: 1, text: "Откройте Пункт управления — смахните вниз от правого верхнего угла.")
                    HelpStep(n: 2, text: "Нажмите «+» в левом верхнем углу → «Добавить элемент управления».")
                    HelpStep(n: 3, text: "Найдите SecretClub и поставьте переключатель, куда удобно.")
                } header: {
                    HelpHeader(icon: "switch.2", color: Theme.gray, title: "Пункт управления")
                } footer: {
                    Text("Тот же переключатель можно поставить на экран блокировки вместо фонарика или камеры, а на iPhone 15 Pro и новее — на кнопку действия.")
                }
            }

            Section {
                HelpPhrase(text: "«Привет, Siri, включи SecretClub»")
                HelpPhrase(text: "«Привет, Siri, выключи SecretClub»")
                HelpPhrase(text: "«Привет, Siri, включён ли SecretClub»")
            } header: {
                HelpHeader(icon: "mic.fill", color: .pink, title: "Siri и «Команды»")
            } footer: {
                Text("Эти же действия есть в приложении «Команды» — например, чтобы включать VPN автоматически, когда открываете определённое приложение.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Виджеты")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct HelpHeader: View {
    let icon: String
    let color: Color
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            SquareIcon(systemName: icon, color: color)
                .scaleEffect(0.8)
            Text(title)
                .font(.scHeadline)
                .foregroundStyle(Theme.label)
                .textCase(nil)
        }
        .padding(.bottom, 2)
    }
}

private struct HelpStep: View {
    let n: Int
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(n)")
                .font(.sc(13, .bold, design: .rounded, relativeTo: .footnote))
                .foregroundStyle(Theme.onTint)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Theme.tint))
            Text(text)
                .font(.scBody)
                .foregroundStyle(Theme.label)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }
}

private struct HelpPhrase: View {
    let text: String

    var body: some View {
        Label {
            Text(text).foregroundStyle(Theme.label)
        } icon: {
            Image(systemName: "waveform").foregroundStyle(.pink)
        }
    }
}
