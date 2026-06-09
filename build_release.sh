#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  DROWSY MONITOR — ĐÓNG GÓI RELEASE PACKAGE                               ║
# ║  Tạo file .tar.gz chứa toàn bộ code + installer cho ESP32 và Pi           ║
# ║  Chạy trên máy dev (Mac): bash build_release.sh                           ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
MAGENTA='\033[0;35m'

ok()   { echo -e "${GREEN}  ✓${RESET} $*"; }
info() { echo -e "${CYAN}  →${RESET} $*"; }
err()  { echo -e "${RED}  ✗${RESET} $*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="${VERSION:-$(date +%Y%m%d)}"
RELEASE_NAME="drowsy-monitor-v${VERSION}"
BUILD_DIR="${SCRIPT_DIR}/release/${RELEASE_NAME}"
OUTPUT_FILE="${SCRIPT_DIR}/release/${RELEASE_NAME}.tar.gz"

echo -e "${BOLD}${MAGENTA}"
cat << 'BANNER'
    ╔═══════════════════════════════════════════════╗
    ║   DROWSY MONITOR — BUILD RELEASE PACKAGE     ║
    ╚═══════════════════════════════════════════════╝
BANNER
echo -e "${RESET}"

echo -e "  Version: ${VERSION}"
echo -e "  Output:  ${OUTPUT_FILE}"
echo ""

# ─── Clean previous build ─────────────────────────────────────────────────────
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}/PI"
mkdir -p "${BUILD_DIR}/PI/systemd"
mkdir -p "${BUILD_DIR}/ESP32/src"
mkdir -p "${BUILD_DIR}/docs"

# ═══════════════════════════════════════════════════════════════════════════════
# 1. ĐÓNG GÓI RASPBERRY PI
# ═══════════════════════════════════════════════════════════════════════════════
echo -e "${BOLD}[1/4] Đóng gói Raspberry Pi${RESET}"

PI_FILES=(
  "drowsy_edge.py"
  "edge_data_server.py"
  "esp32_wifi_bridge.py"
  "wait_drowsy_prereqs.sh"
  "install_drowsy_edge_service.sh"
  "install_edge_data_server_service.sh"
  "install_esp32_wifi_sync_service.sh"
  "setup_pi.sh"
)

for f in "${PI_FILES[@]}"; do
  if [[ -f "${SCRIPT_DIR}/PI/${f}" ]]; then
    cp "${SCRIPT_DIR}/PI/${f}" "${BUILD_DIR}/PI/${f}"
    ok "${f}"
  else
    err "Thiếu: PI/${f}"
  fi
done

# Systemd files
for f in drowsy-edge.service edge-data-server.service esp32-wifi-sync.service; do
  if [[ -f "${SCRIPT_DIR}/PI/systemd/${f}" ]]; then
    cp "${SCRIPT_DIR}/PI/systemd/${f}" "${BUILD_DIR}/PI/systemd/${f}"
    ok "systemd/${f}"
  fi
done

# Optional files
for f in benchmark_metrics.py clean_debug.py realtime_dashboard.py; do
  if [[ -f "${SCRIPT_DIR}/PI/${f}" ]]; then
    cp "${SCRIPT_DIR}/PI/${f}" "${BUILD_DIR}/PI/${f}"
    ok "${f} (optional)"
  fi
done

# AI Model (if exists)
if [[ -f "${SCRIPT_DIR}/PI/face_landmarker.task" ]]; then
  cp "${SCRIPT_DIR}/PI/face_landmarker.task" "${BUILD_DIR}/PI/"
  ok "face_landmarker.task (AI model)"
else
  info "face_landmarker.task không có — installer sẽ tự tải"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# 2. ĐÓNG GÓI ESP32
# ═══════════════════════════════════════════════════════════════════════════════
echo -e "\n${BOLD}[2/4] Đóng gói ESP32${RESET}"

ESP32_DIR="${SCRIPT_DIR}/drowsy_esp32"
ESP32_FILES=(
  "platformio.ini"
  "flash_esp32.sh"
  "src/main.cpp"
  "src/wifi_manager.cpp"
  "src/wifi_manager.h"
  "src/oled_status.cpp"
  "src/oled_status.h"
  "src/motion_detector.cpp"
  "src/motion_detector.h"
)

for f in "${ESP32_FILES[@]}"; do
  if [[ -f "${ESP32_DIR}/${f}" ]]; then
    dir=$(dirname "${f}")
    mkdir -p "${BUILD_DIR}/ESP32/${dir}"
    cp "${ESP32_DIR}/${f}" "${BUILD_DIR}/ESP32/${f}"
    ok "${f}"
  else
    err "Thiếu: ESP32/${f}"
  fi
done

# Pre-build firmware binary (if exists)
FIRMWARE_BIN="${ESP32_DIR}/.pio/build/esp32dev/firmware.bin"
if [[ -f "${FIRMWARE_BIN}" ]]; then
  mkdir -p "${BUILD_DIR}/ESP32/firmware"
  cp "${FIRMWARE_BIN}" "${BUILD_DIR}/ESP32/firmware/"
  ok "firmware.bin (pre-built binary)"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# 3. ĐÓNG GÓI TÀI LIỆU
