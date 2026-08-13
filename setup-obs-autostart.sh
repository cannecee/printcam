#!/usr/bin/env bash
#
# setup-obs-autostart.sh — PrintCam
#
# Makes OBS start itself and begin streaming automatically — no more manual
# "Start Streaming" click. This does NOT remove OBS from the pipeline: a
# direct ffmpeg/VLC replacement for OBS's camera relay was attempted and
# found to be genuinely incompatible with BambuStudio's RTP packetization
# (both ffmpeg's and VLC's H.264 depacketizers fail on it, even though raw
# UDP data demonstrably arrives — see project notes). OBS's own bundled
# ffmpeg handles it correctly, so OBS stays, but runs completely hands-off.
#
# Installs a LaunchAgent that:
#   - launches OBS at login (RunAtLoad)
#   - relaunches OBS automatically if it's quit or crashes (KeepAlive) —
#     same "always-on background service" pattern as mediamtx/cloudflared/
#     bridge.py already running on this Mac
#   - passes --startstreaming so it begins pushing to MediaMTX immediately,
#     no manual click needed
#   - --minimize-to-tray so it doesn't take over the screen
#
# Usage:
#   cd printcam
#   ./setup-obs-autostart.sh
#
# To stop the auto-restart behavior (e.g. to quit OBS and leave it quit):
#   launchctl unload ~/Library/LaunchAgents/com.printcam.obs.plist

set -euo pipefail

log()  { printf '\033[1;32m[setup-obs]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[setup-obs] HATA:\033[0m %s\n' "$*" >&2; exit 1; }

OBS_APP="/Applications/OBS.app"
PLIST_LABEL="com.printcam.obs"
PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"

[[ -d "$OBS_APP" ]] || die "OBS bulunamadı ($OBS_APP) — kurulu olduğundan emin ol."

# Read the scene name from OBS's own scene collection so we start on the
# right scene even if it's not literally named "Scene" on this machine.
SCENE_JSON="$HOME/Library/Application Support/obs-studio/basic/scenes"
DEFAULT_SCENE="Scene"
if [[ -d "$SCENE_JSON" ]]; then
  FIRST_COLLECTION="$(ls "$SCENE_JSON"/*.json 2>/dev/null | head -1 || true)"
  if [[ -n "$FIRST_COLLECTION" ]]; then
    FOUND_SCENE="$(python3 -c "
import json, sys
try:
    d = json.load(open('$FIRST_COLLECTION'))
    print(d.get('current_scene', ''))
except Exception:
    pass
" 2>/dev/null || true)"
    [[ -n "$FOUND_SCENE" ]] && DEFAULT_SCENE="$FOUND_SCENE"
  fi
fi
log "kullanılacak sahne: $DEFAULT_SCENE"

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
        <string>/usr/bin/open</string>
        <string>-W</string>
        <string>-a</string>
        <string>OBS</string>
        <string>--args</string>
        <string>--startstreaming</string>
        <string>--minimize-to-tray</string>
        <string>--disable-missing-files-check</string>
        <string>--multi</string>
        <string>--scene</string>
        <string>${DEFAULT_SCENE}</string>
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

sleep 3
if launchctl list | grep -q "$PLIST_LABEL"; then
  log "OBS otomatik başlatma aktif."
else
  die "servis başlatılamadı."
fi

echo
log "kurulum tamamlandı."
log "OBS artık Mac'e girişte otomatik açılıp yayına başlıyor, çökerse/kapatılırsa yeniden açılıyor."
log "durdurmak için:  launchctl unload ${PLIST_PATH}"
log "not: BambuStudio'nun kamera görünümünün açık olması hâlâ gerekiyor — bu değişmedi."
