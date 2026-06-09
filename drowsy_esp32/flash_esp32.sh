#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  DROWSY MONITOR — ESP32 ONE-CLICK FLASHER                                 ║
# ║  Build firmware + Flash lên ESP32 chỉ với 1 lệnh                          ║
# ║  Chạy trên máy tính (Mac/Linux/Windows) có cài PlatformIO                 ║
# ║  Cách dùng: bash flash_esp32.sh                                           ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

set -euo pipefail

# ─── Terminal colors ───────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
BLUE='\033[0;34m'; MAGENTA='\033[0;35m'

ok()    { echo -e "${GREEN}  ✓${RESET} $*"; }
warn()  { echo -e "${YELLOW}  ⚠${RESET} $*"; }
err()   { echo -e "${RED}  ✗${RESET} $*" >&2; }
info()  { echo -e "${CYAN}  →${RESET} $*"; }
step()  { echo -e "\n${BOLD}${BLUE}══════════════════════════════════════════════════════════════${RESET}"; \
          echo -e "${BOLD}  BƯỚC $1${RESET}: $2"; \
          echo -e "${BOLD}${BLUE}══════════════════════════════════════════════════════════════${RESET}"; }

# ─── Banner ────────────────────────────────────────────────────────────────────
clear
echo -e "${BOLD}${MAGENTA}"
cat << 'BANNER'

    ██████╗ ██████╗  ██████╗ ██╗    ██╗███████╗██╗   ██╗
    ██╔══██╗██╔══██╗██╔═══██╗██║    ██║██╔════╝╚██╗ ██╔╝
    ██║  ██║██████╔╝██║   ██║██║ █╗ ██║███████╗ ╚████╔╝ 
    ██║  ██║██╔══██╗██║   ██║██║███╗██║╚════██║  ╚██╔╝  
    ██████╔╝██║  ██║╚██████╔╝╚███╔███╔╝███████║   ██║   
    ╚═════╝ ╚═╝  ╚═╝ ╚═════╝  ╚══╝╚══╝ ╚══════╝   ╚═╝   
    
    ════ ESP32 FIRMWARE FLASHER v1.0 ════

BANNER
echo -e "${RESET}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="/tmp/esp32_flash_$(date +%Y%m%d_%H%M%S).log"

# ═══════════════════════════════════════════════════════════════════════════════
# BƯỚC 1: KIỂM TRA PLATFORMIO
# ═══════════════════════════════════════════════════════════════════════════════
step "1/5" "Kiểm tra PlatformIO CLI"

# Try to find pio command
PIO_CMD=""
if command -v pio &>/dev/null; then
  PIO_CMD="pio"
elif command -v platformio &>/dev/null; then
  PIO_CMD="platformio"
elif [[ -f "${HOME}/.platformio/penv/bin/pio" ]]; then
  PIO_CMD="${HOME}/.platformio/penv/bin/pio"
elif [[ -f "${HOME}/.platformio/penv/Scripts/pio.exe" ]]; then
  PIO_CMD="${HOME}/.platformio/penv/Scripts/pio.exe"
fi

if [[ -z "${PIO_CMD}" ]]; then
  err "PlatformIO chưa cài!"
  echo ""
  echo -e "  ${BOLD}Cách cài PlatformIO:${RESET}"
  echo ""
  echo -e "  ${CYAN}Cách 1: Dùng pip (khuyến nghị):${RESET}"
  echo "    pip install platformio"
  echo ""
  echo -e "  ${CYAN}Cách 2: Script cài nhanh:${RESET}"
  echo "    curl -fsSL https://raw.githubusercontent.com/platformio/platformio-core-installer/master/get-platformio.py -o get-platformio.py"
  echo "    python3 get-platformio.py"
  echo ""
  echo -e "  ${CYAN}Cách 3: Dùng VSCode Extension:${RESET}"
  echo "    Cài extension 'PlatformIO IDE' trong VSCode"
  echo ""
  exit 1
fi