# ═══════════════════════════════════════════════════════════════════════════════
echo -e "\n${BOLD}[3/4] Đóng gói tài liệu${RESET}"

# Copy documentation
if [[ -f "${SCRIPT_DIR}/SYSTEM_DOCUMENTATION.md" ]]; then
  cp "${SCRIPT_DIR}/SYSTEM_DOCUMENTATION.md" "${BUILD_DIR}/docs/"
  ok "SYSTEM_DOCUMENTATION.md"
fi
if [[ -f "${SCRIPT_DIR}/README.md" ]]; then
  cp "${SCRIPT_DIR}/README.md" "${BUILD_DIR}/"
  ok "README.md"
fi

# Create INSTALL.md (quick start guide)
cat > "${BUILD_DIR}/INSTALL.md" << 'INSTALLEOF'
# 🚀 HƯỚNG DẪN CÀI ĐẶT NHANH — Drowsy Monitor

## Yêu cầu phần cứng
- Raspberry Pi 4 (2GB RAM trở lên)
- ESP32 DevKit V1
- Camera USB
- Buzzer + LED + OLED SSD1306

---

## 📦 BƯỚC 1: Flash firmware ESP32

### Trên máy tính (Mac/Linux):
```bash
# Cài PlatformIO (nếu chưa có)
pip install platformio

# Cắm ESP32 vào USB, sau đó chạy:
cd ESP32/
bash flash_esp32.sh
```

### Sau khi flash xong:
1. ESP32 sẽ tạo WiFi hotspot `DROWSY-SETUP-xxxx`
2. Kết nối điện thoại vào hotspot đó
3. Nhập WiFi SSID + Password

---

## 🖥️ BƯỚC 2: Cài đặt Raspberry Pi

### Cách 1: One-click installer (khuyến nghị)
```bash
# Copy thư mục PI/ lên Raspberry Pi (qua USB hoặc SCP)
scp -r PI/* pi@raspberrypi.local:~/drowsy_project/

# SSH vào Pi
ssh pi@raspberrypi.local

# Chạy installer
cd ~/drowsy_project
sudo bash setup_pi.sh
```

### Cách 2: Copy qua USB
1. Copy thư mục `PI/` vào USB
2. Cắm USB vào Raspberry Pi
3. Copy files vào `/home/pi/drowsy_project/`
4. Chạy: `sudo bash setup_pi.sh`

---

## ✅ BƯỚC 3: Kiểm tra

Sau khi cài xong, reboot Pi:
```bash
sudo reboot
```

Kiểm tra services:
```bash
sudo systemctl status drowsy-edge
sudo systemctl status edge-data-server
sudo systemctl status esp32-wifi-sync
```

---

## 📱 BƯỚC 4: Cài App Flutter (tùy chọn)

Xem thư mục `sleepy_app/` hoặc tài liệu `SYSTEM_DOCUMENTATION.md`.

---

## 🛠️ Xử lý sự cố

| Vấn đề | Giải pháp |
|--------|-----------|
| ESP32 không kết nối WiFi | Nhấn giữ nút BOOT 5 giây → reset |
| Pi không thấy camera | Kiểm tra `ls /dev/video0` |
| MQTT lỗi | `sudo systemctl restart mosquitto` |
| App không nhận data | Kiểm tra Pi và điện thoại cùng WiFi |
INSTALLEOF

ok "INSTALL.md (hướng dẫn cài đặt)"

# ═══════════════════════════════════════════════════════════════════════════════
# 4. TẠO FILE NÉN
# ═══════════════════════════════════════════════════════════════════════════════
echo -e "\n${BOLD}[4/4] Tạo file nén${RESET}"

mkdir -p "${SCRIPT_DIR}/release"
cd "${SCRIPT_DIR}/release"
tar -czf "${RELEASE_NAME}.tar.gz" "${RELEASE_NAME}/"

ARCHIVE_SIZE=$(du -h "${OUTPUT_FILE}" | cut -f1)
ok "Đã tạo: ${OUTPUT_FILE} (${ARCHIVE_SIZE})"

# ─── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}════════════════════════════════════════════════════════════${RESET}"
echo -e "${BOLD}${GREEN}  ✅ ĐÓNG GÓI HOÀN TẤT!${RESET}"
echo -e "${BOLD}${GREEN}════════════════════════════════════════════════════════════${RESET}"
echo ""
echo -e "  ${BOLD}File release:${RESET} ${OUTPUT_FILE}"
echo -e "  ${BOLD}Kích thước:${RESET}   ${ARCHIVE_SIZE}"
echo ""
echo -e "  ${BOLD}Cấu trúc bên trong:${RESET}"
echo ""
find "${BUILD_DIR}" -type f | sort | while read -r f; do
  rel="${f#${BUILD_DIR}/}"
  size=$(du -h "${f}" | cut -f1)
  echo "    ${rel} (${size})"
done
echo ""
echo -e "  ${CYAN}Gửi file ${RELEASE_NAME}.tar.gz cho người nhận.${RESET}"
echo -e "  ${CYAN}Họ chỉ cần giải nén và chạy installer theo INSTALL.md${RESET}"
echo ""
