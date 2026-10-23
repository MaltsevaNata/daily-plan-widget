#!/usr/bin/env bash
# Builds DailyPlan into ~/.daily-plan and registers a LaunchAgent so it starts at login.
# Re-run after editing DailyPlan.swift to rebuild and restart.
set -euo pipefail

DIR="$HOME/.daily-plan"
LABEL="com.$(id -un).dailyplan"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SRC="$(cd "$(dirname "$0")" && pwd)/DailyPlan.swift"

mkdir -p "$DIR" "$HOME/Library/LaunchAgents"
swiftc -O "$SRC" -o "$DIR/DailyPlan"
echo "Built $DIR/DailyPlan"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>$DIR/DailyPlan</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
EOF

if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
  launchctl kickstart -k "gui/$(id -u)/$LABEL"
  echo "Restarted $LABEL"
else
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
  echo "Started $LABEL (runs at login)"
fi
