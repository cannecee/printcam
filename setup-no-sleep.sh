#!/usr/bin/env bash
#
# setup-no-sleep.sh — PrintCam
#
# Keeps this Mac from sleeping, so mediamtx/cloudflared/bridge.py/OBS keep
# running uninterrupted. Uses `caffeinate` (Apple's own no-sleep utility,
# built into macOS) run as a persistent LaunchAgent — same pattern as every
# other background service in this project. This does NOT change any
# System Settings/power management configuration; it just keeps a process
# running that holds a "prevent sleep" assertion for as long as it's alive
# — unload the LaunchAgent and the Mac goes back to its normal sleep
# behavior immediately, nothing persists beyond that.
#
# -d : prevent display sleep
# -i : prevent idle system sleep
# -s : prevent system sleep (AC power)
# (no -u, so this doesn't fight you if you deliberately put the Mac to
#  sleep yourself — closing the lid / Apple menu > Sleep still works,
#  `caffeinate` only blocks the automatic idle timeout)
#
# Usage:
#   cd printcam
#   ./setup-no-sleep.sh
#
# To stop:
#   launchctl unload ~/Library/LaunchAgents/com.printcam.nosleep.plist

set -euo pipefail

log()  { printf '\033[1;32m[setup-no-sleep]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[setup-no-sleep] HATA:\033[0m %s\n' "$*" >&2; exit 1; }

PLIST_LABEL="com.printcam.nosleep"
PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"

command -v caffeinate >/dev/null 2>&1 || die "caffeinate bulunamadı (macOS'ta yerleşik olması gerekiyor, bir şeyler garip)."

log "LaunchAgent yazılıyor: $PLIST_PATH"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${PLIST_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/caffeinate</string>
        <string>-d</string>
        <string>-i</string>
        <string>-s</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
</dict>
</plist>
EOF

log "servis (yeniden) yükleniyor…"
launchctl unload "$PLIST_PATH" 2>/dev/null || true
launchctl load "$PLIST_PATH"

sleep 2
if launchctl list | grep -q "$PLIST_LABEL"; then
  log "aktif — Mac artık otomatik uykuya geçmeyecek."
else
  die "servis başlatılamadı."
fi

echo
log "kurulum tamamlandı."
log "durdurmak için:  launchctl unload ${PLIST_PATH}"
log "not: kapağı kapatmak/elle Uyu demek hâlâ çalışır — bu sadece otomatik boşta-uyku zaman aşımını engeller."