PIO_VER=$("${PIO_CMD}" --version 2>&1 || echo "unknown")
ok "PlatformIO: ${PIO_VER}"
ok "Command: ${PIO_CMD}"

# ═══════════════════════════════════════════════════════════════════════════════
# BƯỚC 2: KIỂM TRA PROJECT FILES
# ═══════════════════════════════════════════════════════════════════════════════
step "2/5" "Kiểm tra source code"

REQUIRED_FILES=(
  "platformio.ini"
  "src/main.cpp"
  "src/wifi_manager.cpp"
  "src/wifi_manager.h"
  "src/oled_status.cpp"
  "src/oled_status.h"
  "src/motion_detector.cpp"
  "src/motion_detector.h"
)

ALL_OK=true
for f in "${REQUIRED_FILES[@]}"; do
  if [[ -f "${SCRIPT_DIR}/${f}" ]]; then
    SIZE=$(du -h "${SCRIPT_DIR}/${f}" | cut -f1)
    ok "${f} (${SIZE})"
  else
    err "Thiếu file: ${f}"
    ALL_OK=false
  fi
done

if [[ "${ALL_OK}" != "true" ]]; then
  err "Có file bị thiếu! Kiểm tra lại source code."
  exit 1
fi

# ═══════════════════════════════════════════════════════════════════════════════
# BƯỚC 3: PHÁT HIỆN ESP32 QUA USB
# ═══════════════════════════════════════════════════════════════════════════════
step "3/5" "Tìm ESP32 qua USB"

# Detect USB serial ports
ESP32_PORT=""
DETECTED_PORTS=()

# macOS
if [[ "$(uname)" == "Darwin" ]]; then
  while IFS= read -r port; do
    DETECTED_PORTS+=("${port}")
  done < <(ls /dev/cu.usbserial-* /dev/cu.SLAB_USBtoUART* /dev/cu.wchusbserial* 2>/dev/null || true)
fi

# Linux
if [[ "$(uname)" == "Linux" ]]; then
  while IFS= read -r port; do
    DETECTED_PORTS+=("${port}")
  done < <(ls /dev/ttyUSB* /dev/ttyACM* 2>/dev/null || true)
fi

