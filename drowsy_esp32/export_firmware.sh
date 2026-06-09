#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  DROWSY MONITOR — EXPORT ESP32 FIRMWARE PACKAGE                           ║
# ║  Đóng gói firmware thành 1 thư mục gọn, ai cũng flash được               ║
# ║  Không cần PlatformIO, không cần source code                               ║
# ║                                                                            ║
# ║  Chạy trên máy dev: bash export_firmware.sh                               ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'; MAGENTA='\033[0;35m'

ok()   { echo -e "${GREEN}  ✓${RESET} $*"; }
err()  { echo -e "${RED}  ✗${RESET} $*" >&2; }
info() { echo -e "${CYAN}  →${RESET} $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/.pio/build/esp32dev"
VERSION="${VERSION:-$(date +%Y%m%d)}"
OUTPUT_DIR="${SCRIPT_DIR}/firmware_package_v${VERSION}"

echo -e "${BOLD}${MAGENTA}"
cat << 'BANNER'
    ╔═══════════════════════════════════════════════════╗
    ║   ESP32 FIRMWARE — EXPORT PACKAGE                ║
    ╚═══════════════════════════════════════════════════╝
BANNER
echo -e "${RESET}"

# ── 1. Kiểm tra firmware đã build chưa ──────────────────────────────────────
BINS=("firmware.bin" "bootloader.bin" "partitions.bin")
for b in "${BINS[@]}"; do
  if [[ ! -f "${BUILD_DIR}/${b}" ]]; then
    err "${b} chưa có! Build trước: pio run"
    exit 1
  fi
done
ok "Firmware đã build sẵn"

# ── 2. Tạo thư mục output ───────────────────────────────────────────────────
rm -rf "${OUTPUT_DIR}"
mkdir -p "${OUTPUT_DIR}"

# Copy 3 file binary
cp "${BUILD_DIR}/firmware.bin"    "${OUTPUT_DIR}/"
cp "${BUILD_DIR}/bootloader.bin"  "${OUTPUT_DIR}/"
cp "${BUILD_DIR}/partitions.bin"  "${OUTPUT_DIR}/"

FW_SIZE=$(du -h "${OUTPUT_DIR}/firmware.bin" | cut -f1)
ok "Copied 3 binaries (firmware: ${FW_SIZE})"

# ── 3. Tạo script flash_drowsy.sh (self-contained flasher) ──────────────────
cat > "${OUTPUT_DIR}/flash_drowsy.sh" << 'FLASHEOF'
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
FLASHEOF

chmod +x "${OUTPUT_DIR}/flash_drowsy.sh"
ok "Tạo flash_drowsy.sh"

# ── 4. Tạo README ───────────────────────────────────────────────────────────
cat > "${OUTPUT_DIR}/README.txt" << 'READMEEOF'
═══════════════════════════════════════════════════
  DROWSY MONITOR — ESP32 FIRMWARE PACKAGE
═══════════════════════════════════════════════════

Gồm có:
  - firmware.bin     : Chương trình chính ESP32
  - bootloader.bin   : Bootloader
  - partitions.bin   : Bảng phân vùng
  - flash_drowsy.sh  : Script flash tự động

CÁCH FLASH:
  1. Cài Python3 (nếu chưa có)
  2. Cắm ESP32 vào USB
  3. Mở Terminal, chạy:

     bash flash_drowsy.sh

  Script sẽ tự cài esptool, tìm ESP32, và flash.

SAU KHI FLASH:
  1. ESP32 tạo WiFi hotspot "DROWSY-SETUP-xxxx"
  2. Kết nối điện thoại vào hotspot đó
  3. Mở trình duyệt → nhập WiFi SSID + Password
  4. ESP32 sẽ kết nối WiFi và sẵn sàng hoạt động

RESET WIFI:
  Nhấn giữ nút BOOT trên ESP32 trong 5 giây

═══════════════════════════════════════════════════
READMEEOF

ok "Tạo README.txt"

# ── 5. Tạo file nén ─────────────────────────────────────────────────────────
ARCHIVE="${SCRIPT_DIR}/drowsy_esp32_firmware_v${VERSION}.tar.gz"
cd "${SCRIPT_DIR}"
tar -czf "${ARCHIVE}" "$(basename "${OUTPUT_DIR}")/"
ARCHIVE_SIZE=$(du -h "${ARCHIVE}" | cut -f1)

echo ""
echo -e "${BOLD}${GREEN}══════════════════════════════════════════════════════════════${RESET}"
echo -e "${GREEN}  ✅ ĐÓNG GÓI FIRMWARE HOÀN TẤT!${RESET}"
echo ""
echo -e "  ${BOLD}File:${RESET}      ${ARCHIVE}"
echo -e "  ${BOLD}Kích thước:${RESET} ${ARCHIVE_SIZE}"
echo ""
echo -e "  ${CYAN}Nội dung:${RESET}"
ls -lh "${OUTPUT_DIR}/" | tail -n +2 | while read -r line; do
  echo "    ${line}"
done
echo ""
echo -e "  ${CYAN}Gửi file .tar.gz cho người nhận.${RESET}"
echo -e "  ${CYAN}Họ chỉ cần: giải nén → cắm ESP32 → bash flash_drowsy.sh${RESET}"
echo -e "${BOLD}${GREEN}══════════════════════════════════════════════════════════════${RESET}"
echo ""
