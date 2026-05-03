#!/usr/bin/env bash
# install_drowsy_edge_service.sh
# Install and enable auto-start service for drowsy_edge.py.

set -euo pipefail

SERVICE_NAME="drowsy-edge.service"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_SERVICE="${SRC_DIR}/systemd/${SERVICE_NAME}"
DST_SERVICE="/etc/systemd/system/${SERVICE_NAME}"

if [[ ! -f "${SRC_SERVICE}" ]]; then
  echo "Missing service template: ${SRC_SERVICE}" >&2
  exit 1
fi
if [[ ! -f "${SRC_DIR}/wait_drowsy_prereqs.sh" ]]; then
  echo "Missing file: ${SRC_DIR}/wait_drowsy_prereqs.sh" >&2
  exit 1
fi

if [[ -n "${PYTHON_BIN:-}" ]]; then
  PY="${PYTHON_BIN}"
elif [[ -x "${SRC_DIR}/.venv/bin/python" ]]; then
  PY="${SRC_DIR}/.venv/bin/python"
else
  PY="$(command -v python3 || true)"
fi

if [[ -z "${PY}" ]]; then
  echo "python3 not found (set PYTHON_BIN=/path/to/python)" >&2
  exit 1
fi

if [[ ! -f "${SRC_DIR}/drowsy_edge.py" ]]; then
  echo "Missing file: ${SRC_DIR}/drowsy_edge.py" >&2
  exit 1
fi

SERVICE_USER="${SERVICE_USER:-pi}"
SERVICE_GROUP="${SERVICE_GROUP:-${SERVICE_USER}}"
DISPLAY_VAL="${DISPLAY_VAL:-:0}"
XAUTHORITY_VAL="${XAUTHORITY_VAL:-/home/${SERVICE_USER}/.Xauthority}"
DISPLAY_WAIT_TIMEOUT_S="${DISPLAY_WAIT_TIMEOUT_S:-120}"
PREVIEW_ON_BOOT="${PREVIEW_ON_BOOT:-1}"
if [[ -n "${DROWSY_EDGE_ARGS:-}" ]]; then
  DROWSY_EDGE_ARGS="${DROWSY_EDGE_ARGS}"
else
  if [[ "${PREVIEW_ON_BOOT}" == "1" ]]; then
    DROWSY_EDGE_ARGS=""
  else
    DROWSY_EDGE_ARGS="--no-preview"
  fi
fi
PI_WIFI_IFACE="${PI_WIFI_INTERFACE:-wlan0}"
WIFI_READY_TIMEOUT_S="${WIFI_READY_TIMEOUT_S:-300}"
REQUIRE_WIFI_AT_START="${REQUIRE_WIFI_AT_START:-1}"
CAMERA_SOURCE="${CAMERA_SOURCE:-0}"
CAMERA_READY_TIMEOUT_S="${CAMERA_READY_TIMEOUT_S:-60}"
QT_QPA_FONTDIR_VAL="${QT_QPA_FONTDIR:-/usr/share/fonts/truetype/dejavu}"
MQTT_BROKER_VAL="${MQTT_BROKER:-127.0.0.1}"
MQTT_PORT_VAL="${MQTT_PORT:-1883}"
MQTT_READY_TIMEOUT_S="${MQTT_READY_TIMEOUT_S:-180}"
REQUIRE_MQTT_AT_START="${REQUIRE_MQTT_AT_START:-1}"
NETWORK_SEND_REQUIRE_WIFI="${NETWORK_SEND_REQUIRE_WIFI:-1}"
NETWORK_CHECK_MS="${NETWORK_CHECK_MS:-1000}"
EDGE_DEVICE_ID_VAL="${EDGE_DEVICE_ID:-rpi-drowsy-edge}"
CLOUD_API_BASE_URL_VAL="${CLOUD_API_BASE_URL:-}"
CLOUD_API_TOKEN_VAL="${CLOUD_API_TOKEN:-}"
CLOUD_PUSH_TIMEOUT_S_VAL="${CLOUD_PUSH_TIMEOUT_S:-1.5}"
CLOUD_HEARTBEAT_MS_VAL="${CLOUD_HEARTBEAT_MS:-300}"
CLOUD_STATUS_MIN_MS_VAL="${CLOUD_STATUS_MIN_MS:-220}"
ESP32_SERIAL="${ESP32_WIFI_SERIAL_PORT:-/dev/ttyUSB0}"
ESP32_BAUD="${ESP32_WIFI_SERIAL_BAUD:-115200}"

escape_sed() {
  printf '%s' "$1" | sed -e 's/[&|/]/\\&/g'
}

