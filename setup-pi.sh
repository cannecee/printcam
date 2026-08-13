#!/usr/bin/env bash
#
# setup-pi.sh — PrintCam
#
# Installs MediaMTX on a Raspberry Pi (arm64) as a systemd service that
# starts on boot and restarts automatically if it crashes.
#
# Usage:
#   scp -r printcam pi@<pi-ip>:~/printcam
#   ssh pi@<pi-ip>
#   cd ~/printcam
#   sudo ./setup-pi.sh
#
# Safe to re-run: re-running upgrades MediaMTX in place and reinstalls the
# config/service files, restarting the service at the end.

set -euo pipefail

INSTALL_DIR="/opt/mediamtx"
SERVICE_USER="mediamtx"
SERVICE_FILE="/etc/systemd/system/mediamtx.service"
GITHUB_REPO="bluenviron/mediamtx"

log()  { printf '\033[1;32m[setup-pi]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[setup-pi] HATA:\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 0. Preconditions
# ---------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
  die "root olarak çalıştırılmalı, örn: sudo ./setup-pi.sh"
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
LOCAL_CONFIG="$SCRIPT_DIR/mediamtx.yml"
[[ -f "$LOCAL_CONFIG" ]] || die "mediamtx.yml bulunamadı ($LOCAL_CONFIG) — bu script'i printcam/ klasörünün içinden çalıştır."

ARCH="$(uname -m)"
case "$ARCH" in
  aarch64|arm64) MTX_ARCH="linux_arm64" ;;
  armv7l)        MTX_ARCH="linux_armv7" ;;
  *)             die "desteklenmeyen mimari: $ARCH (bu script arm64/armv7 Raspberry Pi için)" ;;
esac

for bin in curl tar; do
  command -v "$bin" >/dev/null 2>&1 || die "gerekli komut bulunamadı: $bin"
done

# ---------------------------------------------------------------------------
# 1. Resolve latest MediaMTX release and download
# ---------------------------------------------------------------------------
log "en son MediaMTX sürümü GitHub'dan sorgulanıyor…"
LATEST_TAG="$(curl -fsSL "https://api.github.com/repos/${GITHUB_REPO}/releases/latest" \
  | grep -m1 '"tag_name"' \
  | sed -E 's/.*"tag_name":[[:space:]]*"([^"]+)".*/\1/')"
[[ -n "$LATEST_TAG" ]] || die "en son sürüm etiketi alınamadı (GitHub API'ye erişim var mı?)"
log "bulunan sürüm: $LATEST_TAG"

# MediaMTX release asset names look like: mediamtx_v1.9.3_linux_arm64.tar.gz
ASSET="mediamtx_${LATEST_TAG}_${MTX_ARCH}.tar.gz"
DOWNLOAD_URL="https://github.com/${GITHUB_REPO}/releases/download/${LATEST_TAG}/${ASSET}"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

log "indiriliyor: $DOWNLOAD_URL"
curl -fL --retry 3 -o "$TMP_DIR/mediamtx.tar.gz" "$DOWNLOAD_URL" \
  || die "indirme başarısız — sürüm/mimari adı değişmiş olabilir, GitHub releases sayfasını kontrol et"

# ---------------------------------------------------------------------------
# 2. Install binary + config
# ---------------------------------------------------------------------------
log "kuruluyor: $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
tar -xzf "$TMP_DIR/mediamtx.tar.gz" -C "$TMP_DIR"
install -m 755 "$TMP_DIR/mediamtx" "$INSTALL_DIR/mediamtx"
install -m 644 "$LOCAL_CONFIG" "$INSTALL_DIR/mediamtx.yml"

# ---------------------------------------------------------------------------
# 3. Dedicated unprivileged service user
# ---------------------------------------------------------------------------
if ! id "$SERVICE_USER" >/dev/null 2>&1; then
  log "servis kullanıcısı oluşturuluyor: $SERVICE_USER"
  useradd --system --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"
fi
chown -R "$SERVICE_USER":"$SERVICE_USER" "$INSTALL_DIR"

# ---------------------------------------------------------------------------
# 4. systemd unit
# ---------------------------------------------------------------------------
log "systemd servisi yazılıyor: $SERVICE_FILE"
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=PrintCam - MediaMTX (RTMP -> HLS)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_USER}
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/mediamtx ${INSTALL_DIR}/mediamtx.yml
Restart=on-failure
RestartSec=5
# Küçük bir hız hatası bile servisi çökmüş sayıp sürekli restart döngüsüne
# sokmasın diye:
StartLimitIntervalSec=60
StartLimitBurst=5

# Hafif hardening
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=${INSTALL_DIR}
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

# ---------------------------------------------------------------------------
# 5. Enable + start
# ---------------------------------------------------------------------------
log "systemd yeniden yükleniyor ve servis başlatılıyor…"
systemctl daemon-reload
systemctl enable --now mediamtx
systemctl restart mediamtx

sleep 1
if systemctl is-active --quiet mediamtx; then
  log "MediaMTX çalışıyor. RTMP :1935, HLS :8888"
else
  die "servis başlatılamadı — 'journalctl -u mediamtx -e' ile logları kontrol et"
fi

log "durum:      systemctl status mediamtx"
log "loglar:     journalctl -u mediamtx -f"
log "config:     ${INSTALL_DIR}/mediamtx.yml (değiştirdikten sonra: systemctl restart mediamtx)"
