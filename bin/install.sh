#!/usr/bin/env bash
# install.sh — 한도 워치독을 launchd 에 10분 주기로 등록한다.
# 사용법: install.sh [--interval <초>] | install.sh --uninstall

set -euo pipefail
WD_HOME="${WATCHDOG_HOME:-$HOME/watchdog}"
LABEL="com.jinseonghwang.orca-limit-watchdog"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
INTERVAL=600
PYTHON=/usr/bin/python3

MENUBAR_LABEL="com.jinseonghwang.orca-limit-watchdog-menubar"
MENUBAR_PLIST="$HOME/Library/LaunchAgents/$MENUBAR_LABEL.plist"
MENUBAR_BIN="$WD_HOME/bin/watchdog-menubar"

if [ "${1:-}" = "--uninstall" ]; then
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  launchctl bootout "gui/$(id -u)/$MENUBAR_LABEL" 2>/dev/null || true
  rm -f "$PLIST" "$MENUBAR_PLIST"
  pkill -f watchdog-menubar 2>/dev/null || true
  echo "제거했습니다: $LABEL, $MENUBAR_LABEL"
  exit 0
fi
[ "${1:-}" = "--interval" ] && INTERVAL="${2:?초 단위 값이 필요합니다}"

mkdir -p "$HOME/Library/LaunchAgents" "$WD_HOME/logs"

cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$PYTHON</string>
    <string>$WD_HOME/bin/orca-limit-watchdog.py</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict><key>WATCHDOG_HOME</key><string>$WD_HOME</string></dict>
  <key>StartInterval</key><integer>$INTERVAL</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$WD_HOME/logs/launchd.log</string>
  <key>StandardErrorPath</key><string>$WD_HOME/logs/launchd.log</string>
</dict>
</plist>
PLISTEOF

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "등록했습니다: $LABEL (주기 ${INTERVAL}초)"

# 메뉴바 앱은 없으면 먼저 빌드한다.
if [ ! -x "$MENUBAR_BIN" ] && [ -f "$WD_HOME/menubar/main.swift" ]; then
  echo "메뉴바 앱을 빌드합니다"
  swiftc -O -o "$MENUBAR_BIN" "$WD_HOME/menubar/main.swift" -framework AppKit
fi

if [ -x "$MENUBAR_BIN" ]; then
  cat > "$MENUBAR_PLIST" <<MENUEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$MENUBAR_LABEL</string>
  <key>ProgramArguments</key><array><string>$MENUBAR_BIN</string></array>
  <key>EnvironmentVariables</key>
  <dict><key>WATCHDOG_HOME</key><string>$WD_HOME</string></dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key>
  <dict><key>SuccessfulExit</key><false/></dict>
  <key>StandardOutPath</key><string>$WD_HOME/logs/menubar.log</string>
  <key>StandardErrorPath</key><string>$WD_HOME/logs/menubar.log</string>
</dict>
</plist>
MENUEOF
  launchctl bootout "gui/$(id -u)/$MENUBAR_LABEL" 2>/dev/null || true
  pkill -f watchdog-menubar 2>/dev/null || true
  sleep 1
  launchctl bootstrap "gui/$(id -u)" "$MENUBAR_PLIST"
  echo "등록했습니다: $MENUBAR_LABEL (메뉴바 앱, 로그인 시 자동 실행)"
fi

echo
launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null | grep -E "run interval" | head -2