WORKDIR_ESC="$(escape_sed "${SRC_DIR}")"
PY_ESC="$(escape_sed "${PY}")"
ARGS_ESC="$(escape_sed "${DROWSY_EDGE_ARGS}")"
SERVICE_USER_ESC="$(escape_sed "${SERVICE_USER}")"
SERVICE_GROUP_ESC="$(escape_sed "${SERVICE_GROUP}")"
DISPLAY_ESC="$(escape_sed "${DISPLAY_VAL}")"
XAUTHORITY_ESC="$(escape_sed "${XAUTHORITY_VAL}")"
DISPLAY_WAIT_ESC="$(escape_sed "${DISPLAY_WAIT_TIMEOUT_S}")"
IFACE_ESC="$(escape_sed "${PI_WIFI_IFACE}")"
WAIT_ESC="$(escape_sed "${WIFI_READY_TIMEOUT_S}")"
REQUIRE_WIFI_AT_START_ESC="$(escape_sed "${REQUIRE_WIFI_AT_START}")"
CAMERA_SOURCE_ESC="$(escape_sed "${CAMERA_SOURCE}")"
CAMERA_WAIT_ESC="$(escape_sed "${CAMERA_READY_TIMEOUT_S}")"
QT_QPA_FONTDIR_ESC="$(escape_sed "${QT_QPA_FONTDIR_VAL}")"
BROKER_ESC="$(escape_sed "${MQTT_BROKER_VAL}")"
PORT_ESC="$(escape_sed "${MQTT_PORT_VAL}")"
MQTT_WAIT_ESC="$(escape_sed "${MQTT_READY_TIMEOUT_S}")"
REQUIRE_MQTT_AT_START_ESC="$(escape_sed "${REQUIRE_MQTT_AT_START}")"
NETWORK_SEND_REQUIRE_WIFI_ESC="$(escape_sed "${NETWORK_SEND_REQUIRE_WIFI}")"
NETWORK_CHECK_MS_ESC="$(escape_sed "${NETWORK_CHECK_MS}")"
EDGE_DEVICE_ID_ESC="$(escape_sed "${EDGE_DEVICE_ID_VAL}")"
CLOUD_API_BASE_URL_ESC="$(escape_sed "${CLOUD_API_BASE_URL_VAL}")"
CLOUD_API_TOKEN_ESC="$(escape_sed "${CLOUD_API_TOKEN_VAL}")"
CLOUD_PUSH_TIMEOUT_S_ESC="$(escape_sed "${CLOUD_PUSH_TIMEOUT_S_VAL}")"
CLOUD_HEARTBEAT_MS_ESC="$(escape_sed "${CLOUD_HEARTBEAT_MS_VAL}")"
CLOUD_STATUS_MIN_MS_ESC="$(escape_sed "${CLOUD_STATUS_MIN_MS_VAL}")"
SERIAL_ESC="$(escape_sed "${ESP32_SERIAL}")"
BAUD_ESC="$(escape_sed "${ESP32_BAUD}")"

TMP_SERVICE="$(mktemp)"
trap 'rm -f "${TMP_SERVICE}"' EXIT

sed \
  -e "s|__WORKDIR__|${WORKDIR_ESC}|g" \
  -e "s|__PYTHON_BIN__|${PY_ESC}|g" \
  -e "s|__DROWSY_EDGE_ARGS__|${ARGS_ESC}|g" \
  -e "s|__SERVICE_USER__|${SERVICE_USER_ESC}|g" \
  -e "s|__SERVICE_GROUP__|${SERVICE_GROUP_ESC}|g" \
  -e "s|__DISPLAY__|${DISPLAY_ESC}|g" \
  -e "s|__XAUTHORITY__|${XAUTHORITY_ESC}|g" \
  -e "s|__DISPLAY_WAIT_TIMEOUT_S__|${DISPLAY_WAIT_ESC}|g" \
  -e "s|__QT_QPA_FONTDIR__|${QT_QPA_FONTDIR_ESC}|g" \
  -e "s|__PI_WIFI_INTERFACE__|${IFACE_ESC}|g" \
  -e "s|__WIFI_READY_TIMEOUT_S__|${WAIT_ESC}|g" \
  -e "s|__REQUIRE_WIFI_AT_START__|${REQUIRE_WIFI_AT_START_ESC}|g" \
  -e "s|__CAMERA_SOURCE__|${CAMERA_SOURCE_ESC}|g" \
  -e "s|__CAMERA_READY_TIMEOUT_S__|${CAMERA_WAIT_ESC}|g" \
  -e "s|__MQTT_BROKER__|${BROKER_ESC}|g" \
  -e "s|__MQTT_PORT__|${PORT_ESC}|g" \
  -e "s|__MQTT_READY_TIMEOUT_S__|${MQTT_WAIT_ESC}|g" \
  -e "s|__REQUIRE_MQTT_AT_START__|${REQUIRE_MQTT_AT_START_ESC}|g" \
  -e "s|__NETWORK_SEND_REQUIRE_WIFI__|${NETWORK_SEND_REQUIRE_WIFI_ESC}|g" \
  -e "s|__NETWORK_CHECK_MS__|${NETWORK_CHECK_MS_ESC}|g" \
  -e "s|__EDGE_DEVICE_ID__|${EDGE_DEVICE_ID_ESC}|g" \
  -e "s|__CLOUD_API_BASE_URL__|${CLOUD_API_BASE_URL_ESC}|g" \
  -e "s|__CLOUD_API_TOKEN__|${CLOUD_API_TOKEN_ESC}|g" \
  -e "s|__CLOUD_PUSH_TIMEOUT_S__|${CLOUD_PUSH_TIMEOUT_S_ESC}|g" \
  -e "s|__CLOUD_HEARTBEAT_MS__|${CLOUD_HEARTBEAT_MS_ESC}|g" \
  -e "s|__CLOUD_STATUS_MIN_MS__|${CLOUD_STATUS_MIN_MS_ESC}|g" \
  -e "s|__ESP32_WIFI_SERIAL_PORT__|${SERIAL_ESC}|g" \
  -e "s|__ESP32_WIFI_SERIAL_BAUD__|${BAUD_ESC}|g" \
  "${SRC_SERVICE}" > "${TMP_SERVICE}"

