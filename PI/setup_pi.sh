#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  DROWSY MONITOR — RASPBERRY PI ONE-CLICK INSTALLER                        ║
# ║  Cài đặt toàn bộ hệ thống nhận diện buồn ngủ trên Raspberry Pi           ║
# ║  Chỉ cần chạy: sudo bash setup_pi.sh                                      ║
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
    
    ════ RASPBERRY PI INSTALLER v1.0 ════

BANNER
echo -e "${RESET}"

# ─── Variables ─────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${INSTALL_DIR:-/home/pi/drowsy_project}"
SERVICE_USER="${SERVICE_USER:-pi}"
SERVICE_GROUP="${SERVICE_GROUP:-${SERVICE_USER}}"
VENV_DIR="${INSTALL_DIR}/.venv"
LOG_FILE="/tmp/drowsy_install_$(date +%Y%m%d_%H%M%S).log"
ERRORS=0

# ─── Pre-flight checks ────────────────────────────────────────────────────────
echo -e "${BOLD}Kiểm tra hệ thống...${RESET}\n"

# Check running as root or with sudo
if [[ $EUID -ne 0 ]]; then
  err "Script này cần chạy với sudo!"
  echo "  Cách dùng: sudo bash setup_pi.sh"
  exit 1
fi
ok "Đang chạy với quyền root"

# Check Raspberry Pi
if [[ -f /proc/device-tree/model ]]; then
  PI_MODEL=$(cat /proc/device-tree/model 2>/dev/null || echo "Unknown")
  ok "Phát hiện: ${PI_MODEL}"
else
  warn "Không chắc là Raspberry Pi — tiếp tục cài đặt..."
fi

# Check internet
if ping -c 1 -W 3 8.8.8.8 &>/dev/null; then
  ok "Kết nối Internet: OK"
else
  err "Không có Internet! Cần kết nối mạng để cài đặt."
  exit 1
fi

# Check disk space (need at least 500MB)
AVAIL_MB=$(df / --output=avail -BM | tail -1 | tr -d 'M ')
if [[ ${AVAIL_MB} -lt 500 ]]; then
  err "Ổ cứng còn ít hơn 500MB! Giải phóng dung lượng trước."
  exit 1
fi
ok "Dung lượng trống: ${AVAIL_MB}MB"

# Check camera
if [[ -e /dev/video0 ]]; then
  ok "Camera USB: /dev/video0 (phát hiện)"
else
  warn "Chưa thấy camera USB (/dev/video0) — có thể cắm sau"
fi

echo ""
echo -e "${BOLD}${GREEN}══ BẮT ĐẦU CÀI ĐẶT ══${RESET}"
echo -e "  Thư mục cài: ${INSTALL_DIR}"
echo -e "  User:        ${SERVICE_USER}"
echo -e "  Log file:    ${LOG_FILE}"
echo ""
read -p "$(echo -e "${YELLOW}Nhấn Enter để bắt đầu (Ctrl+C để hủy)...${RESET}")" _CONFIRM

# ═══════════════════════════════════════════════════════════════════════════════
# BƯỚC 1: CÀI SYSTEM DEPENDENCIES
# ═══════════════════════════════════════════════════════════════════════════════
step "1/7" "Cài đặt packages hệ thống"

info "Đang cập nhật apt..."
apt-get update -y >> "${LOG_FILE}" 2>&1
ok "apt update hoàn tất"

SYSTEM_PACKAGES=(
  python3
  python3-pip
  python3-venv
  python3-opencv
  libopencv-dev
  mosquitto
  mosquitto-clients
  network-manager
  wireless-tools
  iw
  net-tools
  libatlas-base-dev
  libjpeg-dev
  libpng-dev
  libtiff-dev
  libavcodec-dev
  libavformat-dev
  libswscale-dev
  libv4l-dev
  fonts-dejavu-core
)

info "Đang cài ${#SYSTEM_PACKAGES[@]} packages..."
for pkg in "${SYSTEM_PACKAGES[@]}"; do
  if dpkg -s "${pkg}" &>/dev/null; then
    ok "${pkg} (đã có)"
  else
    info "Đang cài ${pkg}..."
    if apt-get install -y "${pkg}" >> "${LOG_FILE}" 2>&1; then
      ok "${pkg} (mới cài)"
    else
      warn "${pkg} (lỗi — xem ${LOG_FILE})"
      ((ERRORS++))
    fi
  fi
done

