#!/bin/bash
# Делает скриншоты всех экранов в демо-режиме (тёмная и светлая темы).
set -euo pipefail
APP="$1"
UDID="$2"
OUT="${3:-shots}"
BUNDLE=com.secretclub.app
mkdir -p "$OUT"

xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b
xcrun simctl status_bar "$UDID" override --time "9:41" --dataNetwork wifi --wifiMode active --wifiBars 3 \
  --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100 || true
xcrun simctl install "$UDID" "$APP"

first=1
for theme in dark; do
  xcrun simctl ui "$UDID" appearance "$theme" || true
  for screen in onboarding login home disconnected locations subscription settings diagnostics exceptions; do
    xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
    DATA=$(xcrun simctl get_app_container "$UDID" "$BUNDLE" data)
    rm -f "$DATA/Library/Caches/shot-ready"
    xcrun simctl launch "$UDID" "$BUNDLE" -AppleLanguages "(ru)" -AppleLocale ru_RU \
      -demo YES -screen "$screen" -theme "$theme" >/dev/null
    for i in $(seq 1 60); do [ -f "$DATA/Library/Caches/shot-ready" ] && break; sleep 1; done
    [ -f "$DATA/Library/Caches/shot-ready" ] || echo "warn: $screen не подтвердил отрисовку"
    if [ $first = 1 ]; then sleep 3; first=0; else sleep 1.5; fi
    xcrun simctl io "$UDID" screenshot "$OUT/${theme}-${screen}.png" >/dev/null 2>&1
    echo "shot $theme-$screen"
  done
done
xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
# Краш-репорты (если были) — в артефакт
cp ~/Library/Logs/DiagnosticReports/SecretClub* "$OUT/" 2>/dev/null || true
