#!/usr/bin/env bash
#
# setup-mac.sh — PrintCam
#
# Installs MediaMTX (and cloudflared) on this Mac via Homebrew, and starts
# MediaMTX as a background service (launchd, via `brew services`) that
# restarts on crash and starts again at login. No sudo required.
#
# Usage:
#   cd printcam
#   ./setup-mac.sh
#
# Safe to re-run: re-running upgrades MediaMTX/cloudflared, reinstalls the
# config, and restarts the service so config edits take effect.

set -euo pipefail

log()  { printf '\033[1;32m[setup-mac]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[setup-mac] UYARI:\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[setup-mac] HATA:\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 0. Preconditions
# ---------------------------------------------------------------------------
if ! command -v brew >/dev/null 2>&1; then
  die "Homebrew bulunamadı. Önce şunu çalıştır: /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\" — sonra bu script'i tekrar çalıştır."
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
LOCAL_CONFIG="$SCRIPT_DIR/mediamtx.yml"
[[ -f "$LOCAL_CONFIG" ]] || die "mediamtx.yml bulunamadı ($LOCAL_CONFIG) — bu script'i printcam/ klasörünün içinden çalıştır."

BREW_PREFIX="$(brew --prefix)"

# ---------------------------------------------------------------------------
# 1. Install MediaMTX + cloudflared via Homebrew
# ---------------------------------------------------------------------------
log "Homebrew ile mediamtx ve cloudflared kuruluyor (zaten kuruluysa atlanır)…"
brew install mediamtx cloudflared

# ---------------------------------------------------------------------------
# 2. Install config
# ---------------------------------------------------------------------------
MTX_CONFIG_DIR="${BREW_PREFIX}/etc/mediamtx"
MTX_CONFIG="${MTX_CONFIG_DIR}/mediamtx.yml"

log "config yerleştiriliyor: $MTX_CONFIG"
mkdir -p "$MTX_CONFIG_DIR"
cp "$LOCAL_CONFIG" "$MTX_CONFIG"

# ---------------------------------------------------------------------------
# 3. Start (or restart) MediaMTX as a background service
# ---------------------------------------------------------------------------
if brew services list | awk '{print $1}' | grep -qx mediamtx 2>/dev/null && \
   brew services list | grep -q '^mediamtx.*started'; then
  log "MediaMTX zaten çalışıyor, config değişikliklerinin uygulanması için yeniden başlatılıyor…"
  brew services restart mediamtx
else
  log "MediaMTX arka plan servisi olarak başlatılıyor (girişte otomatik başlar, çökerse yeniden başlar)…"
  brew services start mediamtx
fi

# ---------------------------------------------------------------------------
# 4. Verify
# ---------------------------------------------------------------------------
sleep 1.5

STATE="$(brew services list | awk '$1=="mediamtx"{print $2}')"
if [[ "$STATE" != "started" ]]; then
  die "servis 'started' durumuna geçmedi (durum: ${STATE:-bilinmiyor}) — 'brew services info mediamtx' ile kontrol et"
fi
log "brew services: mediamtx -> started"

check_port() {
  local port="$1"
  if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
    log "port $port dinleniyor ✓"
  else
    warn "port $port henüz dinlenmiyor — servis daha yeni başlamış olabilir, birkaç saniye sonra 'lsof -nP -iTCP:$port -sTCP:LISTEN' ile tekrar kontrol et."
  fi
}
check_port 1935
check_port 8888

LOG_DIR="${BREW_PREFIX}/var/log/mediamtx"

echo
log "kurulum tamamlandı."
log "RTMP (OBS için):  rtmp://localhost:1935/printer"
log "HLS (viewer için): http://localhost:8888/printer/index.m3u8"
log "durum:   brew services info mediamtx"
log "loglar:  tail -f ${LOG_DIR}/output.log (hatalar için: ${LOG_DIR}/error.log)"
log "config:  ${MTX_CONFIG} (değiştirdikten sonra: brew services restart mediamtx, ya da bu script'i tekrar çalıştır)"
echo
log "sıradaki adım: Cloudflare Tunnel kurulumu için README.md'deki 'Yol A' bölümüne bak."