# ═══════════════════════════════════════════════════════════════════════════════
# BƯỚC 2: CẤU HÌNH MQTT BROKER (Mosquitto)
# ═══════════════════════════════════════════════════════════════════════════════
step "2/7" "Cấu hình MQTT Broker (Mosquitto)"

MQTT_CONF="/etc/mosquitto/conf.d/drowsy.conf"
if [[ -f "${MQTT_CONF}" ]]; then
  ok "Cấu hình Mosquitto đã tồn tại"
else
  cat > "${MQTT_CONF}" <<'MQTTEOF'
# Drowsy Monitor MQTT config
# Cho phép kết nối từ ESP32 và App (không cần password)
listener 1883 0.0.0.0
allow_anonymous true
MQTTEOF
  ok "Đã tạo cấu hình Mosquitto"
fi

systemctl restart mosquitto >> "${LOG_FILE}" 2>&1 || true
systemctl enable mosquitto >> "${LOG_FILE}" 2>&1 || true

if systemctl is-active --quiet mosquitto; then
  ok "Mosquitto đang chạy (port 1883)"
else
  warn "Mosquitto không khởi động được — kiểm tra log"
  ((ERRORS++))
fi

# ═══════════════════════════════════════════════════════════════════════════════
# BƯỚC 3: COPY CODE LÊN THƯ MỤC CÀI ĐẶT
# ═══════════════════════════════════════════════════════════════════════════════
step "3/7" "Copy code vào ${INSTALL_DIR}"

# Create install directory
mkdir -p "${INSTALL_DIR}"
mkdir -p "${INSTALL_DIR}/systemd"

# List of files to copy
PROJECT_FILES=(
  "drowsy_edge.py"
  "edge_data_server.py"
  "esp32_wifi_bridge.py"
  "wait_drowsy_prereqs.sh"
  "install_drowsy_edge_service.sh"
  "install_edge_data_server_service.sh"
  "install_esp32_wifi_sync_service.sh"
)

SYSTEMD_FILES=(
  "systemd/drowsy-edge.service"
  "systemd/edge-data-server.service"
  "systemd/esp32-wifi-sync.service"
)

OPTIONAL_FILES=(
  "benchmark_metrics.py"
  "clean_debug.py"
  "realtime_dashboard.py"
  "face_landmarker.task"
)

# Copy main files
for f in "${PROJECT_FILES[@]}"; do
  if [[ -f "${SCRIPT_DIR}/${f}" ]]; then
    cp "${SCRIPT_DIR}/${f}" "${INSTALL_DIR}/${f}"
    ok "Copied: ${f}"
  else
    err "Thiếu file: ${f}"
    ((ERRORS++))
  fi
done

# Copy systemd files
for f in "${SYSTEMD_FILES[@]}"; do
  if [[ -f "${SCRIPT_DIR}/${f}" ]]; then
    cp "${SCRIPT_DIR}/${f}" "${INSTALL_DIR}/${f}"
    ok "Copied: ${f}"
  else
    err "Thiếu file: ${f}"
    ((ERRORS++))
  fi
done

# Copy optional files (no error if missing)
for f in "${OPTIONAL_FILES[@]}"; do
  if [[ -f "${SCRIPT_DIR}/${f}" ]]; then
    cp "${SCRIPT_DIR}/${f}" "${INSTALL_DIR}/${f}"
    ok "Copied: ${f} (optional)"
  else
    warn "Bỏ qua: ${f} (không bắt buộc)"
  fi
done

