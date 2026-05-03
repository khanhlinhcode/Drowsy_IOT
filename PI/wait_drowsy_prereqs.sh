#!/usr/bin/env bash
set -euo pipefail

iface="${PI_WIFI_INTERFACE:-wlan0}"
wifi_timeout="${WIFI_READY_TIMEOUT_S:-300}"
require_wifi="${REQUIRE_WIFI_AT_START:-1}"
camera_source="${CAMERA_SOURCE:-0}"
camera_timeout="${CAMERA_READY_TIMEOUT_S:-60}"
mqtt_host="${MQTT_BROKER:-127.0.0.1}"
mqtt_port="${MQTT_PORT:-1883}"
mqtt_timeout="${MQTT_READY_TIMEOUT_S:-180}"
require_mqtt="${REQUIRE_MQTT_AT_START:-1}"
display_name="${DISPLAY:-:0}"
xauth_path="${XAUTHORITY:-}"
display_timeout="${DISPLAY_WAIT_TIMEOUT_S:-120}"

display_id="${display_name#:}"
display_id="${display_id%%.*}"
if [[ -z "${display_id}" ]]; then
  display_id="0"
fi
x_sock="/tmp/.X11-unix/X${display_id}"

echo "[DROWSY_EDGE] waiting display=${display_name} xauth=${xauth_path:-none} timeout=${display_timeout}s"
for ((i=0; i<display_timeout; i++)); do
  sock_ok=0
  auth_ok=0
  if [[ -S "$x_sock" ]]; then
    sock_ok=1
  fi
  if [[ -n "$xauth_path" && -f "$xauth_path" ]]; then
    auth_ok=1
  elif [[ "$sock_ok" -eq 1 ]]; then
    # Some desktop setups do not create/use ~/.Xauthority for local session.
    auth_ok=1
  fi
  if [[ "$sock_ok" -eq 1 && "$auth_ok" -eq 1 ]]; then
    echo "[DROWSY_EDGE] display ready sock=${x_sock}"
    break
  fi
  sleep 1
done

if [[ ! -S "$x_sock" ]]; then
  echo "[DROWSY_EDGE] display wait timeout (sock=${x_sock})"
  exit 1
fi
if [[ -z "$xauth_path" || ! -f "$xauth_path" ]]; then
  echo "[DROWSY_EDGE] warning: XAUTHORITY missing (${xauth_path:-none}), continue with display socket only"
fi

echo "[DROWSY_EDGE] waiting WiFi iface=${iface} timeout=${wifi_timeout}s"
if [[ "$require_wifi" == "1" ]]; then
  if [[ "$wifi_timeout" =~ ^[0-9]+$ ]] && [[ "$wifi_timeout" -gt 0 ]]; then
    wifi_deadline=$((SECONDS + wifi_timeout))
  else
    wifi_deadline=0
  fi
  while true; do
    ssid="$(iwgetid "$iface" -r 2>/dev/null || true)"
    ip="$(ip -4 -o addr show dev "$iface" scope global 2>/dev/null | head -n1 | tr -s " " | cut -d" " -f4 | cut -d/ -f1)"
    if [[ -n "$ssid" && -n "$ip" ]]; then
      echo "[DROWSY_EDGE] WiFi ready ssid=${ssid} ip=${ip}"
      break
    fi
    if [[ "$wifi_deadline" -gt 0 ]] && [[ "$SECONDS" -ge "$wifi_deadline" ]]; then
      echo "[DROWSY_EDGE] WiFi wait timeout (${wifi_timeout}s) -> keep waiting (required)"
      wifi_deadline=$((SECONDS + wifi_timeout))
    fi
    sleep 1
  done
else
  ssid="$(iwgetid "$iface" -r 2>/dev/null || true)"
  ip="$(ip -4 -o addr show dev "$iface" scope global 2>/dev/null | head -n1 | tr -s " " | cut -d" " -f4 | cut -d/ -f1)"
  if [[ -n "$ssid" && -n "$ip" ]]; then
    echo "[DROWSY_EDGE] WiFi ready ssid=${ssid} ip=${ip}"
  else
    echo "[DROWSY_EDGE] WiFi not ready -> start in WAIT mode"
  fi
fi

if [[ "$camera_source" =~ ^[0-9]+$ ]]; then
  camera_dev="/dev/video${camera_source}"
elif [[ "$camera_source" == /* ]]; then
  camera_dev="$camera_source"
else
  camera_dev=""
fi

if [[ -n "$camera_dev" ]]; then
  echo "[DROWSY_EDGE] waiting camera dev=${camera_dev} timeout=${camera_timeout}s"
  for ((i=0; i<camera_timeout; i++)); do
    if [[ -e "$camera_dev" ]]; then
      echo "[DROWSY_EDGE] camera ready dev=${camera_dev}"
      break
    fi
    sleep 1
  done
  if [[ ! -e "$camera_dev" ]]; then
    echo "[DROWSY_EDGE] camera wait timeout dev=${camera_dev}"
    exit 1
  fi
else
  echo "[DROWSY_EDGE] camera source=${camera_source} (non-device), skip device wait"
fi

echo "[DROWSY_EDGE] waiting MQTT ${mqtt_host}:${mqtt_port} timeout=${mqtt_timeout}s"
if [[ "$require_mqtt" == "1" ]]; then
  if [[ "$mqtt_timeout" =~ ^[0-9]+$ ]] && [[ "$mqtt_timeout" -gt 0 ]]; then
    mqtt_deadline=$((SECONDS + mqtt_timeout))
  else
    mqtt_deadline=0
  fi
  while true; do
    if (echo >"/dev/tcp/${mqtt_host}/${mqtt_port}") >/dev/null 2>&1; then
      echo "[DROWSY_EDGE] MQTT ready ${mqtt_host}:${mqtt_port}"
      exit 0
    fi
    if [[ "$mqtt_deadline" -gt 0 ]] && [[ "$SECONDS" -ge "$mqtt_deadline" ]]; then
      echo "[DROWSY_EDGE] MQTT wait timeout ${mqtt_host}:${mqtt_port} (${mqtt_timeout}s) -> keep waiting (required)"
      mqtt_deadline=$((SECONDS + mqtt_timeout))
    fi
    sleep 1
  done
fi

if (echo >"/dev/tcp/${mqtt_host}/${mqtt_port}") >/dev/null 2>&1; then
  echo "[DROWSY_EDGE] MQTT ready ${mqtt_host}:${mqtt_port}"
else
  echo "[DROWSY_EDGE] MQTT not ready -> start in WAIT mode"
fi
exit 0
