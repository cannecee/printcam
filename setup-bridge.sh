#!/usr/bin/env bash
#
# setup-bridge.sh — PrintCam telemetry bridge
#
# Sets up bridge.py (Bambu Cloud MQTT -> Cloudflare Worker telemetry) as a
# persistent background service on this Mac via launchd — same reasoning as
# mediamtx/cloudflared running through brew services: a bare `python3
# bridge.py &` process doesn't survive logout/reboot/crashes, a LaunchAgent
# does.
#
# Usage:
#   cd printcam
#   cp bridge_config.example.json bridge_config.json   # then fill in real values
#   ./setup-bridge.sh

set -euo pipefail

log()  { printf '\033[1;32m[setup-bridge]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[setup-bridge] UYARI:\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[setup-bridge] HATA:\033[0m %s\n' "$*" >&2; exit 1; }

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
VENV_DIR="$SCRIPT_DIR/.bridge-venv"
CONFIG_FILE="$SCRIPT_DIR/bridge_config.json"
PLIST_LABEL="com.printcam.bridge"
PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"
LOG_DIR="$SCRIPT_DIR/.bridge-logs"

command -v python3 >/dev/null 2>&1 || die "python3 bulunamadı."

[[ -f "$CONFIG_FILE" ]] || die "bridge_config.json bulunamadı. Önce: cp bridge_config.example.json bridge_config.json, sonra gerçek değerleri gir (bkz. README §Telemetri)."

log "Python venv hazırlanıyor: $VENV_DIR"
python3 -m venv "$VENV_DIR"
"$VENV_DIR/bin/pip" install -q --upgrade pip
"$VENV_DIR/bin/pip" install -q -r "$SCRIPT_DIR/bridge-requirements.txt"

mkdir -p "$LOG_DIR"

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
        <string>${VENV_DIR}/bin/python3</string>
        <string>${SCRIPT_DIR}/bridge.py</string>
    </array>
    <key>WorkingDirectory</key>
    <string>${SCRIPT_DIR}</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${LOG_DIR}/output.log</string>
    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/error.log</string>
</dict>
</plist>
EOF

log "servis (yeniden) yükleniyor…"
launchctl unload "$PLIST_PATH" 2>/dev/null || true
launchctl load "$PLIST_PATH"

sleep 4
if launchctl list | grep -q "$PLIST_LABEL"; then
  log "bridge çalışıyor."
else
  die "servis başlatılamadı — ${LOG_DIR}/error.log'a bak."
fi

echo
log "kurulum tamamlandı."
log "loglar:  tail -f ${LOG_DIR}/output.log (hatalar: ${LOG_DIR}/error.log)"
log "durdur:  launchctl unload ${PLIST_PATH}"
log "yeniden başlat: launchctl unload ${PLIST_PATH} && launchctl load ${PLIST_PATH}"