echo "[1/4] Installing service file -> ${DST_SERVICE}"
sudo install -m 644 "${TMP_SERVICE}" "${DST_SERVICE}"
chmod +x "${SRC_DIR}/wait_drowsy_prereqs.sh"

echo "[2/4] Reloading systemd daemon"
sudo systemctl daemon-reload

echo "[3/4] Enabling service at boot"
sudo systemctl enable "${SERVICE_NAME}"

echo "[4/4] Restarting service now"
sudo systemctl restart "${SERVICE_NAME}"
sleep 1

echo ""
sudo systemctl --no-pager --full status "${SERVICE_NAME}" || true
echo ""
if [[ -n "${CLOUD_API_TOKEN_VAL}" ]]; then
  CLOUD_API_TOKEN_PRINT="(set)"
else
  CLOUD_API_TOKEN_PRINT="(empty)"
fi
echo "Applied config:"
printf "  %-22s %s\n" "WORKDIR" "${SRC_DIR}"
printf "  %-22s %s\n" "PYTHON_BIN" "${PY}"
printf "  %-22s %s\n" "DROWSY_EDGE_ARGS" "${DROWSY_EDGE_ARGS}"
printf "  %-22s %s\n" "SERVICE_USER" "${SERVICE_USER}"
printf "  %-22s %s\n" "SERVICE_GROUP" "${SERVICE_GROUP}"
printf "  %-22s %s\n" "DISPLAY" "${DISPLAY_VAL}"
printf "  %-22s %s\n" "XAUTHORITY" "${XAUTHORITY_VAL}"
printf "  %-22s %s\n" "DISPLAY_WAIT_TIMEOUT_S" "${DISPLAY_WAIT_TIMEOUT_S}"
printf "  %-22s %s\n" "QT_QPA_FONTDIR" "${QT_QPA_FONTDIR_VAL}"
printf "  %-22s %s\n" "PI_WIFI_INTERFACE" "${PI_WIFI_IFACE}"
printf "  %-22s %s\n" "WIFI_READY_TIMEOUT_S" "${WIFI_READY_TIMEOUT_S}"
printf "  %-22s %s\n" "REQUIRE_WIFI_AT_START" "${REQUIRE_WIFI_AT_START}"
printf "  %-22s %s\n" "CAMERA_SOURCE" "${CAMERA_SOURCE}"
printf "  %-22s %s\n" "CAMERA_READY_TIMEOUT_S" "${CAMERA_READY_TIMEOUT_S}"
printf "  %-22s %s\n" "MQTT_BROKER" "${MQTT_BROKER_VAL}"
printf "  %-22s %s\n" "MQTT_PORT" "${MQTT_PORT_VAL}"
printf "  %-22s %s\n" "MQTT_READY_TIMEOUT_S" "${MQTT_READY_TIMEOUT_S}"
printf "  %-22s %s\n" "REQUIRE_MQTT_AT_START" "${REQUIRE_MQTT_AT_START}"
printf "  %-22s %s\n" "NETWORK_SEND_REQUIRE_WIFI" "${NETWORK_SEND_REQUIRE_WIFI}"
printf "  %-22s %s\n" "NETWORK_CHECK_MS" "${NETWORK_CHECK_MS}"
printf "  %-22s %s\n" "EDGE_DEVICE_ID" "${EDGE_DEVICE_ID_VAL}"
printf "  %-22s %s\n" "CLOUD_API_BASE_URL" "${CLOUD_API_BASE_URL_VAL}"
printf "  %-22s %s\n" "CLOUD_API_TOKEN" "${CLOUD_API_TOKEN_PRINT}"
printf "  %-22s %s\n" "CLOUD_PUSH_TIMEOUT_S" "${CLOUD_PUSH_TIMEOUT_S_VAL}"
printf "  %-22s %s\n" "CLOUD_HEARTBEAT_MS" "${CLOUD_HEARTBEAT_MS_VAL}"
printf "  %-22s %s\n" "CLOUD_STATUS_MIN_MS" "${CLOUD_STATUS_MIN_MS_VAL}"
printf "  %-22s %s\n" "ESP32_WIFI_SERIAL_PORT" "${ESP32_SERIAL}"
printf "  %-22s %s\n" "ESP32_WIFI_SERIAL_BAUD" "${ESP32_BAUD}"
echo ""
echo "Monitor: sudo journalctl -fu ${SERVICE_NAME}"