# Make scripts executable
chmod +x "${INSTALL_DIR}"/*.sh 2>/dev/null || true

# Set ownership
chown -R "${SERVICE_USER}:${SERVICE_GROUP}" "${INSTALL_DIR}"
ok "Đã set ownership → ${SERVICE_USER}:${SERVICE_GROUP}"

# ═══════════════════════════════════════════════════════════════════════════════
# BƯỚC 4: TẠO PYTHON VIRTUAL ENVIRONMENT & CÀI PACKAGES
# ═══════════════════════════════════════════════════════════════════════════════
step "4/7" "Cài đặt Python environment"

if [[ -d "${VENV_DIR}" ]]; then
  info "Virtual environment đã tồn tại, kiểm tra..."
else
  info "Tạo virtual environment tại ${VENV_DIR}..."
  sudo -u "${SERVICE_USER}" python3 -m venv "${VENV_DIR}" --system-site-packages
  ok "Virtual environment đã tạo"
fi

PYTHON_BIN="${VENV_DIR}/bin/python"
PIP_BIN="${VENV_DIR}/bin/pip"

info "Đang cài Python packages..."
PYTHON_PACKAGES=(
  "mediapipe"
  "paho-mqtt"
  "numpy"
  "pyserial"
  "opencv-python-headless"
)

sudo -u "${SERVICE_USER}" "${PIP_BIN}" install --upgrade pip >> "${LOG_FILE}" 2>&1
for pkg in "${PYTHON_PACKAGES[@]}"; do
  info "Đang cài ${pkg}..."
  if sudo -u "${SERVICE_USER}" "${PIP_BIN}" install "${pkg}" >> "${LOG_FILE}" 2>&1; then
    ok "${pkg}"
  else
    warn "${pkg} (lỗi — xem ${LOG_FILE})"
    ((ERRORS++))
  fi
done

# ═══════════════════════════════════════════════════════════════════════════════
# BƯỚC 5: KIỂM TRA MODEL AI
# ═══════════════════════════════════════════════════════════════════════════════
step "5/7" "Kiểm tra Model AI (MediaPipe)"

MODEL_FILE="${INSTALL_DIR}/face_landmarker.task"
if [[ -f "${MODEL_FILE}" ]]; then
  MODEL_SIZE=$(du -h "${MODEL_FILE}" | cut -f1)
  ok "Model AI: face_landmarker.task (${MODEL_SIZE})"
else
  warn "Model AI chưa có! Đang tải từ Google..."
  MODEL_URL="https://storage.googleapis.com/mediapipe-models/face_landmarker/face_landmarker/float16/latest/face_landmarker.task"
  if sudo -u "${SERVICE_USER}" wget -q -O "${MODEL_FILE}" "${MODEL_URL}" 2>> "${LOG_FILE}"; then
    MODEL_SIZE=$(du -h "${MODEL_FILE}" | cut -f1)
    ok "Đã tải model AI (${MODEL_SIZE})"
  else
    err "Không tải được model AI! Cần copy thủ công."
    echo "  Tải từ: ${MODEL_URL}"
    echo "  Copy vào: ${MODEL_FILE}"
    ((ERRORS++))
  fi
fi

# ═══════════════════════════════════════════════════════════════════════════════
# BƯỚC 6: CÀI ĐẶT 3 SYSTEMD SERVICES
# ═══════════════════════════════════════════════════════════════════════════════
step "6/7" "Cài đặt 3 Systemd Services (tự khởi động khi bật Pi)"

export PYTHON_BIN="${VENV_DIR}/bin/python"
export SERVICE_USER="${SERVICE_USER}"
export SERVICE_GROUP="${SERVICE_GROUP}"

# Service 1: ESP32 WiFi Sync
info "Cài service: esp32-wifi-sync..."
if bash "${INSTALL_DIR}/install_esp32_wifi_sync_service.sh" >> "${LOG_FILE}" 2>&1; then
  ok "esp32-wifi-sync.service ✓"
else
  warn "esp32-wifi-sync.service (lỗi — xem log)"
  ((ERRORS++))
fi

# Service 2: Drowsy Edge AI
info "Cài service: drowsy-edge..."
if bash "${INSTALL_DIR}/install_drowsy_edge_service.sh" >> "${LOG_FILE}" 2>&1; then
  ok "drowsy-edge.service ✓"
else
  warn "drowsy-edge.service (lỗi — xem log)"
  ((ERRORS++))
fi

# Service 3: Edge Data Server (HTTP API)
info "Cài service: edge-data-server..."
if bash "${INSTALL_DIR}/install_edge_data_server_service.sh" >> "${LOG_FILE}" 2>&1; then
  ok "edge-data-server.service ✓"
else
  warn "edge-data-server.service (lỗi — xem log)"
  ((ERRORS++))
fi

# ═══════════════════════════════════════════════════════════════════════════════
# BƯỚC 7: KIỂM TRA TỔNG THỂ
# ═══════════════════════════════════════════════════════════════════════════════
step "7/7" "Kiểm tra tổng thể hệ thống"

echo ""
echo -e "${BOLD}Trạng thái services:${RESET}"

check_service() {
  local svc=$1
  local desc=$2
  if systemctl is-active --quiet "${svc}" 2>/dev/null; then
    echo -e "  ${GREEN}● ${svc}${RESET} — ${desc} ${GREEN}[RUNNING]${RESET}"
  elif systemctl is-enabled --quiet "${svc}" 2>/dev/null; then
    echo -e "  ${YELLOW}○ ${svc}${RESET} — ${desc} ${YELLOW}[ENABLED, NOT RUNNING]${RESET}"
  else
    echo -e "  ${RED}✗ ${svc}${RESET} — ${desc} ${RED}[NOT INSTALLED]${RESET}"
  fi
}

check_service "mosquitto"            "MQTT Broker"
check_service "esp32-wifi-sync"      "WiFi Sync Bridge"
check_service "drowsy-edge"          "AI Detection Engine"
check_service "edge-data-server"     "HTTP API Server"

echo ""
echo -e "${BOLD}Kiểm tra files:${RESET}"
for f in drowsy_edge.py edge_data_server.py esp32_wifi_bridge.py face_landmarker.task; do
  if [[ -f "${INSTALL_DIR}/${f}" ]]; then
    echo -e "  ${GREEN}✓${RESET} ${f}"
  else
    echo -e "  ${RED}✗${RESET} ${f} (thiếu!)"
  fi
done

echo ""
echo -e "${BOLD}Python environment:${RESET}"
if [[ -x "${PYTHON_BIN}" ]]; then
  PY_VER=$("${PYTHON_BIN}" --version 2>&1)
  echo -e "  ${GREEN}✓${RESET} ${PY_VER} (${PYTHON_BIN})"
  echo -e "  ${CYAN}  Packages:${RESET}"
  for pkg in mediapipe paho-mqtt numpy pyserial cv2; do
    if "${PYTHON_BIN}" -c "import ${pkg//-/_}" 2>/dev/null; then
      echo -e "    ${GREEN}✓${RESET} ${pkg}"
    else
      echo -e "    ${RED}✗${RESET} ${pkg} (chưa cài)"
    fi
  done
fi

# ═══════════════════════════════════════════════════════════════════════════════
# KẾT QUẢ
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}${BLUE}══════════════════════════════════════════════════════════════${RESET}"
if [[ ${ERRORS} -eq 0 ]]; then
  echo -e "${BOLD}${GREEN}"
  cat << 'SUCCESS'

    ╔═══════════════════════════════════════════════════╗
    ║                                                   ║
    ║   ✅  CÀI ĐẶT HOÀN TẤT — KHÔNG CÓ LỖI!        ║
    ║                                                   ║
    ║   Hệ thống sẽ tự khởi động khi bật Pi.           ║
    ║   Khởi động lại Pi để kiểm tra:                   ║
    ║     sudo reboot                                   ║
    ║                                                   ║
    ╚═══════════════════════════════════════════════════╝

SUCCESS
  echo -e "${RESET}"
else
  echo -e "${BOLD}${YELLOW}"
  cat << 'PARTIAL'

    ╔═══════════════════════════════════════════════════╗
    ║                                                   ║
    ║   ⚠  CÀI ĐẶT XONG — CÓ MỘT SỐ CẢNH BÁO       ║
    ║                                                   ║
    ╚═══════════════════════════════════════════════════╝

PARTIAL
  echo -e "${RESET}"
  echo -e "  Số lỗi/cảnh báo: ${ERRORS}"
  echo -e "  Xem chi tiết: ${LOG_FILE}"
fi

echo -e "${BOLD}${BLUE}══════════════════════════════════════════════════════════════${RESET}"
echo ""
echo -e "${BOLD}Hướng dẫn nhanh:${RESET}"
echo -e "  ${CYAN}Xem log AI:${RESET}        sudo journalctl -fu drowsy-edge"
echo -e "  ${CYAN}Xem log API:${RESET}       sudo journalctl -fu edge-data-server"
echo -e "  ${CYAN}Xem log WiFi:${RESET}      sudo journalctl -fu esp32-wifi-sync"
echo -e "  ${CYAN}Restart tất cả:${RESET}    sudo systemctl restart drowsy-edge edge-data-server esp32-wifi-sync"
echo -e "  ${CYAN}Stop tất cả:${RESET}       sudo systemctl stop drowsy-edge edge-data-server esp32-wifi-sync"
echo -e "  ${CYAN}Chạy thủ công:${RESET}     cd ${INSTALL_DIR} && ${PYTHON_BIN} drowsy_edge.py"
echo ""
echo -e "  ${CYAN}Log cài đặt:${RESET}       ${LOG_FILE}"
echo ""
