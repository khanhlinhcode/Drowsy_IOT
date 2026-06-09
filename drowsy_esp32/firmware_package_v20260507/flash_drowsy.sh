#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  DROWSY MONITOR — FLASH ESP32 FIRMWARE                                    ║
# ║  Cắm ESP32 USB → chạy script này → xong!                                 ║
# ║  Yêu cầu: Python3 + pip (esptool sẽ tự cài)                              ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'; MAGENTA='\033[0;35m'

ok()   { echo -e "${GREEN}  ✓${RESET} $*"; }
err()  { echo -e "${RED}  ✗${RESET} $*" >&2; }
info() { echo -e "${CYAN}  →${RESET} $*"; }
warn() { echo -e "${YELLOW}  ⚠${RESET} $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo -e "${BOLD}${MAGENTA}"
echo "  ══════════════════════════════════════════"
echo "   ⚡ DROWSY MONITOR — ESP32 FLASHER"
echo "  ══════════════════════════════════════════"
echo -e "${RESET}"

# ── Bước 1: Kiểm tra Python ─────────────────────────────────────────────────
if ! command -v python3 &>/dev/null; then
  err "Cần cài Python3 trước!"
  echo "  Mac:   brew install python3"
  echo "  Linux: sudo apt install python3 python3-pip"
  exit 1
fi
ok "Python3: $(python3 --version)"

# ── Bước 2: Cài esptool (nếu chưa có) ───────────────────────────────────────
if ! python3 -m esptool version &>/dev/null 2>&1; then
  info "Đang cài esptool..."
  pip3 install esptool --quiet
fi
ok "esptool: $(python3 -m esptool version 2>&1 | head -1)"

# ── Bước 3: Kiểm tra firmware files ─────────────────────────────────────────
for f in firmware.bin bootloader.bin partitions.bin; do
  if [[ ! -f "${SCRIPT_DIR}/${f}" ]]; then
    err "Thiếu file: ${f}"
    exit 1
  fi
done
FW_SIZE=$(du -h "${SCRIPT_DIR}/firmware.bin" | cut -f1)
ok "Firmware: ${FW_SIZE}"

# ── Bước 4: Tìm ESP32 USB port ──────────────────────────────────────────────
ESP32_PORT=""
DETECTED_PORTS=()

# macOS
if [[ "$(uname)" == "Darwin" ]]; then
  while IFS= read -r port; do
    [[ -n "${port}" ]] && DETECTED_PORTS+=("${port}")
  done < <(ls /dev/cu.usbserial-* /dev/cu.SLAB_USBtoUART* /dev/cu.wchusbserial* 2>/dev/null || true)
fi

# Linux
if [[ "$(uname)" == "Linux" ]]; then
  while IFS= read -r port; do
    [[ -n "${port}" ]] && DETECTED_PORTS+=("${port}")
  done < <(ls /dev/ttyUSB* /dev/ttyACM* 2>/dev/null || true)
fi

if [[ ${#DETECTED_PORTS[@]} -eq 0 ]]; then
  err "Không tìm thấy ESP32!"
  echo ""
  echo "  Kiểm tra:"
  echo "  1. ESP32 đã cắm USB chưa?"
  echo "  2. Cáp USB có hỗ trợ data? (không phải cáp sạc)"
  echo "  3. Driver USB đã cài?"
  echo "     Mac CP210x: https://www.silabs.com/developers/usb-to-uart-bridge-vcp-drivers"
  echo "     Mac CH340:  brew install --cask wch-ch34x-usb-serial-driver"
  exit 1
elif [[ ${#DETECTED_PORTS[@]} -eq 1 ]]; then
  ESP32_PORT="${DETECTED_PORTS[0]}"
  ok "ESP32: ${ESP32_PORT}"
else
  echo "  Phát hiện nhiều cổng USB:"
  for i in "${!DETECTED_PORTS[@]}"; do
    echo "    $((i+1)). ${DETECTED_PORTS[$i]}"
  done
  read -p "  Chọn (1-${#DETECTED_PORTS[@]}): " choice
  ESP32_PORT="${DETECTED_PORTS[$((choice-1))]}"
  ok "Đã chọn: ${ESP32_PORT}"
fi

# ── Bước 5: Flash! ──────────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}  ⚡ Sẵn sàng flash firmware lên ESP32${RESET}"
echo -e "${YELLOW}     Port: ${ESP32_PORT}${RESET}"
echo ""
read -p "$(echo -e "${YELLOW}  Nhấn Enter để flash (Ctrl+C để hủy)...${RESET}")" _

info "Đang flash..."
echo ""

python3 -m esptool \
  --chip esp32 \
  --port "${ESP32_PORT}" \
  --baud 460800 \
  --before default_reset \
  --after hard_reset \
  write_flash \
  -z \
  --flash_mode dio \
  --flash_freq 40m \
  --flash_size detect \
  0x1000  "${SCRIPT_DIR}/bootloader.bin" \
  0x8000  "${SCRIPT_DIR}/partitions.bin" \
  0x10000 "${SCRIPT_DIR}/firmware.bin"

echo ""
echo -e "${BOLD}${GREEN}"
echo "  ╔═══════════════════════════════════════════╗"
echo "  ║                                           ║"
echo "  ║   ✅  FLASH THÀNH CÔNG!                  ║"
echo "  ║                                           ║"
echo "  ║   ESP32 đang khởi động lại...             ║"
echo "  ║   Nếu lần đầu: kết nối WiFi hotspot      ║"
echo "  ║   'DROWSY-SETUP-xxxx' để cấu hình.       ║"
echo "  ║                                           ║"
echo "  ╚═══════════════════════════════════════════╝"
echo -e "${RESET}"
