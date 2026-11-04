# SecretClub iOS

Нативный клиент (SwiftUI + Network Extension).

- Проект генерируется из `project.yml` через XcodeGen.
- Каждый пуш в `main` → GitHub Actions: сборка, скриншоты (светлая/тёмная тема) и неподписанный `SecretClub-unsigned.ipa` в артефактах.
- Демо-режим для скриншотов: аргументы запуска `-demo YES -screen home|locations|subscription|settings|diagnostics|onboarding`.

Статус: 0.1 — интерфейс и пробный туннель (ядро Xray ещё не подключено).
