#!/usr/bin/env bash
# install_edge_data_server_service.sh
# Install and enable edge_data_server.py as systemd service.

set -euo pipefail

SERVICE_NAME="edge-data-server.service"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_SERVICE="${SRC_DIR}/systemd/${SERVICE_NAME}"
DST_SERVICE="/etc/systemd/system/${SERVICE_NAME}"

if [[ ! -f "${SRC_SERVICE}" ]]; then
  echo "Missing service template: ${SRC_SERVICE}" >&2
  exit 1
fi
if [[ ! -f "${SRC_DIR}/edge_data_server.py" ]]; then
  echo "Missing file: ${SRC_DIR}/edge_data_server.py" >&2
  exit 1
fi

PYTHON_BIN="${PYTHON_BIN:-$(command -v python3 || true)}"
if [[ -z "${PYTHON_BIN}" ]]; then
  echo "python3 not found (set PYTHON_BIN=/path/to/python3)" >&2
  exit 1
fi

SERVICE_USER="${SERVICE_USER:-pi}"
SERVICE_GROUP="${SERVICE_GROUP:-${SERVICE_USER}}"
EDGE_SERVER_HOST_VAL="${EDGE_SERVER_HOST:-0.0.0.0}"
EDGE_SERVER_PORT_VAL="${EDGE_SERVER_PORT:-8787}"
EDGE_SERVER_DB_VAL="${EDGE_SERVER_DB:-${SRC_DIR}/edge_data_server.db}"
EDGE_SERVER_TOKEN_VAL="${EDGE_SERVER_TOKEN:-}"
EDGE_SERVER_INGEST_TOKEN_VAL="${EDGE_SERVER_INGEST_TOKEN:-${EDGE_SERVER_TOKEN_VAL}}"
EDGE_SERVER_READ_TOKEN_VAL="${EDGE_SERVER_READ_TOKEN:-${EDGE_SERVER_TOKEN_VAL}}"
EDGE_SERVER_CORS_ORIGIN_VAL="${EDGE_SERVER_CORS_ORIGIN:-*}"

escape_sed() {
  printf '%s' "$1" | sed -e 's/[&|/]/\\&/g'
}

WORKDIR_ESC="$(escape_sed "${SRC_DIR}")"
PY_ESC="$(escape_sed "${PYTHON_BIN}")"
SERVICE_USER_ESC="$(escape_sed "${SERVICE_USER}")"
SERVICE_GROUP_ESC="$(escape_sed "${SERVICE_GROUP}")"
HOST_ESC="$(escape_sed "${EDGE_SERVER_HOST_VAL}")"
PORT_ESC="$(escape_sed "${EDGE_SERVER_PORT_VAL}")"
DB_ESC="$(escape_sed "${EDGE_SERVER_DB_VAL}")"
TOKEN_ESC="$(escape_sed "${EDGE_SERVER_TOKEN_VAL}")"
INGEST_TOKEN_ESC="$(escape_sed "${EDGE_SERVER_INGEST_TOKEN_VAL}")"
READ_TOKEN_ESC="$(escape_sed "${EDGE_SERVER_READ_TOKEN_VAL}")"
CORS_ESC="$(escape_sed "${EDGE_SERVER_CORS_ORIGIN_VAL}")"

TMP_SERVICE="$(mktemp)"
trap 'rm -f "${TMP_SERVICE}"' EXIT

sed \
  -e "s|__WORKDIR__|${WORKDIR_ESC}|g" \
  -e "s|__PYTHON_BIN__|${PY_ESC}|g" \
  -e "s|__SERVICE_USER__|${SERVICE_USER_ESC}|g" \
  -e "s|__SERVICE_GROUP__|${SERVICE_GROUP_ESC}|g" \
  -e "s|__EDGE_SERVER_HOST__|${HOST_ESC}|g" \
  -e "s|__EDGE_SERVER_PORT__|${PORT_ESC}|g" \
  -e "s|__EDGE_SERVER_DB__|${DB_ESC}|g" \
  -e "s|__EDGE_SERVER_TOKEN__|${TOKEN_ESC}|g" \
  -e "s|__EDGE_SERVER_INGEST_TOKEN__|${INGEST_TOKEN_ESC}|g" \
  -e "s|__EDGE_SERVER_READ_TOKEN__|${READ_TOKEN_ESC}|g" \
  -e "s|__EDGE_SERVER_CORS_ORIGIN__|${CORS_ESC}|g" \
  "${SRC_SERVICE}" > "${TMP_SERVICE}"

echo "[1/4] Installing service file -> ${DST_SERVICE}"
sudo install -m 644 "${TMP_SERVICE}" "${DST_SERVICE}"

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
if [[ -n "${EDGE_SERVER_TOKEN_VAL}" ]]; then
  TOKEN_PRINT="(set)"
else
  TOKEN_PRINT="(empty)"
fi
if [[ -n "${EDGE_SERVER_INGEST_TOKEN_VAL}" ]]; then
  INGEST_TOKEN_PRINT="(set)"
else
  INGEST_TOKEN_PRINT="(empty)"
fi
if [[ -n "${EDGE_SERVER_READ_TOKEN_VAL}" ]]; then
  READ_TOKEN_PRINT="(set)"
else
  READ_TOKEN_PRINT="(empty)"
fi

echo "Applied config:"
printf "  %-22s %s\n" "WORKDIR" "${SRC_DIR}"
printf "  %-22s %s\n" "PYTHON_BIN" "${PYTHON_BIN}"
printf "  %-22s %s\n" "SERVICE_USER" "${SERVICE_USER}"
printf "  %-22s %s\n" "SERVICE_GROUP" "${SERVICE_GROUP}"
printf "  %-22s %s\n" "EDGE_SERVER_HOST" "${EDGE_SERVER_HOST_VAL}"
printf "  %-22s %s\n" "EDGE_SERVER_PORT" "${EDGE_SERVER_PORT_VAL}"
printf "  %-22s %s\n" "EDGE_SERVER_DB" "${EDGE_SERVER_DB_VAL}"
printf "  %-22s %s\n" "EDGE_SERVER_TOKEN" "${TOKEN_PRINT}"
printf "  %-22s %s\n" "EDGE_SERVER_INGEST_TOKEN" "${INGEST_TOKEN_PRINT}"
printf "  %-22s %s\n" "EDGE_SERVER_READ_TOKEN" "${READ_TOKEN_PRINT}"
printf "  %-22s %s\n" "EDGE_SERVER_CORS_ORIGIN" "${EDGE_SERVER_CORS_ORIGIN_VAL}"
echo ""
echo "Monitor: sudo journalctl -fu ${SERVICE_NAME}"
