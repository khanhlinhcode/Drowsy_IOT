#!/usr/bin/env bash
# install_esp32_wifi_sync_service.sh
# Install and enable the ESP32 WiFi Sync Bridge as a systemd service.
# Run on Raspberry Pi as a regular user (sudo will be requested as needed).

set -euo pipefail

# ─── Terminal colors ───────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
ok()   { echo -e "${GREEN}✓${RESET} $*"; }
warn() { echo -e "${YELLOW}⚠${RESET} $*"; }
err()  { echo -e "${RED}✗${RESET} $*" >&2; }
info() { echo -e "${CYAN}→${RESET} $*"; }
step() { echo -e "\n${BOLD}[$1]${RESET} $2"; }

# ─── Config (override via env vars) ───────────────────────────────────────────
SERVICE_NAME="esp32-wifi-sync.service"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_SERVICE="${SRC_DIR}/systemd/${SERVICE_NAME}"
DST_SERVICE="/etc/systemd/system/${SERVICE_NAME}"
PYTHON_BIN="${PYTHON_BIN:-$(command -v python3 || true)}"
ESP32_SERIAL="${ESP32_WIFI_SERIAL_PORT:-/dev/ttyUSB0}"
ESP32_BAUD="${ESP32_WIFI_SERIAL_BAUD:-115200}"
AUTO_SERIAL_DISCOVERY_VAL="${AUTO_SERIAL_DISCOVERY:-1}"
PI_WIFI_IFACE="${PI_WIFI_INTERFACE:-wlan0}"
WIFI_LOCK="${WIFI_LOCK_TO_ESP32:-1}"
WIFI_REQUIRE_TARGET="${WIFI_REQUIRE_ESP32_TARGET:-1}"
NO_TARGET_DISCONNECT_COOLDOWN="${NO_TARGET_DISCONNECT_COOLDOWN_MS:-15000}"
WIFI_HARD_LOCK_RADIO_VAL="${WIFI_HARD_LOCK_RADIO:-1}"
WIFI_RADIO_TOGGLE_GAP="${WIFI_RADIO_TOGGLE_GAP_MS:-4000}"
WIFI_ENFORCE_RECONNECT_GAP="${WIFI_ENFORCE_RECONNECT_GAP_MS:-1200}"
WIFI_MISMATCH_HOLD="${WIFI_MISMATCH_HOLD_MS:-1800}"
WIFI_LOCK_CHECK="${WIFI_LOCK_CHECK_MS:-2500}"
TARGET_WAIT_GRACE="${ESP32_TARGET_WAIT_GRACE_MS:-30000}"
TARGET_LOSS_GRACE="${ESP32_TARGET_LOSS_GRACE_MS:-30000}"
SERIAL_OFFLINE_GRACE="${ESP32_SERIAL_OFFLINE_GRACE_MS:-1500}"
KEEP_LAST_TARGET_ON_SERIAL_LOSS="${KEEP_LAST_TARGET_WHEN_SERIAL_OFFLINE:-1}"
WIFI_CONNECT_WAIT="${WIFI_CONNECT_WAIT_S:-12}"
WIFI_CONNECT_TIMEOUT="${WIFI_CONNECT_TIMEOUT_S:-20}"
WIFI_RECOVER_AFTER="${WIFI_FAIL_RECOVER_AFTER:-2}"
WIFI_RECOVER_COOLDOWN="${WIFI_FAIL_RECOVER_COOLDOWN_MS:-12000}"
SYNC_REQ_INTERVAL="${ESP32_SYNC_REQUEST_INTERVAL_MS:-1800}"
NO_TARGET_FORCE_SERIAL_REOPEN="${NO_TARGET_FORCE_SERIAL_REOPEN_MS:-12000}"
MQTT_BROKER_VAL="${MQTT_BROKER:-127.0.0.1}"
MQTT_PORT_VAL="${MQTT_PORT:-1883}"
BROKER_HINT_INTERVAL="${BROKER_HINT_INTERVAL_S:-5.0}"
SERIAL_REOPEN_MIN="${SERIAL_REOPEN_MIN_S:-0.4}"
SERIAL_REOPEN_MAX="${SERIAL_REOPEN_MAX_S:-3.0}"

# ─── Pre-flight checks ─────────────────────────────────────────────────────────
step "0/6" "Pre-flight checks"

if [[ ! -f "${SRC_SERVICE}" ]]; then
  err "Missing service template: ${SRC_SERVICE}"
  exit 1
fi

if [[ -z "${PYTHON_BIN}" ]]; then
  err "python3 not found in PATH. Install python3 first."
  exit 1
fi
ok "Python: ${PYTHON_BIN} ($(${PYTHON_BIN} --version 2>&1))"

