#!/usr/bin/env bash
#
# setup-tunnel-autostart.sh — PrintCam
#
# Makes the Cloudflare Quick Tunnel (cloudflared tunnel --url ...) survive
# reboots/crashes via a LaunchAgent — it was previously just a bare
# background process (`nohup cloudflared ... &`), which does NOT survive a
# real restart. Same pattern as every other service in this project.
#
# IMPORTANT — Quick Tunnels get a NEW random *.trycloudflare.com URL every
# time they start. That means after a real reboot (or any time this
# service restarts), the old URL stops working and viewer/index.html's
# STREAM_URL needs to be updated + redeployed with the new one. This
# script prints the new URL at the end; update STREAM_URL and run
# `npx wrangler deploy` afterwards.
#
# For a URL that never changes across restarts, a real domain + named
# tunnel is required (see README §A.3 alternative) — out of scope here.
#
# Usage:
#   cd printcam
#   ./setup-tunnel-autostart.sh

set -euo pipefail

log()  { printf '\033[1;32m[setup-tunnel]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[setup-tunnel] HATA:\033[0m %s\n' "$*" >&2; exit 1; }

CLOUDFLARED_BIN="$(command -v cloudflared || true)"
[[ -n "$CLOUDFLARED_BIN" ]] || die "cloudflared bulunamadı (brew install cloudflared)."

PLIST_LABEL="com.printcam.tunnel"
PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"
LOG_DIR="$HOME/Library/Logs/printcam-tunnel"
mkdir -p "$LOG_DIR"

log "eski nohup süreci varsa durduruluyor…"
pkill -f "cloudflared tunnel --url http://localhost:8888" 2>/dev/null || true
sleep 1

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
        <string>${CLOUDFLARED_BIN}</string>
        <string>tunnel</string>
        <string>--url</string>
        <string>http://localhost:8888</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${LOG_DIR}/output.log</string>
    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/output.log</string>
</dict>
</plist>
EOF

log "servis (yeniden) yükleniyor…"
launchctl unload "$PLIST_PATH" 2>/dev/null || true
: > "${LOG_DIR}/output.log"
launchctl load "$PLIST_PATH"

log "yeni URL bekleniyor…"
for i in $(seq 1 15); do
  URL="$(grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' "${LOG_DIR}/output.log" 2>/dev/null | head -1 || true)"
  [[ -n "$URL" ]] && break
  sleep 1
done

if launchctl list | grep -q "$PLIST_LABEL"; then
  log "aktif."
else
  die "servis başlatılamadı — ${LOG_DIR}/output.log'a bak."
fi

echo
log "kurulum tamamlandı."
if [[ -n "${URL:-}" ]]; then
  log "YENİ TÜNEL ADRESİ: $URL"
  log "sıradaki adım: viewer/index.html'deki STREAM_URL'i bu adresle güncelle, sonra 'npx wrangler deploy' çalıştır."
else
  log "URL henüz loglara düşmedi, birkaç saniye sonra şu komutla kontrol et:"
  log "  grep trycloudflare ${LOG_DIR}/output.log"
fi
log "durdurmak için:  launchctl unload ${PLIST_PATH}"
