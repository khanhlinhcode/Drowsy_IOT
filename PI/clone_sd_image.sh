#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  DROWSY MONITOR — CLONE SD CARD IMAGE                                     ║
# ║  Tạo file .img từ SD card Pi đang chạy → ghi vào SD mới = Pi mới chạy    ║
# ║  Hỗ trợ: lưu trên USB, lưu trên Pi (nén trực tiếp), hoặc chạy trên Mac  ║
# ║                                                                            ║
# ║  Chạy: sudo bash clone_sd_image.sh                                        ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'; MAGENTA='\033[0;35m'

ok()   { echo -e "${GREEN}  ✓${RESET} $*"; }
err()  { echo -e "${RED}  ✗${RESET} $*" >&2; }
info() { echo -e "${CYAN}  →${RESET} $*"; }
warn() { echo -e "${YELLOW}  ⚠${RESET} $*"; }

echo -e "${BOLD}${MAGENTA}"
cat << 'BANNER'
    ╔═══════════════════════════════════════════════════╗
    ║  DROWSY MONITOR — SD CARD IMAGE CREATOR          ║
    ║  Clone hệ thống Pi → ghi vào SD mới             ║
    ╚═══════════════════════════════════════════════════╝
BANNER
echo -e "${RESET}"

VERSION="${VERSION:-$(date +%Y%m%d)}"

# ═══════════════════════════════════════════════════════════════════════════════
# DETECT: Đang chạy trên Pi hay Mac?
# ═══════════════════════════════════════════════════════════════════════════════