if [[ ${#DETECTED_PORTS[@]} -eq 0 ]]; then
  err "Không tìm thấy ESP32 trên USB!"
  echo ""
  echo -e "  ${BOLD}Kiểm tra:${RESET}"
  echo "  1. ESP32 đã cắm USB chưa?"
  echo "  2. Cáp USB có hỗ trợ data không? (không phải cáp sạc)"
  echo "  3. Driver USB-to-Serial đã cài chưa?"
  echo ""
  echo -e "  ${CYAN}Cài driver CP210x (Mac):${RESET}"
  echo "    Tải từ: https://www.silabs.com/developers/usb-to-uart-bridge-vcp-drivers"
  echo ""
  echo -e "  ${CYAN}Cài driver CH340 (Mac):${RESET}"
  echo "    brew install --cask wch-ch34x-usb-serial-driver"
  echo ""
  exit 1
elif [[ ${#DETECTED_PORTS[@]} -eq 1 ]]; then
  ESP32_PORT="${DETECTED_PORTS[0]}"
  ok "Phát hiện ESP32: ${ESP32_PORT}"
else
  echo -e "  ${CYAN}Phát hiện nhiều cổng USB:${RESET}"
  for i in "${!DETECTED_PORTS[@]}"; do
    echo "    $((i+1)). ${DETECTED_PORTS[$i]}"
  done
  echo ""
  read -p "  Chọn cổng (1-${#DETECTED_PORTS[@]}): " PORT_CHOICE
  PORT_CHOICE=$((PORT_CHOICE - 1))
  if [[ ${PORT_CHOICE} -ge 0 && ${PORT_CHOICE} -lt ${#DETECTED_PORTS[@]} ]]; then
    ESP32_PORT="${DETECTED_PORTS[$PORT_CHOICE]}"
  else
    err "Lựa chọn không hợp lệ!"
    exit 1
  fi
  ok "Đã chọn: ${ESP32_PORT}"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# BƯỚC 4: BUILD FIRMWARE
# ═══════════════════════════════════════════════════════════════════════════════
step "4/5" "Build firmware ESP32"

info "Đang build (có thể mất 1-3 phút lần đầu)..."
echo ""

if "${PIO_CMD}" run -d "${SCRIPT_DIR}" 2>&1 | tee -a "${LOG_FILE}"; then
  echo ""
  ok "Build thành công!"
  
  # Show firmware size
  FIRMWARE_FILE="${SCRIPT_DIR}/.pio/build/esp32dev/firmware.bin"
  if [[ -f "${FIRMWARE_FILE}" ]]; then
    FW_SIZE=$(du -h "${FIRMWARE_FILE}" | cut -f1)
    ok "Firmware: ${FW_SIZE}"
  fi
else
  echo ""
  err "Build thất bại! Kiểm tra lỗi ở trên."
  echo -e "  Log đầy đủ: ${LOG_FILE}"
  exit 1
fi

# ═══════════════════════════════════════════════════════════════════════════════
# BƯỚC 5: FLASH LÊN ESP32
# ═══════════════════════════════════════════════════════════════════════════════
step "5/5" "Flash firmware lên ESP32"

echo ""
echo -e "  ${YELLOW}⚡ Sắp flash firmware lên ESP32 qua ${ESP32_PORT}${RESET}"
echo -e "  ${YELLOW}   ESP32 sẽ khởi động lại sau khi flash xong.${RESET}"
echo ""
read -p "$(echo -e "${YELLOW}Nhấn Enter để flash (Ctrl+C để hủy)...${RESET}")" _CONFIRM

info "Đang flash..."
echo ""

if "${PIO_CMD}" run -d "${SCRIPT_DIR}" -t upload --upload-port "${ESP32_PORT}" 2>&1 | tee -a "${LOG_FILE}"; then
  echo ""
  echo -e "${BOLD}${GREEN}"
  cat << 'SUCCESS'

    ╔═══════════════════════════════════════════════════╗
    ║                                                   ║
    ║   ✅  FLASH THÀNH CÔNG!                          ║
    ║                                                   ║
    ║   ESP32 đã khởi động lại với firmware mới.        ║
    ║   Nếu là lần đầu: kết nối WiFi hotspot           ║
    ║   "DROWSY-SETUP-xxxx" để cấu hình WiFi.          ║
    ║                                                   ║
    ╚═══════════════════════════════════════════════════╝

SUCCESS
  echo -e "${RESET}"
else
  echo ""
  err "Flash thất bại!"
  echo -e "  ${BOLD}Thử lại:${RESET}"
  echo "  1. Nhấn giữ nút BOOT trên ESP32"
  echo "  2. Chạy lại script này"
  echo "  3. Thả nút BOOT khi thấy 'Connecting...'"
  echo ""
  echo -e "  Log: ${LOG_FILE}"
  exit 1
fi

# ═══════════════════════════════════════════════════════════════════════════════
# HƯỚNG DẪN SAU KHI FLASH
# ═══════════════════════════════════════════════════════════════════════════════
echo -e "${BOLD}Bước tiếp theo:${RESET}"
echo ""
echo -e "  ${CYAN}1. Cấu hình WiFi (lần đầu):${RESET}"
echo "     - Dùng điện thoại kết nối WiFi hotspot 'DROWSY-SETUP-xxxx'"
echo "     - Mở trình duyệt → nhập WiFi SSID + password"
echo ""
echo -e "  ${CYAN}2. Xem Serial monitor:${RESET}"
echo "     ${PIO_CMD} device monitor -p ${ESP32_PORT} -b 115200"
echo ""
echo -e "  ${CYAN}3. Reset WiFi (nếu cần):${RESET}"
echo "     Nhấn giữ nút BOOT trên ESP32 trong 5 giây"
echo ""
echo -e "  ${CYAN}Log:${RESET} ${LOG_FILE}"
echo ""