# Check required runtime deps on Pi
MISSING_DEPS=()
for dep in nmcli ip stty iwgetid; do
  if ! command -v "${dep}" &>/dev/null; then
    MISSING_DEPS+=("${dep}")
  fi
done
if [[ ${#MISSING_DEPS[@]} -gt 0 ]]; then
  warn "Missing commands: ${MISSING_DEPS[*]}"
  warn "Install with: sudo apt-get install -y network-manager iw net-tools"
else
  ok "Runtime deps: nmcli, ip, stty, iwgetid — all found"
fi

# Check NetworkManager is available
if ! systemctl is-active --quiet NetworkManager 2>/dev/null; then
  warn "NetworkManager is not running. WiFi sync may not work correctly."
  warn "Start it with: sudo systemctl enable --now NetworkManager"
else
  ok "NetworkManager: active"
fi

# Check dialout group for serial access
CURRENT_USER="${SUDO_USER:-$(whoami)}"
if id -nG "${CURRENT_USER}" 2>/dev/null | grep -qw dialout; then
  ok "User '${CURRENT_USER}' is in dialout group (serial access OK)"
else
  warn "User '${CURRENT_USER}' is NOT in dialout group."
  warn "Serial port access may fail. Fix with:"
  warn "  sudo usermod -aG dialout ${CURRENT_USER}  (then logout/login)"
fi

# Check serial port exists
if [[ -e "${ESP32_SERIAL}" ]]; then
  ok "Serial port: ${ESP32_SERIAL} (found)"
else
  warn "Serial port: ${ESP32_SERIAL} (not found — check USB connection or set ESP32_WIFI_SERIAL_PORT)"
fi

# ─── Build service file from template ──────────────────────────────────────────
step "1/5" "Building service file from template"

escape_sed() {
  printf '%s' "$1" | sed -e 's/[&|/]/\\&/g'
}

TMP_SERVICE="$(mktemp)"
trap 'rm -f "${TMP_SERVICE}"' EXIT

WORKDIR_ESC="$(escape_sed "${SRC_DIR}")"
PYTHON_ESC="$(escape_sed "${PYTHON_BIN}")"
SERIAL_ESC="$(escape_sed "${ESP32_SERIAL}")"
BAUD_ESC="$(escape_sed "${ESP32_BAUD}")"
AUTO_DISCOVERY_ESC="$(escape_sed "${AUTO_SERIAL_DISCOVERY_VAL}")"
IFACE_ESC="$(escape_sed "${PI_WIFI_IFACE}")"
LOCK_ESC="$(escape_sed "${WIFI_LOCK}")"
REQUIRE_TARGET_ESC="$(escape_sed "${WIFI_REQUIRE_TARGET}")"
NO_TARGET_DISCONNECT_COOLDOWN_ESC="$(escape_sed "${NO_TARGET_DISCONNECT_COOLDOWN}")"
WIFI_HARD_LOCK_RADIO_ESC="$(escape_sed "${WIFI_HARD_LOCK_RADIO_VAL}")"
WIFI_RADIO_TOGGLE_GAP_ESC="$(escape_sed "${WIFI_RADIO_TOGGLE_GAP}")"
WIFI_ENFORCE_RECONNECT_GAP_ESC="$(escape_sed "${WIFI_ENFORCE_RECONNECT_GAP}")"
WIFI_MISMATCH_HOLD_ESC="$(escape_sed "${WIFI_MISMATCH_HOLD}")"
LOCK_CHECK_ESC="$(escape_sed "${WIFI_LOCK_CHECK}")"
TARGET_WAIT_GRACE_ESC="$(escape_sed "${TARGET_WAIT_GRACE}")"
TARGET_LOSS_GRACE_ESC="$(escape_sed "${TARGET_LOSS_GRACE}")"
SERIAL_OFFLINE_GRACE_ESC="$(escape_sed "${SERIAL_OFFLINE_GRACE}")"
KEEP_LAST_TARGET_ON_SERIAL_LOSS_ESC="$(escape_sed "${KEEP_LAST_TARGET_ON_SERIAL_LOSS}")"
WIFI_CONNECT_WAIT_ESC="$(escape_sed "${WIFI_CONNECT_WAIT}")"
WIFI_CONNECT_TIMEOUT_ESC="$(escape_sed "${WIFI_CONNECT_TIMEOUT}")"
WIFI_RECOVER_AFTER_ESC="$(escape_sed "${WIFI_RECOVER_AFTER}")"
WIFI_RECOVER_COOLDOWN_ESC="$(escape_sed "${WIFI_RECOVER_COOLDOWN}")"
SYNC_REQ_INTERVAL_ESC="$(escape_sed "${SYNC_REQ_INTERVAL}")"
NO_TARGET_FORCE_SERIAL_REOPEN_ESC="$(escape_sed "${NO_TARGET_FORCE_SERIAL_REOPEN}")"
BROKER_ESC="$(escape_sed "${MQTT_BROKER_VAL}")"
PORT_ESC="$(escape_sed "${MQTT_PORT_VAL}")"
BROKER_HINT_ESC="$(escape_sed "${BROKER_HINT_INTERVAL}")"
SERIAL_REOPEN_ESC="$(escape_sed "${SERIAL_REOPEN_MIN}")"
SERIAL_REOPEN_MAX_ESC="$(escape_sed "${SERIAL_REOPEN_MAX}")"

sed \
  -e "s|__WORKDIR__|${WORKDIR_ESC}|g" \
  -e "s|__PYTHON_BIN__|${PYTHON_ESC}|g" \
  -e "s|__ESP32_WIFI_SERIAL_PORT__|${SERIAL_ESC}|g" \
  -e "s|__ESP32_WIFI_SERIAL_BAUD__|${BAUD_ESC}|g" \
  -e "s|__AUTO_SERIAL_DISCOVERY__|${AUTO_DISCOVERY_ESC}|g" \
  -e "s|__PI_WIFI_INTERFACE__|${IFACE_ESC}|g" \
  -e "s|__WIFI_LOCK_TO_ESP32__|${LOCK_ESC}|g" \
  -e "s|__WIFI_REQUIRE_ESP32_TARGET__|${REQUIRE_TARGET_ESC}|g" \
  -e "s|__NO_TARGET_DISCONNECT_COOLDOWN_MS__|${NO_TARGET_DISCONNECT_COOLDOWN_ESC}|g" \
  -e "s|__WIFI_HARD_LOCK_RADIO__|${WIFI_HARD_LOCK_RADIO_ESC}|g" \
  -e "s|__WIFI_RADIO_TOGGLE_GAP_MS__|${WIFI_RADIO_TOGGLE_GAP_ESC}|g" \
  -e "s|__WIFI_ENFORCE_RECONNECT_GAP_MS__|${WIFI_ENFORCE_RECONNECT_GAP_ESC}|g" \
  -e "s|__WIFI_MISMATCH_HOLD_MS__|${WIFI_MISMATCH_HOLD_ESC}|g" \
  -e "s|__WIFI_LOCK_CHECK_MS__|${LOCK_CHECK_ESC}|g" \
  -e "s|__ESP32_TARGET_WAIT_GRACE_MS__|${TARGET_WAIT_GRACE_ESC}|g" \
  -e "s|__ESP32_TARGET_LOSS_GRACE_MS__|${TARGET_LOSS_GRACE_ESC}|g" \
  -e "s|__ESP32_SERIAL_OFFLINE_GRACE_MS__|${SERIAL_OFFLINE_GRACE_ESC}|g" \
  -e "s|__KEEP_LAST_TARGET_WHEN_SERIAL_OFFLINE__|${KEEP_LAST_TARGET_ON_SERIAL_LOSS_ESC}|g" \
  -e "s|__WIFI_CONNECT_WAIT_S__|${WIFI_CONNECT_WAIT_ESC}|g" \
  -e "s|__WIFI_CONNECT_TIMEOUT_S__|${WIFI_CONNECT_TIMEOUT_ESC}|g" \
  -e "s|__WIFI_FAIL_RECOVER_AFTER__|${WIFI_RECOVER_AFTER_ESC}|g" \
  -e "s|__WIFI_FAIL_RECOVER_COOLDOWN_MS__|${WIFI_RECOVER_COOLDOWN_ESC}|g" \
  -e "s|__ESP32_SYNC_REQUEST_INTERVAL_MS__|${SYNC_REQ_INTERVAL_ESC}|g" \
  -e "s|__NO_TARGET_FORCE_SERIAL_REOPEN_MS__|${NO_TARGET_FORCE_SERIAL_REOPEN_ESC}|g" \
  -e "s|__MQTT_BROKER__|${BROKER_ESC}|g" \
  -e "s|__MQTT_PORT__|${PORT_ESC}|g" \
  -e "s|__BROKER_HINT_INTERVAL_S__|${BROKER_HINT_ESC}|g" \
  -e "s|__SERIAL_REOPEN_MIN_S__|${SERIAL_REOPEN_ESC}|g" \
  -e "s|__SERIAL_REOPEN_MAX_S__|${SERIAL_REOPEN_MAX_ESC}|g" \
  "${SRC_SERVICE}" > "${TMP_SERVICE}"

ok "Service file built ($(wc -l < "${TMP_SERVICE}") lines)"

# ─── Install service ───────────────────────────────────────────────────────────
step "2/5" "Installing service -> ${DST_SERVICE}"
sudo install -m 644 "${TMP_SERVICE}" "${DST_SERVICE}"
ok "Installed: ${DST_SERVICE}"

step "3/5" "Reloading systemd daemon"
sudo systemctl daemon-reload
ok "systemd reloaded"

step "4/5" "Enabling service at boot"
sudo systemctl enable "${SERVICE_NAME}"
ok "Service enabled"

step "5/5" "Starting service"
sudo systemctl restart "${SERVICE_NAME}"
sleep 1

# ─── Status check ──────────────────────────────────────────────────────────────
echo ""
if systemctl is-active --quiet "${SERVICE_NAME}"; then
  ok "${SERVICE_NAME} is RUNNING ✓"
else
  err "${SERVICE_NAME} is NOT running"
  echo ""
  sudo systemctl --no-pager --full status "${SERVICE_NAME}" || true
  exit 1
fi

echo ""
info "Recent logs:"
sudo journalctl -u "${SERVICE_NAME}" -n 30 --no-pager || true

echo ""
echo -e "${BOLD}Applied config:${RESET}"
printf "  %-32s %s\n" "WORKDIR"                "${SRC_DIR}"
printf "  %-32s %s\n" "PYTHON_BIN"             "${PYTHON_BIN}"
printf "  %-32s %s\n" "ESP32_WIFI_SERIAL_PORT" "${ESP32_SERIAL}"
printf "  %-32s %s\n" "ESP32_WIFI_SERIAL_BAUD" "${ESP32_BAUD}"
printf "  %-32s %s\n" "AUTO_SERIAL_DISCOVERY"  "${AUTO_SERIAL_DISCOVERY_VAL}"
printf "  %-32s %s\n" "PI_WIFI_INTERFACE"      "${PI_WIFI_IFACE}"
printf "  %-32s %s\n" "WIFI_LOCK_TO_ESP32"     "${WIFI_LOCK}"
printf "  %-32s %s\n" "WIFI_REQUIRE_ESP32_TARGET" "${WIFI_REQUIRE_TARGET}"
printf "  %-32s %s\n" "NO_TARGET_DISCONNECT_COOLDOWN_MS" "${NO_TARGET_DISCONNECT_COOLDOWN}"
printf "  %-32s %s\n" "WIFI_HARD_LOCK_RADIO" "${WIFI_HARD_LOCK_RADIO_VAL}"
printf "  %-32s %s\n" "WIFI_RADIO_TOGGLE_GAP_MS" "${WIFI_RADIO_TOGGLE_GAP}"
printf "  %-32s %s\n" "WIFI_ENFORCE_RECONNECT_GAP_MS" "${WIFI_ENFORCE_RECONNECT_GAP}"
printf "  %-32s %s\n" "WIFI_MISMATCH_HOLD_MS" "${WIFI_MISMATCH_HOLD}"
printf "  %-32s %s\n" "ESP32_TARGET_WAIT_GRACE_MS" "${TARGET_WAIT_GRACE}"
printf "  %-32s %s\n" "ESP32_TARGET_LOSS_GRACE_MS" "${TARGET_LOSS_GRACE}"
printf "  %-32s %s\n" "ESP32_SERIAL_OFFLINE_GRACE_MS" "${SERIAL_OFFLINE_GRACE}"
printf "  %-32s %s\n" "KEEP_LAST_TARGET_WHEN_SERIAL_OFFLINE" "${KEEP_LAST_TARGET_ON_SERIAL_LOSS}"
printf "  %-32s %s\n" "WIFI_CONNECT_WAIT_S"    "${WIFI_CONNECT_WAIT}"
printf "  %-32s %s\n" "WIFI_CONNECT_TIMEOUT_S" "${WIFI_CONNECT_TIMEOUT}"
printf "  %-32s %s\n" "WIFI_FAIL_RECOVER_AFTER" "${WIFI_RECOVER_AFTER}"
printf "  %-32s %s\n" "WIFI_FAIL_RECOVER_COOLDOWN_MS" "${WIFI_RECOVER_COOLDOWN}"
printf "  %-32s %s\n" "ESP32_SYNC_REQUEST_INTERVAL_MS" "${SYNC_REQ_INTERVAL}"
printf "  %-32s %s\n" "NO_TARGET_FORCE_SERIAL_REOPEN_MS" "${NO_TARGET_FORCE_SERIAL_REOPEN}"
printf "  %-32s %s\n" "MQTT_BROKER"            "${MQTT_BROKER_VAL}"
printf "  %-32s %s\n" "MQTT_PORT"              "${MQTT_PORT_VAL}"
printf "  %-32s %s\n" "BROKER_HINT_INTERVAL_S" "${BROKER_HINT_INTERVAL}"
printf "  %-32s %s\n" "SERIAL_REOPEN_MIN_S"    "${SERIAL_REOPEN_MIN}"
printf "  %-32s %s\n" "SERIAL_REOPEN_MAX_S"    "${SERIAL_REOPEN_MAX}"

echo ""
ok "Installation complete! To monitor: sudo journalctl -fu ${SERVICE_NAME}"