if [[ "$(uname)" == "Linux" ]] && [[ -f /proc/device-tree/model ]]; then
  # ─── ĐANG CHẠY TRÊN RASPBERRY PI ──────────────────────────────────────────
  echo -e "${BOLD}  Mode: Chạy trên Raspberry Pi${RESET}"
  echo ""

  if [[ $EUID -ne 0 ]]; then
    err "Cần chạy với sudo!"
    echo "  sudo bash clone_sd_image.sh"
    exit 1
  fi

  PI_MODEL=$(cat /proc/device-tree/model 2>/dev/null || echo "Unknown")
  ok "Pi: ${PI_MODEL}"

  # Kiểm tra dung lượng đĩa
  ROOT_USED=$(df / --output=used -BG | tail -1 | tr -d 'G ')
  ROOT_TOTAL=$(df / --output=size -BG | tail -1 | tr -d 'G ')
  ROOT_AVAIL=$(df / --output=avail -BG | tail -1 | tr -d 'G ')
  echo -e "  ${CYAN}SD card:${RESET} ${ROOT_USED}GB used / ${ROOT_TOTAL}GB total / ${ROOT_AVAIL}GB trống"

  # Tính kích thước SD card thực (block device)
  SD_BYTES=$(blockdev --getsize64 /dev/mmcblk0 2>/dev/null || echo "0")
  SD_GB=$(( SD_BYTES / 1073741824 ))
  ok "SD card block size: ${SD_GB}GB"

  # ── Chọn nơi lưu ──────────────────────────────────────────────────────────
  echo ""
  echo -e "${BOLD}  Chọn nơi lưu file image:${RESET}"
  echo ""

  # Tìm USB mount points
  USB_MOUNTS=()
  while IFS= read -r mount; do
    [[ -n "${mount}" ]] && USB_MOUNTS+=("${mount}")
  done < <(lsblk -o MOUNTPOINT -nr | grep -E "^/media|^/mnt" 2>/dev/null || true)

  OPTION_NUM=1

  if [[ ${#USB_MOUNTS[@]} -gt 0 ]]; then
    for i in "${!USB_MOUNTS[@]}"; do
      avail=$(df "${USB_MOUNTS[$i]}" --output=avail -BG | tail -1 | tr -d 'G ')
      echo "    ${OPTION_NUM}. ${USB_MOUNTS[$i]} (${avail}GB trống) [USB]"
      ((OPTION_NUM++))
    done
  fi

  LOCAL_OPTION=${OPTION_NUM}
  echo "    ${OPTION_NUM}. Lưu trên Pi (${ROOT_AVAIL}GB trống) — nén trực tiếp, tải về Mac sau"
  ((OPTION_NUM++))

  CUSTOM_OPTION=${OPTION_NUM}
  echo "    ${OPTION_NUM}. Nhập đường dẫn khác"

  echo ""
  read -p "  Chọn (1-${OPTION_NUM}): " save_choice

  SAVE_LOCAL=false

  if [[ ${save_choice} -eq ${LOCAL_OPTION} ]]; then
    # ── Lưu trên Pi (nén trực tiếp) ─────────────────────────────────────────
    SAVE_LOCAL=true
    OUTPUT_DIR="/home/pi"
    OUTPUT_PATH="${OUTPUT_DIR}/drowsy-pi-v${VERSION}.img.gz"

    # Ước tính file nén (~30-40% kích thước gốc)
    EST_COMPRESSED=$(( SD_GB * 35 / 100 ))
    if [[ ${ROOT_AVAIL} -lt ${EST_COMPRESSED} ]]; then
      warn "Có thể thiếu dung lượng! Cần ~${EST_COMPRESSED}GB, có ${ROOT_AVAIL}GB trống"
      read -p "$(echo -e "${YELLOW}  Tiếp tục? (y/n): ${RESET}")" yn
      [[ "${yn}" != "y" ]] && exit 0
    else
      ok "Đủ dung lượng (~${EST_COMPRESSED}GB cần, ${ROOT_AVAIL}GB có)"
    fi

  elif [[ ${save_choice} -eq ${CUSTOM_OPTION} ]]; then
    read -p "  Nhập đường dẫn: " OUTPUT_DIR
    OUTPUT_PATH="${OUTPUT_DIR}/drowsy-pi-v${VERSION}.img.gz"

  elif [[ ${#USB_MOUNTS[@]} -gt 0 ]] && [[ ${save_choice} -le ${#USB_MOUNTS[@]} ]]; then
    OUTPUT_DIR="${USB_MOUNTS[$((save_choice-1))]}"
    OUTPUT_PATH="${OUTPUT_DIR}/drowsy-pi-v${VERSION}.img.gz"
    AVAIL_USB=$(df "${OUTPUT_DIR}" --output=avail -BG | tail -1 | tr -d 'G ')
    ok "USB: ${OUTPUT_DIR} (${AVAIL_USB}GB trống)"
  else
    err "Lựa chọn không hợp lệ!"
    exit 1
  fi

  echo ""
  echo -e "${YELLOW}  ⚠ Sẽ tạo image từ SD card hiện tại${RESET}"
  echo -e "${YELLOW}    Output: ${OUTPUT_PATH}${RESET}"
  echo -e "${YELLOW}    SD card: ${SD_GB}GB → nén còn ~$((SD_GB * 35 / 100))GB${RESET}"
  echo -e "${YELLOW}    Thời gian: 15-40 phút tùy tốc độ${RESET}"
  echo ""
  read -p "$(echo -e "${YELLOW}  Nhấn Enter để bắt đầu...${RESET}")" _

  # Dọn dẹp trước khi clone
  info "Dọn dẹp cache..."
  apt-get clean 2>/dev/null || true
  journalctl --vacuum-size=10M 2>/dev/null || true
  sync
  ok "Cache đã dọn"

  # ── Clone + nén trực tiếp (dd | gzip pipe) ────────────────────────────────
  info "Đang clone SD card → nén → ${OUTPUT_PATH}"
  info "Đây là quá trình ĐỌC, dữ liệu Pi KHÔNG bị ảnh hưởng!"
  info "(chờ 15-40 phút, đừng tắt máy)"
  echo ""

  # Dùng pipe: dd → gzip → file
  # Không cần lưu file .img thô → tiết kiệm dung lượng!
  dd if=/dev/mmcblk0 bs=4M status=progress 2>&1 | gzip -1 > "${OUTPUT_PATH}"

  sync

  COMPRESSED_SIZE=$(du -h "${OUTPUT_PATH}" | cut -f1)

  echo ""
  echo -e "${BOLD}${GREEN}══════════════════════════════════════════════════════════════${RESET}"
  echo -e "${GREEN}  ✅ TẠO IMAGE HOÀN TẤT!${RESET}"
  echo ""
  echo -e "  ${BOLD}File:${RESET} ${OUTPUT_PATH}"
  echo -e "  ${BOLD}Size:${RESET} ${COMPRESSED_SIZE}"
  echo ""

  if [[ "${SAVE_LOCAL}" == "true" ]]; then
    echo -e "  ${BOLD}Tải về Mac:${RESET}"
    echo -e "  ${CYAN}  scp pi@raspberrypi.local:${OUTPUT_PATH} ~/Desktop/${RESET}"
    echo ""
  fi

  echo -e "  ${BOLD}Ghi vào SD card mới:${RESET}"
  echo "  1. Mở Raspberry Pi Imager"
  echo "  2. Chọn OS → 'Use custom' → chọn file .img.gz"
  echo "  3. Chọn SD card mới → Write"
  echo "  4. Lắp SD card vào Pi mới → Bật nguồn → Chạy!"
  echo -e "${BOLD}${GREEN}══════════════════════════════════════════════════════════════${RESET}"
  echo ""

elif [[ "$(uname)" == "Darwin" ]]; then
  # ─── ĐANG CHẠY TRÊN MAC ───────────────────────────────────────────────────
  echo -e "${BOLD}  Mode: Chạy trên Mac (đọc SD card qua đầu đọc)${RESET}"
  echo ""

  if [[ $EUID -ne 0 ]]; then
    err "Cần chạy với sudo!"
    echo "  sudo bash clone_sd_image.sh"
    exit 1
  fi

  # Liệt kê ổ đĩa
  echo -e "${BOLD}  Các ổ đĩa hiện tại:${RESET}"
  echo ""
  diskutil list external | head -30
  echo ""

  echo -e "${YELLOW}  ⚠ Cắm SD card Pi vào đầu đọc trước!${RESET}"
  echo ""
  read -p "  Nhập disk number của SD card (vd: 4 cho /dev/disk4): " DISK_NUM

  SD_DISK="/dev/disk${DISK_NUM}"
  SD_RDISK="/dev/rdisk${DISK_NUM}"

  if [[ ! -e "${SD_DISK}" ]]; then
    err "Không tìm thấy ${SD_DISK}!"
    exit 1
  fi

  SD_SIZE=$(diskutil info "${SD_DISK}" | grep "Disk Size" | awk '{print $3, $4}')
  ok "SD card: ${SD_DISK} (${SD_SIZE})"

  OUTPUT_PATH="$(pwd)/drowsy-pi-v${VERSION}.img.gz"
  echo ""
  echo -e "${YELLOW}  ⚠ Sẽ clone ${SD_DISK} → ${OUTPUT_PATH}${RESET}"
  echo -e "${RED}  ⚠ CHẮC CHẮN ĐÚNG Ổ ĐĨA! Nhập sai sẽ mất dữ liệu!${RESET}"
  echo ""
  read -p "$(echo -e "${YELLOW}  Gõ 'YES' để xác nhận: ${RESET}")" confirm

  if [[ "${confirm}" != "YES" ]]; then
    echo "  Đã hủy."
    exit 0
  fi

  # Unmount partitions
  info "Unmounting SD card..."
  diskutil unmountDisk "${SD_DISK}" 2>/dev/null || true

  # Clone + nén trực tiếp
  info "Đang clone + nén SD card → ${OUTPUT_PATH}..."
  info "(có thể mất 10-30 phút)"
  echo ""

  dd if="${SD_RDISK}" bs=4m status=progress 2>&1 | gzip -1 > "${OUTPUT_PATH}"

  sync

  COMPRESSED_SIZE=$(du -h "${OUTPUT_PATH}" | cut -f1)
  ok "Clone + nén hoàn tất! (${COMPRESSED_SIZE})"

  echo ""
  echo -e "${BOLD}${GREEN}══════════════════════════════════════════════════════════════${RESET}"
  echo -e "${GREEN}  ✅ TẠO IMAGE HOÀN TẤT!${RESET}"
  echo ""
  echo -e "  ${BOLD}File:${RESET} ${OUTPUT_PATH}"
  echo -e "  ${BOLD}Size:${RESET} ${COMPRESSED_SIZE}"
  echo ""
  echo -e "  ${BOLD}Ghi vào SD mới:${RESET}"
  echo "  1. Mở Raspberry Pi Imager"
  echo "  2. Chọn OS → 'Use custom' → chọn file .img.gz"
  echo "  3. Chọn SD card → Write"
  echo "  4. Lắp SD card vào Pi mới → Bật nguồn → Xong!"
  echo -e "${BOLD}${GREEN}══════════════════════════════════════════════════════════════${RESET}"

else
  err "Hệ điều hành không hỗ trợ. Chạy script này trên Pi hoặc Mac."
  exit 1
fi
