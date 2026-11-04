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
  for screen in onboarding home disconnected locations subscription settings diagnostics exceptions; do
    xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
    xcrun simctl launch "$UDID" "$BUNDLE" -AppleLanguages "(ru)" -AppleLocale ru_RU \
      -demo YES -screen "$screen" -theme "$theme" >/dev/null
    if [ $first = 1 ]; then sleep 8; first=0; else sleep 4; fi
    xcrun simctl io "$UDID" screenshot "$OUT/${theme}-${screen}.png" >/dev/null 2>&1
    echo "shot $theme-$screen"
  done
done
xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
