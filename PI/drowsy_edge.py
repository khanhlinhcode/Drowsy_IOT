"""
Drowsiness Detection - Edge Optimized for Raspberry Pi 4 + ESP32 over MQTT.

Goals:
- Stable real-time demo on unstable 4G hotspot
- 224x168 low-latency pipeline
- Adaptive MediaPipe inference with dynamic throttling
- MQTT QoS1 + heartbeat + reconnect safety
- ESP32-compatible signal mapping
"""

import argparse
import json
import math
import os
import re
import select
import socket
import subprocess
import sys
import threading
import time
from collections import deque
from urllib import error as urllib_error
from urllib import request as urllib_request

os.environ["OMP_NUM_THREADS"] = "1"
os.environ.setdefault("QT_QPA_PLATFORM", "xcb")
os.environ.setdefault("QT_LOGGING_RULES", "qt.qpa.*=false")

import cv2
import mediapipe as mp
import numpy as np
import paho.mqtt.client as mqtt

# =========================================================
# Edge tuning
# =========================================================
cv2.setUseOptimized(True)
cv2.setNumThreads(1)
try:
    cv2.ocl.setUseOpenCL(False)
except Exception:
    pass

# =========================================================
# MediaPipe
# =========================================================
_mp_tasks = mp.tasks.vision
_options = _mp_tasks.FaceLandmarkerOptions(
    base_options=mp.tasks.BaseOptions(model_asset_path="face_landmarker.task"),
    running_mode=_mp_tasks.RunningMode.VIDEO,
    num_faces=1,
    min_face_detection_confidence=0.5,
    min_face_presence_confidence=0.5,
    min_tracking_confidence=0.6,
    output_face_blendshapes=False,
    output_facial_transformation_matrixes=False,
)
_landmarker = _mp_tasks.FaceLandmarker.create_from_options(_options)

# =========================================================
# MQTT (defaults overridden by CLI args in main())
# =========================================================
MQTT_BROKER = os.getenv("MQTT_BROKER", "127.0.0.1")

MQTT_PORT = int(os.getenv("MQTT_PORT", "1883"))
MQTT_TOPIC = "driver/status"
MQTT_META_TOPIC = "driver/status_meta"
MQTT_ALERT_TOPIC = "driver/alert_event"

MQTT_KEEPALIVE_S = 5
MQTT_STATUS_QOS = 1
#MQTT_META_QOS = 0
MQTT_META_QOS = 1
MQTT_HEARTBEAT_MS = 300       # keep stream fresh for ESP32 state sync
MQTT_DANGER_HEARTBEAT_MS = max(150, int(os.getenv("MQTT_DANGER_HEARTBEAT_MS", "220")))
MQTT_RETRY_MIN_S = 1
MQTT_RETRY_MAX_S = 8
MQTT_ERR_LOG_GAP_MS = 3000
MQTT_STATE_TTL_MS = 1400
MQTT_LOG_GAP_MS = 1500
MQTT_LOG_DANGER_GAP_MS = max(MQTT_LOG_GAP_MS, int(os.getenv("MQTT_LOG_DANGER_GAP_MS", "2200")))
MQTT_LOG_NO_FACE_GAP_MS = max(MQTT_LOG_GAP_MS, int(os.getenv("MQTT_LOG_NO_FACE_GAP_MS", "5000")))
MQTT_META_MIN_MS = 100
MQTT_META_DANGER_MIN_MS = max(MQTT_META_MIN_MS, int(os.getenv("MQTT_META_DANGER_MIN_MS", "220")))
MQTT_RETRY_BASE_MS = 500
MQTT_RETRY_MAX_MS = 8000

ESP32_WIFI_SERIAL_PORT = os.getenv("ESP32_WIFI_SERIAL_PORT", "/dev/ttyUSB0")
ESP32_WIFI_SERIAL_BAUD = int(os.getenv("ESP32_WIFI_SERIAL_BAUD", "115200"))
PI_WIFI_INTERFACE = os.getenv("PI_WIFI_INTERFACE", "wlan0")
DEFAULT_CMD_TIMEOUT_S = 25
WIFI_SYNC_DUP_WINDOW_MS = 15000
WIFI_SYNC_RETRY_DELAY_S = 2.0
WIFI_LOCK_TO_ESP32 = os.getenv("WIFI_LOCK_TO_ESP32", "1").strip().lower() in (
    "1",
    "true",
    "yes",
    "on",
)
WIFI_LOCK_CHECK_MS = int(os.getenv("WIFI_LOCK_CHECK_MS", "2500"))
INTERNAL_WIFI_SYNC_ENABLED = os.getenv("INTERNAL_WIFI_SYNC_ENABLED", "0").strip().lower() in (
    "1",
    "true",
    "yes",
    "on",
)
NETWORK_SEND_REQUIRE_WIFI = os.getenv("NETWORK_SEND_REQUIRE_WIFI", "1").strip().lower() in (
    "1",
    "true",
    "yes",
    "on",
)
NETWORK_CHECK_MS = max(200, int(os.getenv("NETWORK_CHECK_MS", "1000")))
NET_STATE_LOG_GAP_MS = max(5000, int(os.getenv("NET_STATE_LOG_GAP_MS", "30000")))
EDGE_DEVICE_ID = os.getenv("EDGE_DEVICE_ID", "rpi-drowsy-edge").strip() or "rpi-drowsy-edge"
CLOUD_API_BASE_URL = os.getenv("CLOUD_API_BASE_URL", "").strip().rstrip("/")
CLOUD_API_TOKEN = os.getenv("CLOUD_API_TOKEN", "").strip()
try:
    CLOUD_PUSH_TIMEOUT_S = max(0.3, float(os.getenv("CLOUD_PUSH_TIMEOUT_S", "1.5")))
except Exception:
    CLOUD_PUSH_TIMEOUT_S = 1.5
try:
    CLOUD_HEARTBEAT_MS = max(150, int(os.getenv("CLOUD_HEARTBEAT_MS", str(MQTT_HEARTBEAT_MS))))
except Exception:
    CLOUD_HEARTBEAT_MS = MQTT_HEARTBEAT_MS
try:
    CLOUD_STATUS_MIN_MS = max(120, int(os.getenv("CLOUD_STATUS_MIN_MS", "220")))
except Exception:
    CLOUD_STATUS_MIN_MS = 220
try:
    CLOUD_QUEUE_MAX = max(50, int(os.getenv("CLOUD_QUEUE_MAX", "400")))
except Exception:
    CLOUD_QUEUE_MAX = 400
CLOUD_PUSH_ENABLED = bool(CLOUD_API_BASE_URL)

mqtt_client = None
_mqtt_connected = False
_mqtt_force_sync = True
_mqtt_seq = 0
_last_mqtt_err_ms = 0
_last_mqtt_log_ms = 0
_last_mqtt_log_status = ""
_last_mqtt_meta_ms = 0
_last_mqtt_meta_status = ""
_mqtt_retry_ms = MQTT_RETRY_BASE_MS
_mqtt_next_retry_ms = 0

_mqtt_pub_lock = threading.Lock()
_wifi_sync_last_signature = ""
_wifi_sync_last_attempt_ms = 0
_esp32_serial_fd = -1
_esp32_serial_lock = threading.Lock()
_last_broker_hint = ""
_last_broker_hint_ms = 0
_wifi_target_lock = threading.Lock()
_esp32_target_ssid = ""
_esp32_target_password = ""
_last_wifi_lock_log_ms = 0
_net_state_lock = threading.Lock()
_last_net_check_ms = 0
_net_ready_for_send = not NETWORK_SEND_REQUIRE_WIFI
_net_ssid = ""
_net_ip = ""
_last_net_state_log_ms = 0

_cloud_queue_lock = threading.Lock()
_cloud_queue = deque(maxlen=CLOUD_QUEUE_MAX)
_cloud_queue_event = threading.Event()
_last_cloud_status_ms = 0
_last_cloud_status_key = ""
_last_cloud_err_ms = 0
_cloud_seq = 0


def _on_mqtt_connect(_client, _userdata, _flags, rc, *_args):
    global _mqtt_connected, _mqtt_force_sync
    global _mqtt_retry_ms, _mqtt_next_retry_ms
    if rc == 0:
        _mqtt_connected = True
        _mqtt_force_sync = True
        _mqtt_retry_ms = MQTT_RETRY_BASE_MS
        _mqtt_next_retry_ms = 0
        print(f"MQTT connected broker={MQTT_BROKER}:{MQTT_PORT}")
        _send_pi_broker_hint("mqtt_connected")
    else:
        _mqtt_connected = False
        print("MQTT connect failed rc=", rc)


def _on_mqtt_disconnect(_client, _userdata, rc, *_args):
    global _mqtt_connected, _mqtt_force_sync
    global _mqtt_retry_ms, _mqtt_next_retry_ms
    _mqtt_connected = False
    _mqtt_force_sync = True
    now_ms = int(time.monotonic() * 1000)
    _mqtt_next_retry_ms = now_ms + _mqtt_retry_ms
    _mqtt_retry_ms = min(_mqtt_retry_ms * 2, MQTT_RETRY_MAX_MS)
    if rc != 0:
        print("MQTT disconnected rc=", rc)


def _init_mqtt():
    global mqtt_client
    mqtt_client = mqtt.Client(client_id="rpi-drowsy-edge", protocol=mqtt.MQTTv311)
    mqtt_client.on_connect = _on_mqtt_connect
    mqtt_client.on_disconnect = _on_mqtt_disconnect
    mqtt_client.reconnect_delay_set(min_delay=MQTT_RETRY_MIN_S, max_delay=MQTT_RETRY_MAX_S)
    mqtt_client.max_inflight_messages_set(5)
    mqtt_client.max_queued_messages_set(20)
    mqtt_client.will_set(MQTT_TOPIC, payload="0", qos=MQTT_STATUS_QOS, retain=False)
    try:
        mqtt_client.connect_async(MQTT_BROKER, MQTT_PORT, MQTT_KEEPALIVE_S)
        mqtt_client.loop_start()  # non-blocking loop
        print(f"MQTT init broker={MQTT_BROKER}:{MQTT_PORT}")
    except Exception as exc:
        print("MQTT connection failed:", exc)


def _run_cmd(cmd, timeout=DEFAULT_CMD_TIMEOUT_S):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, check=False)


def _is_valid_iface_name(name):
    return bool(name) and re.fullmatch(r"[A-Za-z0-9._:-]{1,32}", name) is not None


def _sanitize_wifi_text(value, max_len):
    text = "" if value is None else str(value)
    text = text.replace("\x00", "").replace("\r", "").replace("\n", "").strip()
    return text[:max_len]


def _get_pi_ip(interface):
    try:
        res = _run_cmd(["ip", "-4", "-o", "addr", "show", "dev", interface], timeout=8)
        if res.returncode == 0:
            lines = (res.stdout or "").strip().splitlines()
            if lines:
                parts = lines[0].split()
                if len(parts) >= 4 and "/" in parts[3]:
                    return parts[3].split("/", 1)[0]
    except Exception:
        pass

    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            sock.connect(("8.8.8.8", 80))
            return sock.getsockname()[0]
    except Exception:
        return ""


def _resolve_esp32_broker_host():
    raw = str(MQTT_BROKER).strip()
    lower = raw.lower()
    if lower in ("127.0.0.1", "localhost", "0.0.0.0", "::1", ""):
        ip = _get_pi_ip(PI_WIFI_INTERFACE)
        return ip if ip else ""
    if lower.endswith(".local"):
        ip = _get_pi_ip(PI_WIFI_INTERFACE)
        return ip if ip else raw
    return raw


def _send_pi_broker_hint(reason):
    global _last_broker_hint, _last_broker_hint_ms
    now_ms = int(time.monotonic() * 1000)
    host = _resolve_esp32_broker_host()
    if not host:
        return

    payload = json.dumps(
        {
            "type": "broker",
            "host": host,
            "port": int(MQTT_PORT),
        },
        separators=(",", ":"),
    )
    signature = f"{host}:{int(MQTT_PORT)}"
    if signature == _last_broker_hint and (now_ms - _last_broker_hint_ms) < 2500:
        return

    with _esp32_serial_lock:
        if _esp32_serial_fd < 0:
            return
        try:
            os.write(_esp32_serial_fd, f"[PI_BROKER] {payload}\n".encode("utf-8"))
            _last_broker_hint = signature
            _last_broker_hint_ms = now_ms
            print(f"[WIFI_SYNC] sent broker to ESP32 ({reason}): {host}:{int(MQTT_PORT)}")
        except Exception as exc:
            print(f"[WIFI_SYNC] send broker failed: {exc}")


def _set_wifi_target_from_esp32(ssid, password):
    global _esp32_target_ssid, _esp32_target_password
    clean_ssid = _sanitize_wifi_text(ssid, 32)
    clean_pass = _sanitize_wifi_text(password, 64)
    if not clean_ssid:
        return
    with _wifi_target_lock:
        if _esp32_target_ssid == clean_ssid and (not clean_pass) and _esp32_target_password:
            clean_pass = _esp32_target_password
        _esp32_target_ssid = clean_ssid
        _esp32_target_password = clean_pass


def _get_wifi_target_from_esp32():
    with _wifi_target_lock:
        return _esp32_target_ssid, _esp32_target_password


def _get_current_wifi_ssid(interface):
    interface = _sanitize_wifi_text(interface, 32)
    if not _is_valid_iface_name(interface):
        return ""

    try:
        res = _run_cmd(["iwgetid", interface, "-r"], timeout=5)
        if res.returncode == 0:
            ssid = (res.stdout or "").strip()
            if ssid:
                return ssid
    except Exception:
        pass

    try:
        res = _run_cmd(["nmcli", "-t", "-f", "GENERAL.CONNECTION", "device", "show", interface], timeout=6)
        if res.returncode == 0:
            out = (res.stdout or "").strip()
            if out.startswith("GENERAL.CONNECTION:"):
                val = out.split(":", 1)[1].strip()
                if val and val != "--":
                    return val
    except Exception:
        pass
    return ""


def _get_iface_ipv4(interface):
    interface = _sanitize_wifi_text(interface, 32)
    if not _is_valid_iface_name(interface):
        return ""
    try:
        res = _run_cmd(["ip", "-4", "-o", "addr", "show", "dev", interface, "scope", "global"], timeout=5)
        if res.returncode != 0:
            return ""
        lines = (res.stdout or "").strip().splitlines()
        if not lines:
            return ""
        parts = lines[0].split()
        if len(parts) >= 4 and "/" in parts[3]:
            return parts[3].split("/", 1)[0]
    except Exception:
        pass
    return ""


def _can_send_network(now_ms):
    global _last_net_check_ms, _net_ready_for_send, _net_ssid, _net_ip, _last_net_state_log_ms
    if not NETWORK_SEND_REQUIRE_WIFI:
        return True

    with _net_state_lock:
        if (now_ms - _last_net_check_ms) >= NETWORK_CHECK_MS:
            _last_net_check_ms = now_ms
            ssid = _get_current_wifi_ssid(PI_WIFI_INTERFACE)
            ip = _get_iface_ipv4(PI_WIFI_INTERFACE)
            prev_ready = _net_ready_for_send
            _net_ssid = ssid
            _net_ip = ip
            _net_ready_for_send = bool(ssid and ip)

            if _net_ready_for_send != prev_ready or (now_ms - _last_net_state_log_ms) >= NET_STATE_LOG_GAP_MS:
                if _net_ready_for_send:
                    print(f"[NET] ready for publish ssid='{ssid}' ip={ip}")
                else:
                    print("[NET] offline publish hold (waiting WiFi)")
                _last_net_state_log_ms = now_ms

        return _net_ready_for_send


def _cloud_enqueue(path, payload):
    global _last_cloud_err_ms
    if not CLOUD_PUSH_ENABLED:
        return False
    item = {"path": path, "payload": payload, "retry": 0}
    dropped = False
    with _cloud_queue_lock:
        if len(_cloud_queue) >= CLOUD_QUEUE_MAX:
            dropped = True
        _cloud_queue.append(item)
    _cloud_queue_event.set()
    if dropped:
        now_ms = int(time.monotonic() * 1000)
        if (now_ms - _last_cloud_err_ms) >= 2500:
            print("[CLOUD] queue full, dropping oldest item")
            _last_cloud_err_ms = now_ms
    return True


def _cloud_next_item():
    with _cloud_queue_lock:
        if _cloud_queue:
            return _cloud_queue.popleft()
    return None


def _cloud_requeue_front(item):
    with _cloud_queue_lock:
        _cloud_queue.appendleft(item)
    _cloud_queue_event.set()


def _cloud_push_status(now_ms, status, esp_status, signal, fatigue, armed, status_changed, danger_now):
    global _last_cloud_status_ms, _last_cloud_status_key, _cloud_seq
    if not CLOUD_PUSH_ENABLED:
        return

    due = status_changed or ((now_ms - _last_cloud_status_ms) >= CLOUD_HEARTBEAT_MS)
    if not due:
        return

    status_key = f"{status}|{int(signal)}|{int(fatigue)}|{int(armed)}"
    if status_key == _last_cloud_status_key and (now_ms - _last_cloud_status_ms) < CLOUD_STATUS_MIN_MS:
        return

    epoch_ms = int(time.time() * 1000)
    _cloud_seq += 1
    face_lock = int(_last_out.get("face_lock", 0))
    face_in_frame = 0 if status in ("NO FACE", "NO_FACE") else 1
    payload = {
        "device_id": EDGE_DEVICE_ID,
        "event_id": f"status-{_alert_session_id}-{_cloud_seq:06d}",
        "timestamp_ms": epoch_ms,
        "epoch_ms": epoch_ms,
        "ts_ms": now_ms,
        "runtime_ms": now_ms,
        "status": esp_status,
        "status_raw": status,
        "signal": int(signal),
        "fatigue": int(fatigue),
        "armed": int(armed),
        "face_lock": int(face_lock),
        "face_in_frame": int(face_in_frame),
        "source": "drowsy_edge",
    }
    if _cloud_enqueue("/v1/ingest/status", payload):
        _last_cloud_status_ms = now_ms
        _last_cloud_status_key = status_key


def _cloud_push_alert(payload):
    if not CLOUD_PUSH_ENABLED:
        return
    data = dict(payload)
    if not data.get("device_id"):
        data["device_id"] = EDGE_DEVICE_ID
    _cloud_enqueue("/v1/ingest/alert", data)


def _connect_pi_wifi(ssid, password, interface, force=False):
    global _wifi_sync_last_signature, _wifi_sync_last_attempt_ms
    now_ms = int(time.monotonic() * 1000)
    signature = f"{ssid}\n{password}\n{interface}"
    if (not force) and signature == _wifi_sync_last_signature and (now_ms - _wifi_sync_last_attempt_ms) < WIFI_SYNC_DUP_WINDOW_MS:
        return

    _wifi_sync_last_signature = signature
    _wifi_sync_last_attempt_ms = now_ms
    interface = _sanitize_wifi_text(interface, 32)
    if not _is_valid_iface_name(interface):
        print(f"[WIFI_SYNC] invalid interface: '{interface}'")
        return

    ssid = _sanitize_wifi_text(ssid, 32)
    password = _sanitize_wifi_text(password, 64)
    if not ssid:
        return

    print(f"[WIFI_SYNC] request ssid='{ssid}' iface={interface}")
    cmd = ["nmcli", "--wait", "20", "dev", "wifi", "connect", ssid, "ifname", interface]
    if password:
        cmd.extend(["password", password])

    try:
        res = _run_cmd(cmd, timeout=35)
        if res.returncode != 0:
            stderr = (res.stderr or "").strip()
            stdout = (res.stdout or "").strip()
            detail = stderr if stderr else stdout
            if detail:
                print(f"[WIFI_SYNC] Pi WiFi connect failed: {detail}")
            else:
                print("[WIFI_SYNC] Pi WiFi connect failed")
            return

        pi_ip = _get_pi_ip(interface)
        if pi_ip:
            print(f"[WIFI_SYNC] Pi WiFi connected: ssid='{ssid}' ip={pi_ip}")
        else:
            print(f"[WIFI_SYNC] Pi WiFi connected: ssid='{ssid}' ip=unknown")
        _send_pi_broker_hint("pi_wifi_connected")
        return True
    except Exception as exc:
        print(f"[WIFI_SYNC] Pi WiFi connect error: {exc}")
    return False


def _enforce_wifi_lock():
    global _last_wifi_lock_log_ms
    if not WIFI_LOCK_TO_ESP32:
        return

    target_ssid, target_pass = _get_wifi_target_from_esp32()
    if not target_ssid:
        return

    now_ms = int(time.monotonic() * 1000)
    current_ssid = _get_current_wifi_ssid(PI_WIFI_INTERFACE)
    if current_ssid == target_ssid:
        return

    if (now_ms - _last_wifi_lock_log_ms) >= 3000:
        print(
            f"[WIFI_LOCK] ssid mismatch: current='{current_ssid or 'none'}' "
            f"target='{target_ssid}' -> reconnect"
        )
        _last_wifi_lock_log_ms = now_ms
    _connect_pi_wifi(target_ssid, target_pass, PI_WIFI_INTERFACE, force=True)


def _handle_esp32_wifi_sync_line(line):
    prefix = "[ESP32_WIFI] "
    if not line.startswith(prefix):
        return
    raw = line[len(prefix):].strip()
    if not raw:
        return
    try:
        data = json.loads(raw)
    except Exception:
        return

    msg_type = str(data.get("type", "")).strip().lower()
    if msg_type == "wifi_credentials":
        _set_wifi_target_from_esp32(
            str(data.get("ssid", "")).strip(),
            str(data.get("pass", "")).strip(),
        )
        connected = _connect_pi_wifi(
            str(data.get("ssid", "")).strip(),
            str(data.get("pass", "")).strip(),
            PI_WIFI_INTERFACE,
        )
        if connected:
            _send_pi_broker_hint("wifi_credentials")
    elif msg_type == "wifi_connected":
        esp_ip = str(data.get("esp_ip", "")).strip()
        ssid = str(data.get("ssid", "")).strip()
        if ssid:
            _set_wifi_target_from_esp32(ssid, "")
        if esp_ip:
            print(f"[WIFI_SYNC] ESP32 connected: ssid='{ssid}' esp_ip={esp_ip}")
        _send_pi_broker_hint("wifi_connected")


def _esp32_wifi_sync_worker():
    global _esp32_serial_fd
    serial_path = ESP32_WIFI_SERIAL_PORT
    if not serial_path:
        return

    while not _stop_event.is_set():
        fd = -1
        try:
            _run_cmd(
                [
                    "stty",
                    "-F",
                    serial_path,
                    str(ESP32_WIFI_SERIAL_BAUD),
                    "cs8",
                    "-cstopb",
                    "-parenb",
                    "-icanon",
                    "-echo",
                    "min",
                    "0",
                    "time",
                    "1",
                ],
                timeout=8,
            )
            fd = os.open(serial_path, os.O_RDWR | os.O_NONBLOCK)
            with _esp32_serial_lock:
                _esp32_serial_fd = fd
            print(f"[WIFI_SYNC] listening {serial_path}@{ESP32_WIFI_SERIAL_BAUD}")
            _send_pi_broker_hint("serial_open")
            buf = ""
            while not _stop_event.is_set():
                ready, _, _ = select.select([fd], [], [], 0.2)
                if not ready:
                    continue
                chunk = os.read(fd, 512)
                if not chunk:
                    continue
                buf += chunk.decode("utf-8", errors="ignore")
                while "\n" in buf:
                    line, buf = buf.split("\n", 1)
                    _handle_esp32_wifi_sync_line(line.strip())
        except Exception:
            _stop_event.wait(WIFI_SYNC_RETRY_DELAY_S)
        finally:
            with _esp32_serial_lock:
                if _esp32_serial_fd == fd:
                    _esp32_serial_fd = -1
            if fd >= 0:
                try:
                    os.close(fd)
                except Exception:
                    pass


# NOTE: _init_mqtt() is called from main() after CLI args are parsed.

# =========================================================
# Core constants
# =========================================================
FRAME_W = 224
FRAME_H = 168
X_SCALE_1000 = (FRAME_W * 1000) // FRAME_H


def _env_int(name, default):
    raw = os.getenv(name)
    if raw is None:
        return default
    try:
        return int(str(raw).strip())
    except Exception:
        return default


def _parse_camera_source(raw):
    src = "" if raw is None else str(raw).strip()
    if not src:
        return 0
    try:
        return int(src)
    except ValueError:
        return src


CAMERA_COLOR_ORDER = os.getenv("CAMERA_COLOR_ORDER", "bgr").strip().lower()
USB_CAMERA_SOURCE = os.getenv("USB_CAMERA_SOURCE", "0").strip()
USB_CAMERA_API = os.getenv("USB_CAMERA_API", "auto").strip().lower()
USB_CAMERA_WIDTH = _env_int("USB_CAMERA_WIDTH", FRAME_W)
USB_CAMERA_HEIGHT = _env_int("USB_CAMERA_HEIGHT", FRAME_H)
USB_CAMERA_FPS = _env_int("USB_CAMERA_FPS", 30)
USE_GRAYSCALE = False

# Adaptive inference timing (ms)
INFER_SAFE_MS = 95
INFER_RISK_MS = 60
INFER_NO_FACE_MS = 70

# EAR/MAR thresholds
EAR_CLOSE = 215
EAR_OPEN = 240
MAR_OPEN = 630
MAR_CLOSE = 550

# Time thresholds (ms)
BLINK_MIN = 80
BLINK_MAX = 450
EYE_WARN = 700
EYE_DROWSY = 1400
YAWN_MIN = 900
MICROSLEEP = 2000

# Windows (ms)
WIN_BLINK = 60000
WIN_YAWN = 60000
WIN_MICRO = 45000
WIN_PERCLOS = 30000

MICRO_FORCE = 4

# Head pose / attention (x1000)
YAW_THRESH = int(os.getenv("YAW_THRESH_X1000", "120"))
PITCH_THRESH = int(os.getenv("PITCH_THRESH_X1000", "560"))
ROLL_THRESH = int(os.getenv("ROLL_THRESH_X1000", "45"))
# Camera angle compensation: positive value makes "down" detection less sensitive.
PITCH_BIAS_X1000 = int(os.getenv("PITCH_BIAS_X1000", "0"))
POSE_HOLD = 220
ATTN_LAT = int(os.getenv("ATTN_LAT_X1000", "160"))
ATTN_DOWN = int(os.getenv("ATTN_DOWN_X1000", "500"))
ATTN_HOLD = 180
DISTRACT_HOLD = 1000

RELEASE_X10 = 18
MAX_HOLD = 4000

# State stability for demo-safe classification
DROWSY_HOLD_MS = 550
DANGER_HOLD_MS = 700
STATUS_MIN_SWITCH_MS = 140
DROWSY_ENTER = 80.0
DROWSY_EXIT = 62.0
VERY_TIRED_EXIT = 54.0
TIRED_EXIT = 34.0
FATIGUE_EMA_ALPHA_RISE = 0.18
FATIGUE_EMA_ALPHA_FALL = 0.34
STATUS_VOTE_WINDOW = 3
INFER_INTERVAL_MAX_MS = 160
FAST_RECOVERY_MS = 300
FAST_RECOVERY_FATIGUE = 60.0
ATTENTIVE_ARM_MS = 5000
# Keep only short tolerance for natural blinks; large grace causes early arm
# after repeated micro-breaks across multiple attempts.
ATTENTIVE_BREAK_GRACE_MS = int(os.getenv("ATTENTIVE_BREAK_GRACE_MS", "700"))
ARM_FACE_LOCK_MS = int(os.getenv("ARM_FACE_LOCK_MS", "1200"))
NO_FACE_REARM_MS = int(os.getenv("NO_FACE_REARM_MS", "60000"))
PI_ARM_GATE_ENABLED = os.getenv("PI_ARM_GATE_ENABLED", "1").strip().lower() in (
    "1",
    "true",
    "yes",
    "on",
)

# Fatigue rates (existing logic preserved)
RATE_BASE_REC = 80
RATE_OPEN_REC = 200
RATE_POST_DROWSY = 300
RATE_ALERT_REC = 140
RATE_IDLE_REC = 20
RATE_NO_FACE = 100

RATE_PERCLOS_HIGH = 180
RATE_PERCLOS_MED = 100
RATE_PERCLOS_LOW = 50
RATE_EYE_DROWSY = 180
RATE_EYE_WARN = 90
RATE_BLINK_HIGH = 30
RATE_BLINK_MED = 15
RATE_YAWN_HIGH = 70
RATE_YAWN_MED = 40
RATE_YAWN_LOW = 18
RATE_HEAD_DOWN = 80
RATE_HEAD_TILT = 20
RATE_HEAD_SIDE = 15
RATE_ATTN_AWAY = 15
RATE_DISTRACT = 90
RATE_MICROSLEEP = 120
MICRO_BOOST = 120

# Landmark indices
_L_EYE = (33, 160, 158, 133, 153, 144)
_R_EYE = (362, 385, 387, 263, 373, 380)
_L_IRIS = 468
_R_IRIS = 473

# UI + colors (Premium palette — BGR format)
COLOR_SAFE = (180, 230, 80)       # Soft lime-green
COLOR_WARN = (60, 200, 255)       # Warm amber
COLOR_DANG = (80, 60, 255)        # Coral-red
COLOR_TEXT = (240, 240, 240)       # Near-white
COLOR_TEXT_DIM = (160, 160, 170)   # Subtle gray for secondary info
COLOR_ACCENT = (255, 200, 60)     # Teal accent for badges
COLOR_PANEL_BG = (20, 20, 24)     # Dark panel background
COLOR_PANEL_BORDER = (60, 60, 68) # Panel border
COLOR_BAR_BG = (40, 40, 48)       # Fatigue bar background
PANEL_H = 110
PANEL_W = 132
CAM_LOG_GAP_MS = 2000
PERF_LOG_GAP_MS = _env_int("PERF_LOG_GAP_MS", 3000)


class RingBuf:
    __slots__ = ("_data", "_cap", "_idx", "_count", "_sum")

    def __init__(self, capacity):
        self._data = [0.0] * capacity
        self._cap = capacity
        self._idx = 0
        self._count = 0
        self._sum = 0.0

    def push(self, val):
        if self._count == self._cap:
            self._sum -= self._data[self._idx]
        else:
            self._count += 1
        self._data[self._idx] = val
        self._sum += val
        self._idx = (self._idx + 1) % self._cap

    def avg(self):
        return 0.0 if self._count == 0 else (self._sum / self._count)


class EventWindow:
    __slots__ = ("_ts", "_cap", "_head", "_tail", "_count", "_window_ms")

    def __init__(self, capacity, window_ms):
        self._ts = [0] * capacity
        self._cap = capacity
        self._head = 0
        self._tail = 0
        self._count = 0
        self._window_ms = window_ms

    def push(self, ts_ms):
        if self._count == self._cap:
            self._tail = (self._tail + 1) % self._cap
        else:
            self._count += 1
        self._ts[self._head] = ts_ms
        self._head = (self._head + 1) % self._cap

    def purge(self, now_ms):
        cutoff = now_ms - self._window_ms
        while self._count > 0 and self._ts[self._tail] < cutoff:
            self._tail = (self._tail + 1) % self._cap
            self._count -= 1

    def size(self):
        return self._count


class PerclosTracker:
    __slots__ = (
        "_ts",
        "_dt",
        "_closed",
        "_cap",
        "_head",
        "_tail",
        "_count",
        "_total",
        "_closed_total",
        "_window_ms",
    )

    def __init__(self, capacity, window_ms):
        self._ts = [0] * capacity
        self._dt = [0.0] * capacity
        self._closed = [0.0] * capacity
        self._cap = capacity
        self._head = 0
        self._tail = 0
        self._count = 0
        self._total = 0.0
        self._closed_total = 0.0
        self._window_ms = window_ms

    def push(self, ts_ms, dt_ms, is_closed):
        if dt_ms <= 0:
            return
        c = float(dt_ms) if is_closed else 0.0

        if self._count == self._cap:
            self._total -= self._dt[self._tail]
            self._closed_total -= self._closed[self._tail]
            self._tail = (self._tail + 1) % self._cap
        else:
            self._count += 1

        self._ts[self._head] = ts_ms
        self._dt[self._head] = float(dt_ms)
        self._closed[self._head] = c
        self._total += float(dt_ms)
        self._closed_total += c
        self._head = (self._head + 1) % self._cap

        cutoff = ts_ms - self._window_ms
        while self._count > 0 and self._ts[self._tail] < cutoff:
            self._total -= self._dt[self._tail]
            self._closed_total -= self._closed[self._tail]
            self._tail = (self._tail + 1) % self._cap
            self._count -= 1

        if self._total < 0.0:
            self._total = 0.0
        if self._closed_total < 0.0:
            self._closed_total = 0.0

    def value(self):
        return 0.0 if self._total < 1.0 else (self._closed_total / self._total)


# =========================================================
# Runtime state
# =========================================================
_ear_ma = RingBuf(6)
_mar_ma = RingBuf(6)
_yaw_ma = RingBuf(6)
_pitch_ma = RingBuf(6)
_roll_ma = RingBuf(6)
_lat_ma = RingBuf(6)

_blink_ev = EventWindow(64, WIN_BLINK)
_yawn_ev = EventWindow(16, WIN_YAWN)
_micro_ev = EventWindow(8, WIN_MICRO)
_perclos = PerclosTracker(1024, WIN_PERCLOS)

_last_infer_ms = 0
_last_call_ms = 0
_last_mp_ts = 0
_infer_adapt_ms = 0
_last_infer_time_ms = 0.0

_fatigue = 0.0
_blink_total = 0

_eye_closed = False
_eye_start = 0
_micro_active = False
_eyes_open_since = 0

_mouth_open = False
_mouth_start = 0
_yawn_latch = False

_side_h = 0.0
_down_h = 0.0
_tilt_h = 0.0
_left_h = 0.0
_right_h = 0.0
_adown_h = 0.0
_away_h = 0.0

_bbox_valid = False
_bbox_smooth = [0, 0, 0, 0]

# State machine variables are single-writer (processing thread only).
_fatigue_ema = 0.0
_drowsy_latched = False
_last_drowsy_ts = 0
_last_danger_ts = 0
_last_status_change_ms = 0
_recovery_start_ts = 0
_status_vote = deque(maxlen=STATUS_VOTE_WINDOW)

_last_sent = ""
_last_sent_signal = -1
_last_sent_ms = 0
_last_print_status = ""
_last_status_log_ms = 0

# Alert event tracking (for driver/alert_event publishing)
_alert_event_active = False
_alert_event_id = 0
_alert_event_start_ms = 0
_alert_event_trigger = ""
_alert_event_last_status = ""
_alert_session_id = f"sess-{int(time.time())}"

_last_out = {
    "status": "NO FACE",
    "fatigue": 0,
    "fatigue_eval": 0,
    "blink_total": 0,
    "ear": 0.0,
    "mar": 0.0,
    "perclos": 0.0,
    "signal": 0,
    "armed": 0,
    "face_lock": 0,
}

_drowsy_armed = not PI_ARM_GATE_ENABLED
_attentive_since_ms = 0
_attentive_break_since_ms = 0
_face_lock_since_ms = 0
_no_face_since_ms = 0

STATUS_SIGNAL = {
    "ATTENTIVE": 0,
    "AWAKE": 0,
    "TIRED": 1,
    "VERY TIRED": 2,
    "LOOKING LEFT": 1,
    "LOOKING RIGHT": 1,
    "LOOKING DOWN": 2,
    "LOOKING SIDE": 1,
    "HEAD TILT": 1,
    "DISTRACTED": 2,
    "HEAD DOWN": 2,
    "DROWSY": 3,
    "MICROSLEEP": 3,
    "NO FACE": 0,
}

# Map internal status to text that ESP32 mapStatusTextToAiState() understands.
STATUS_TO_ESP32_TEXT = {
    "ATTENTIVE": "ATTENTIVE",
    "AWAKE": "ATTENTIVE",
    "TIRED": "TIRED",
    "VERY TIRED": "SLEEPY",
    "DROWSY": "MICROSLEEP",
    "MICROSLEEP": "MICROSLEEP",
    "HEAD DOWN": "SLEEPY",
    "DISTRACTED": "SLEEPY",
    "LOOKING DOWN": "LOOKING DOWN",
    "LOOKING LEFT": "TIRED",
    "LOOKING RIGHT": "TIRED",
    "LOOKING SIDE": "TIRED",
    "HEAD TILT": "TIRED",
    "NO FACE": "NO_FACE",
}


def _esp_status_for(status):
    return STATUS_TO_ESP32_TEXT.get(status, "ATTENTIVE")


def _expected_buzzer_code(status, armed):
    if not armed:
        return "OFF"
    esp_status = _esp_status_for(status)
    if esp_status in ("MICROSLEEP", "SLEEP"):
        return "CONT"
    if esp_status == "SLEEPY":
        return "FAST"
    if esp_status == "TIRED":
        return "SLOW"
    return "OFF"

DANGER_STATES = {"DROWSY", "MICROSLEEP", "HEAD DOWN"}
WARN_STATES = {
    "TIRED",
    "VERY TIRED",
    "DISTRACTED",
    "LOOKING DOWN",
    "LOOKING LEFT",
    "LOOKING RIGHT",
    "LOOKING SIDE",
    "HEAD TILT",
}

STATUS_PRIORITY = {
    "MICROSLEEP": 100,
    "DROWSY": 90,
    "VERY TIRED": 80,
    "TIRED": 70,
    "HEAD DOWN": 60,
    "DISTRACTED": 58,
    "LOOKING DOWN": 56,
    "LOOKING LEFT": 54,
    "LOOKING RIGHT": 54,
    "LOOKING SIDE": 52,
    "HEAD TILT": 52,
    "ATTENTIVE": 20,
    "AWAKE": 15,
    "NO FACE": 0,
}

_hypot = math.hypot


def _clamp(v):
    if v < 0.0:
        return 0.0
    if v > 100.0:
        return 100.0
    return v


def _status_color(status):
    if status in DANGER_STATES:
        return COLOR_DANG
    if status in WARN_STATES:
        return COLOR_WARN
    return COLOR_SAFE


def _priority(status):
    return STATUS_PRIORITY.get(status, 0)


def _normalize_camera_frame(frame, stream_format):
    if not isinstance(frame, np.ndarray):
        return None

    fmt = str(stream_format).upper() if stream_format else ""

    # grayscale -> BGR
    if frame.ndim == 2:
        return cv2.cvtColor(frame, cv2.COLOR_GRAY2BGR)

    if frame.ndim != 3:
        return None

    ch = frame.shape[2]

    # RGBA/BGRA -> BGR
    if ch == 4:
        if "RGBA" in fmt and "BGRA" not in fmt:
            return cv2.cvtColor(frame, cv2.COLOR_RGBA2BGR)
        return cv2.cvtColor(frame, cv2.COLOR_BGRA2BGR)

    if ch != 3:
        return None

    # Force stable BGR for OpenCV display and downstream logic.
    # If camera stream is RGB888, convert once to BGR here.
    if "RGB" in fmt and "BGR" not in fmt:
        frame = frame[:, :, ::-1]
    elif CAMERA_COLOR_ORDER == "rgb" and "BGR" not in fmt:
        frame = frame[:, :, ::-1]
    return frame

def _is_valid_color_frame(frame):
    return (
        isinstance(frame, np.ndarray)
        and frame.ndim == 3
        and frame.shape[2] == 3
        and frame.size > 0
    )


def _is_expected_frame_size(frame):
    return frame.shape[0] == FRAME_H and frame.shape[1] == FRAME_W


def _ensure_frame_ownership(frame):
    if frame is None:
        return None
    if (not frame.flags["OWNDATA"]) or (not frame.flags["C_CONTIGUOUS"]):
        return frame.copy()
    return frame


def _next_ts(now_ms):
    global _last_mp_ts
    if now_ms <= _last_mp_ts:
        now_ms = _last_mp_ts + 1
    _last_mp_ts = now_ms
    return now_ms


def _decay(hold, dt):
    v = hold - (RELEASE_X10 * dt * 0.1)
    return 0.0 if v < 0.0 else v


def _accum(hold, dt):
    v = hold + dt
    return MAX_HOLD if v > MAX_HOLD else v


def _update_no_face_arm_reset(now_ms, face_present):
    global _no_face_since_ms
    global _drowsy_armed, _attentive_since_ms, _attentive_break_since_ms, _face_lock_since_ms
    global _drowsy_latched, _recovery_start_ts, _status_vote
    if face_present:
        _no_face_since_ms = 0
        return False

    if _no_face_since_ms == 0:
        _no_face_since_ms = now_ms

    if (not PI_ARM_GATE_ENABLED) or (not _drowsy_armed):
        return False
    if (now_ms - _no_face_since_ms) < NO_FACE_REARM_MS:
        return False

    _drowsy_armed = False
    _attentive_since_ms = 0
    _attentive_break_since_ms = 0
    _face_lock_since_ms = 0
    _drowsy_latched = False
    _recovery_start_ts = 0
    _status_vote.clear()
    print(
        f"[ARM] NO FACE {int(NO_FACE_REARM_MS / 1000)}s -> disarmed, "
        "require 5s face-forward again"
    )
    _no_face_since_ms = now_ms
    return True


def _arm_progress_fields(now_ms):
    if not PI_ARM_GATE_ENABLED:
        return 100, 0
    if _drowsy_armed:
        return 100, 0

    if _attentive_since_ms > 0:
        elapsed = max(0, now_ms - _attentive_since_ms)
        arm_ms = max(1, ATTENTIVE_ARM_MS)
        progress = int((elapsed * 100) / arm_ms)
        if progress > 99:
            progress = 99
        remaining = ATTENTIVE_ARM_MS - elapsed
        if remaining < 0:
            remaining = 0
        return progress, remaining

    return 0, ATTENTIVE_ARM_MS


def _publish_signal(status, signal, fatigue, now_ms):
    global _last_sent, _last_sent_signal, _last_sent_ms
    global _mqtt_seq, _mqtt_force_sync
    global _last_mqtt_meta_ms, _last_mqtt_meta_status
    global _last_mqtt_err_ms, _last_mqtt_log_ms, _last_mqtt_log_status

    if mqtt_client is None:
        return

    sig_from_status = STATUS_SIGNAL.get(status, signal)
    sig = int(sig_from_status)
    fat = int(fatigue)
    armed = int(_last_out.get("armed", 1))
    # Translate to text ESP32 understands
    esp_status = _esp_status_for(status)

    with _mqtt_pub_lock:
        status_changed = (status != _last_sent) or (sig != _last_sent_signal)
        danger_now = status in DANGER_STATES
        heartbeat_ms = MQTT_DANGER_HEARTBEAT_MS if danger_now else MQTT_HEARTBEAT_MS
        should_send = _mqtt_force_sync or status_changed or ((now_ms - _last_sent_ms) >= heartbeat_ms)
        if not should_send:
            return

        _cloud_push_status(
            now_ms=now_ms,
            status=status,
            esp_status=esp_status,
            signal=sig,
            fatigue=fat,
            armed=armed,
            status_changed=status_changed,
            danger_now=danger_now,
        )

        if not _can_send_network(now_ms):
            _mqtt_force_sync = True
            if (status_changed or danger_now) and (now_ms - _last_mqtt_err_ms) >= MQTT_ERR_LOG_GAP_MS:
                print("MQTT skip(no_wifi):", sig, "| STATUS:", status, "| FATIGUE:", fat)
                _last_mqtt_err_ms = now_ms
            return

        if not _mqtt_connected:
            if status_changed and (now_ms - _last_mqtt_err_ms) >= MQTT_ERR_LOG_GAP_MS:
                print("MQTT skip(disconnected):", sig, "| STATUS:", status, "| FATIGUE:", fat)
                _last_mqtt_err_ms = now_ms
            return

        _mqtt_seq += 1
        publish_ts_ms = int(time.monotonic() * 1000)
        meta_due = (
            status != _last_mqtt_meta_status
            or sig != _last_sent_signal
            or (now_ms - _last_mqtt_meta_ms) >= (MQTT_META_DANGER_MIN_MS if danger_now else MQTT_META_MIN_MS)
        )
        meta_payload = None
        if meta_due:
            epoch_ms = int(time.time() * 1000)
            face_lock = int(_last_out.get("face_lock", 0))
            arm_progress_pct, arm_remaining_ms = _arm_progress_fields(now_ms)
            with _net_state_lock:
                pi_ip = _net_ip or ""
            if not pi_ip:
                pi_ip = _get_iface_ipv4(PI_WIFI_INTERFACE)

            meta_obj = {
                "seq": _mqtt_seq,
                "ts_ms": now_ms,
                "epoch_ms": epoch_ms,
                "publish_ts_ms": publish_ts_ms,
                "status": esp_status,
                "status_raw": status,
                "signal": sig,
                "fatigue": fat,
                "armed": armed,
                "face_lock": face_lock,
                "arm_progress_pct": arm_progress_pct,
                "arm_remaining_ms": arm_remaining_ms,
                "ttl_ms": MQTT_STATE_TTL_MS,
            }
            if pi_ip:
                meta_obj["pi_ip"] = pi_ip
            meta_payload = json.dumps(meta_obj, separators=(",", ":"))

        try:
            info = mqtt_client.publish(
                MQTT_TOPIC,
                payload=str(sig),
                qos=MQTT_STATUS_QOS,
                retain=False,
            )
            if info.rc != mqtt.MQTT_ERR_SUCCESS:
                if (now_ms - _last_mqtt_err_ms) >= MQTT_ERR_LOG_GAP_MS:
                    print("MQTT status publish failed rc=", info.rc)
                    _last_mqtt_err_ms = now_ms
                return

            if meta_payload is not None:
                meta_info = mqtt_client.publish(
                    MQTT_META_TOPIC,
                    payload=meta_payload,
                    qos=MQTT_META_QOS,
                    retain=False,
                )
                if meta_info.rc != mqtt.MQTT_ERR_SUCCESS and (now_ms - _last_mqtt_err_ms) >= MQTT_ERR_LOG_GAP_MS:
                    print("MQTT meta publish failed rc=", meta_info.rc)
                    _last_mqtt_err_ms = now_ms
        except Exception as exc:
            if (now_ms - _last_mqtt_err_ms) >= MQTT_ERR_LOG_GAP_MS:
                print("MQTT publish error:", exc)
                _last_mqtt_err_ms = now_ms
            return

        _last_sent = status
        _last_sent_signal = sig
        _last_sent_ms = now_ms
        _mqtt_force_sync = False
        if meta_payload is not None:
            _last_mqtt_meta_ms = now_ms
            _last_mqtt_meta_status = status

    if status == "NO FACE":
        log_gap_ms = MQTT_LOG_NO_FACE_GAP_MS
    elif danger_now:
        log_gap_ms = MQTT_LOG_DANGER_GAP_MS
    else:
        log_gap_ms = MQTT_LOG_GAP_MS
    if status_changed or status != _last_mqtt_log_status or (now_ms - _last_mqtt_log_ms) >= log_gap_ms:
        print("MQTT PUB:", sig, "|", esp_status, "| FATIGUE:", fat)
        _last_mqtt_log_ms = now_ms
        _last_mqtt_log_status = status


def _log_status(status, fatigue, now_ms):
    global _last_print_status, _last_status_log_ms
    armed = int(_last_out.get("armed", 1)) == 1
    esp_status = _esp_status_for(status)
    signal = STATUS_SIGNAL.get(status, 0)
    buzz = _expected_buzzer_code(status, armed)
    if status != _last_print_status or (now_ms - _last_status_log_ms) >= 5000:
        print(
            f"STATUS: {status} | ESP:{esp_status} | SIG:{int(signal)} "
            f"| ARM:{1 if armed else 0} | BUZZ:{buzz} | FATIGUE:{int(fatigue)}"
        )
        _last_print_status = status
        _last_status_log_ms = now_ms


def _publish_alert_event(status, fatigue, now_ms):
    """Publish structured alert event to driver/alert_event when entering danger state."""
    global _alert_event_active, _alert_event_id
    global _alert_event_start_ms, _alert_event_trigger, _alert_event_last_status

    mqtt_ready = mqtt_client is not None and _mqtt_connected and _can_send_network(now_ms)

    is_danger = status in DANGER_STATES
    was_danger = _alert_event_last_status in DANGER_STATES
    signal_now = int(_last_out.get("signal", STATUS_SIGNAL.get(status, 0)))
    armed_now = int(_last_out.get("armed", 1))

    if is_danger and not was_danger:
        # Entering danger state — publish alert start event.
        _alert_event_active = True
        _alert_event_id += 1
        _alert_event_start_ms = now_ms
        _alert_event_trigger = status

        event_epoch_ms = int(time.time() * 1000)
        event = {
            "event_id": f"evt-{_alert_session_id}-{_alert_event_id:04d}",
            "device_id": EDGE_DEVICE_ID,
            "session_id": _alert_session_id,
            "event_type": "DROWSY_ALERT",
            "trigger_status": status,
            "status": status,
            "status_raw": status,
            "signal": signal_now,
            "armed": armed_now,
            "fatigue_score": int(fatigue),
            "perclos": round(_perclos.value(), 3),
            "eye_closed_ms": int(float(now_ms - _eye_start) if _eye_closed and _eye_start > 0 else 0),
            "head_pose": _last_out.get("head", "CENTER"),
            "timestamp_ms": now_ms,
            "epoch_ms": event_epoch_ms,
            "duration_ms": 0,
            "resolved": False,
        }
        _cloud_push_alert(event)
        if mqtt_ready:
            try:
                mqtt_client.publish(
                    MQTT_ALERT_TOPIC,
                    payload=json.dumps(event, separators=(",", ":")),
                    qos=1,
                    retain=False,
                )
                print(f"ALERT EVENT START: {event['event_id']} trigger={status} fatigue={int(fatigue)}")
            except Exception as exc:
                print("ALERT EVENT publish error:", exc)

    elif not is_danger and was_danger and _alert_event_active:
        # Exiting danger state — publish alert resolved event.
        _alert_event_active = False
        duration_ms = max(0, now_ms - _alert_event_start_ms)

        event_epoch_ms = int(time.time() * 1000)
        event = {
            "event_id": f"evt-{_alert_session_id}-{_alert_event_id:04d}",
            "device_id": EDGE_DEVICE_ID,
            "session_id": _alert_session_id,
            "event_type": "DROWSY_ALERT_RESOLVED",
            "trigger_status": _alert_event_trigger,
            "status": status,
            "status_raw": status,
            "resolved_status": status,
            "signal": signal_now,
            "armed": armed_now,
            "fatigue_score": int(fatigue),
            "perclos": round(_perclos.value(), 3),
            "eye_closed_ms": 0,
            "head_pose": _last_out.get("head", "CENTER"),
            "timestamp_ms": now_ms,
            "epoch_ms": event_epoch_ms,
            "duration_ms": duration_ms,
            "resolved": True,
        }
        _cloud_push_alert(event)
        if mqtt_ready:
            try:
                mqtt_client.publish(
                    MQTT_ALERT_TOPIC,
                    payload=json.dumps(event, separators=(",", ":")),
                    qos=1,
                    retain=False,
                )
                print(f"ALERT EVENT RESOLVED: {event['event_id']} duration={duration_ms}ms")
            except Exception as exc:
                print("ALERT EVENT publish error:", exc)

    _alert_event_last_status = status


def _ear_eye(lm, idx):
    s = X_SCALE_1000 * 0.001
    p0x = lm[idx[0]].x * s
    p0y = lm[idx[0]].y
    p1x = lm[idx[1]].x * s
    p1y = lm[idx[1]].y
    p2x = lm[idx[2]].x * s
    p2y = lm[idx[2]].y
    p3x = lm[idx[3]].x * s
    p3y = lm[idx[3]].y
    p4x = lm[idx[4]].x * s
    p4y = lm[idx[4]].y
    p5x = lm[idx[5]].x * s
    p5y = lm[idx[5]].y

    a = _hypot(p1x - p5x, p1y - p5y)
    b = _hypot(p2x - p4x, p2y - p4y)
    c = _hypot(p0x - p3x, p0y - p3y)
    if c < 1e-7:
        return 0.0
    return (a + b) / (c + c)


def _mar_calc(lm):
    s = X_SCALE_1000 * 0.001
    ux = lm[13].x * s
    uy = lm[13].y
    lx = lm[14].x * s
    ly = lm[14].y
    c1x = lm[78].x * s
    c1y = lm[78].y
    c2x = lm[308].x * s
    c2y = lm[308].y

    v = _hypot(ux - lx, uy - ly)
    h = _hypot(c1x - c2x, c1y - c2y)
    if h < 1e-7:
        return 0.0
    return v / h


def _head_pose(lm):
    s = X_SCALE_1000 * 0.001
    lx = lm[234].x * s
    rx = lm[454].x * s
    nx = lm[1].x * s
    ny = lm[1].y
    cy = lm[152].y
    lox = lm[33].x * s
    loy = lm[33].y
    rox = lm[263].x * s
    roy = lm[263].y

    fw = abs(rx - lx) + 1e-6
    emx = (lox + rox) * 0.5
    emy = (loy + roy) * 0.5
    etc = abs(cy - emy) + 1e-6
    return ((nx - emx) / fw, (ny - emy) / etc, (loy - roy) / fw)


def _gaze_lat(lm, yaw_fb):
    if len(lm) <= _R_IRIS:
        if yaw_fb < -1.0:
            return -1.0
        if yaw_fb > 1.0:
            return 1.0
        return yaw_fb

    s = X_SCALE_1000 * 0.001
    li = lm[_L_IRIS].x * s
    ri = lm[_R_IRIS].x * s
    l0 = lm[33].x * s
    l1 = lm[133].x * s
    r0 = lm[362].x * s
    r1 = lm[263].x * s

    if l0 > l1:
        l0, l1 = l1, l0
    if r0 > r1:
        r0, r1 = r1, r0

    lr = (li - l0) / (l1 - l0 + 1e-6)
    rr = (ri - r0) / (r1 - r0 + 1e-6)
    g = lr + rr - 1.0
    if g < -1.0:
        return -1.0
    if g > 1.0:
        return 1.0
    return g


def _compute_bbox(lm, width, height):
    global _bbox_valid, _bbox_smooth

    min_x = 1.0
    min_y = 1.0
    max_x = 0.0
    max_y = 0.0
    for p in lm:
        x = p.x
        y = p.y
        if x < min_x:
            min_x = x
        if y < min_y:
            min_y = y
        if x > max_x:
            max_x = x
        if y > max_y:
            max_y = y

    x1 = int(min_x * width)
    y1 = int(min_y * height)
    x2 = int(max_x * width)
    y2 = int(max_y * height)

    bw = x2 - x1
    bh = y2 - y1
    if bw <= 2 or bh <= 2:
        return None

    # Keep box visibly larger for demo readability.
    pad_x = max(6, int(bw * 0.30))
    pad_y = max(7, int(bh * 0.35))
    x1 -= pad_x
    y1 -= pad_y
    x2 += pad_x
    y2 += pad_y

    if x1 < 0:
        x1 = 0
    if y1 < 0:
        y1 = 0
    if x2 > (width - 1):
        x2 = width - 1
    if y2 > (height - 1):
        y2 = height - 1

    if _bbox_valid:
        bx1, by1, bx2, by2 = _bbox_smooth
        prev_cx = (bx1 + bx2) * 0.5
        prev_cy = (by1 + by2) * 0.5
        cur_cx = (x1 + x2) * 0.5
        cur_cy = (y1 + y2) * 0.5
        jump_x = abs(cur_cx - prev_cx)
        jump_y = abs(cur_cy - prev_cy)
        if jump_x > (width * 0.24) or jump_y > (height * 0.24):
            _bbox_smooth[0] = x1
            _bbox_smooth[1] = y1
            _bbox_smooth[2] = x2
            _bbox_smooth[3] = y2
            return (x1, y1, x2, y2)

        alpha = 0.58
        x1 = int(alpha * bx1 + (1.0 - alpha) * x1)
        y1 = int(alpha * by1 + (1.0 - alpha) * y1)
        x2 = int(alpha * bx2 + (1.0 - alpha) * x2)
        y2 = int(alpha * by2 + (1.0 - alpha) * y2)
    else:
        _bbox_valid = True

    _bbox_smooth[0] = x1
    _bbox_smooth[1] = y1
    _bbox_smooth[2] = x2
    _bbox_smooth[3] = y2
    return (x1, y1, x2, y2)


def process_frame(frame):
    global _last_call_ms, _last_infer_ms
    global _fatigue, _blink_total
    global _eye_closed, _eye_start, _micro_active, _eyes_open_since
    global _mouth_open, _mouth_start, _yawn_latch
    global _side_h, _down_h, _tilt_h
    global _left_h, _right_h, _adown_h, _away_h
    global _last_out, _bbox_valid, _infer_adapt_ms, _last_infer_time_ms
    global _fatigue_ema, _drowsy_latched
    global _last_drowsy_ts, _last_danger_ts, _last_status_change_ms
    global _recovery_start_ts, _status_vote
    global _drowsy_armed, _attentive_since_ms, _attentive_break_since_ms, _face_lock_since_ms

    now = int(time.monotonic() * 1000)

    if frame is None or frame.size == 0:
        force_rearm = _update_no_face_arm_reset(now, face_present=False)
        _fatigue = _clamp(_fatigue - 1.0)
        _bbox_valid = False
        _drowsy_latched = False
        _recovery_start_ts = 0
        _attentive_since_ms = 0
        _attentive_break_since_ms = 0
        _face_lock_since_ms = 0
        _status_vote.clear()

        # 🔥 GIỮ trạng thái nguy hiểm
        if (not force_rearm) and _last_out.get("status") in ["DROWSY", "MICROSLEEP"]:
            _publish_signal(_last_out["status"], _last_out["signal"], _fatigue, now)
            return dict(_last_out), frame

        if _last_out.get("status") != "NO FACE":
            _last_status_change_ms = now

        _last_out["status"] = "NO FACE"
        _last_out["fatigue"] = int(_fatigue)
        _last_out["fatigue_eval"] = int(_fatigue_ema)
        _last_out["blink_total"] = _blink_total
        _last_out["signal"] = 0
        _last_out["armed"] = 1 if _drowsy_armed else 0
        _last_out["face_lock"] = 0

        _publish_signal("NO FACE", 0, _fatigue, now)
        return dict(_last_out), frame

    h, w = frame.shape[:2]
    if w != FRAME_W or h != FRAME_H:
        frame = cv2.resize(frame, (FRAME_W, FRAME_H), interpolation=cv2.INTER_AREA)
        h, w = FRAME_H, FRAME_W

    st = _last_out.get("status", "NO FACE")
    risk = (
        _fatigue >= 40.0
        or _eye_closed
        or _mouth_open
        or _down_h >= POSE_HOLD
        or st in ("TIRED", "VERY TIRED", "DROWSY", "MICROSLEEP", "HEAD DOWN", "DISTRACTED")
    )

    if st == "NO FACE":
        interval = INFER_NO_FACE_MS + _infer_adapt_ms
    elif risk:
        interval = INFER_RISK_MS + (_infer_adapt_ms // 2)
    else:
        interval = INFER_SAFE_MS + _infer_adapt_ms
    if interval > INFER_INTERVAL_MAX_MS:
        interval = INFER_INTERVAL_MAX_MS

    # Frame skipping: keep UI and MQTT heartbeat but skip heavy inference.
    if _last_infer_ms > 0 and (now - _last_infer_ms) < interval:
        if _last_call_ms > 0 and st in ("ATTENTIVE", "AWAKE") and _fatigue > 0.0:
            _fatigue = _clamp(_fatigue - RATE_IDLE_REC * 0.1 * (now - _last_call_ms) * 0.001)
            _last_out["fatigue"] = int(_fatigue)
            _last_out["fatigue_eval"] = int(_fatigue_ema if _fatigue_ema > 0.0 else _fatigue)
        _last_call_ms = now
        _publish_signal(st, _last_out.get("signal", 0), _fatigue, now)
        return dict(_last_out), frame

    dt = 33 if _last_infer_ms == 0 else (now - _last_infer_ms)
    if dt < 15:
        dt = 15
    elif dt > 180:
        dt = 180
    dt_s = dt * 0.001

    _last_infer_ms = now
    _last_call_ms = now

    ts = _next_ts(now)

    try:
        # MediaPipe expects RGB input; camera/display pipeline stays BGR.
        rgb = frame[:, :, ::-1]
        if not rgb.flags["C_CONTIGUOUS"]:
            rgb = np.ascontiguousarray(rgb)
        img = mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb)
        infer_start = time.monotonic()
        res = _landmarker.detect_for_video(img, ts)
        infer_ms = (time.monotonic() - infer_start) * 1000.0
        _last_infer_time_ms = infer_ms
        if infer_ms > 100.0:
            _infer_adapt_ms += 15
            if _infer_adapt_ms > 70:
                _infer_adapt_ms = 70
        elif infer_ms > 80.0:
            _infer_adapt_ms += 6
            if _infer_adapt_ms > 70:
                _infer_adapt_ms = 70
        elif infer_ms > 60.0:
            _infer_adapt_ms += 3
            if _infer_adapt_ms > 70:
                _infer_adapt_ms = 70
        elif infer_ms < 40.0:
            _infer_adapt_ms -= 3
            if _infer_adapt_ms < 0:
                _infer_adapt_ms = 0
    except Exception:
        force_rearm = _update_no_face_arm_reset(now, face_present=False)
        _fatigue = _clamp(_fatigue - RATE_NO_FACE * 0.1 * dt_s)
        _bbox_valid = False
        _drowsy_latched = False
        _recovery_start_ts = 0
        _attentive_since_ms = 0
        _attentive_break_since_ms = 0
        _face_lock_since_ms = 0
        _status_vote.clear()
        if _last_out.get("status") != "NO FACE":
            _last_status_change_ms = now
        _last_out["status"] = "NO FACE"
        _last_out["fatigue"] = int(_fatigue)
        _last_out["fatigue_eval"] = int(_fatigue_ema)
        _last_out["blink_total"] = _blink_total
        _last_out["signal"] = 0
        _last_out["armed"] = 1 if _drowsy_armed else 0
        _last_out["face_lock"] = 0
        if force_rearm:
            _last_out["status"] = "NO FACE"
        _publish_signal("NO FACE", 0, _fatigue, now)
        return dict(_last_out), frame

    _blink_ev.purge(ts)
    _yawn_ev.purge(ts)
    _micro_ev.purge(ts)

    if not res.face_landmarks:
        force_rearm = _update_no_face_arm_reset(now, face_present=False)
        _eye_closed = False
        _eye_start = 0
        _micro_active = False
        _eyes_open_since = 0
        _mouth_open = False
        _mouth_start = 0
        _yawn_latch = False
        _bbox_valid = False
        _drowsy_latched = False
        _recovery_start_ts = 0
        _attentive_since_ms = 0
        _attentive_break_since_ms = 0
        _face_lock_since_ms = 0
        _status_vote.clear()

        _side_h = _decay(_side_h, dt)
        _down_h = _decay(_down_h, dt)
        _tilt_h = _decay(_tilt_h, dt)
        _left_h = _decay(_left_h, dt)
        _right_h = _decay(_right_h, dt)
        _adown_h = _decay(_adown_h, dt)
        _away_h = _decay(_away_h, dt)

        _perclos.push(ts, dt, False)
        _fatigue = _clamp(_fatigue - RATE_NO_FACE * 0.1 * dt_s)

      # 🔥 GIỮ trạng thái nguy hiểm nếu vừa xảy ra
        if (not force_rearm) and _last_out.get("status") in ["DROWSY", "MICROSLEEP"]:
            _publish_signal(_last_out["status"], _last_out["signal"], _fatigue, now)
            return dict(_last_out), frame

        if _last_out.get("status") != "NO FACE":
            _last_status_change_ms = now

        _last_out["status"] = "NO FACE"
        _last_out["fatigue"] = int(_fatigue)
        _last_out["fatigue_eval"] = int(_fatigue_ema)
        _last_out["blink_total"] = _blink_total
        _last_out["signal"] = 0
        _last_out["armed"] = 1 if _drowsy_armed else 0
        _last_out["face_lock"] = 0

        _publish_signal("NO FACE", 0, _fatigue, now)
        return dict(_last_out), frame
    lm = res.face_landmarks[0]
    _update_no_face_arm_reset(now, face_present=True)
    bbox = _compute_bbox(lm, w, h)

    ear_raw = (_ear_eye(lm, _L_EYE) + _ear_eye(lm, _R_EYE)) * 0.5
    mar_raw = _mar_calc(lm)
    yaw_raw, pitch_raw, roll_raw = _head_pose(lm)
    gaze_raw = _gaze_lat(lm, yaw_raw)
    lat_raw = 0.65 * yaw_raw + 0.35 * gaze_raw

    _ear_ma.push(ear_raw)
    ear = _ear_ma.avg()
    _mar_ma.push(mar_raw)
    mar = _mar_ma.avg()
    _yaw_ma.push(yaw_raw)
    yaw = _yaw_ma.avg()
    _pitch_ma.push(pitch_raw)
    pitch = _pitch_ma.avg()
    _roll_ma.push(roll_raw)
    roll = _roll_ma.avg()
    _lat_ma.push(lat_raw)
    lateral = _lat_ma.avg()
    pitch_1000 = int(pitch * 1000) - PITCH_BIAS_X1000

    micro_event = False
    closed_ms = 0.0
    ear_1000 = int(ear * 1000)

    if _eye_closed:
        closed_ms = float(ts - _eye_start)
        if ear_1000 >= EAR_OPEN:
            if BLINK_MIN <= closed_ms <= BLINK_MAX:
                _blink_total += 1
                _blink_ev.push(ts)
            _eye_closed = False
            _eye_start = 0
            _micro_active = False
            closed_ms = 0.0
            _eyes_open_since = ts
        elif closed_ms >= MICROSLEEP and not _micro_active:
            _micro_active = True
            _micro_ev.push(ts)
            _fatigue = _clamp(_fatigue + MICRO_BOOST * 0.1)
            micro_event = True
    else:
        if ear_1000 <= EAR_CLOSE:
            _eye_closed = True
            _eye_start = ts
            _micro_active = False
            _eyes_open_since = 0
        elif _eyes_open_since == 0:
            _eyes_open_since = ts

    if _eye_closed:
        closed_ms = float(ts - _eye_start)
    microsleep_now = closed_ms >= MICROSLEEP

    eyes_open_ms = 0.0
    if (not _eye_closed) and _eyes_open_since > 0:
        eyes_open_ms = float(ts - _eyes_open_since)

    mar_1000 = int(mar * 1000)
    if _mouth_open:
        mouth_ms = float(ts - _mouth_start)
        if mar_1000 <= MAR_CLOSE:
            _mouth_open = False
            _mouth_start = 0
            _yawn_latch = False
        elif (not _yawn_latch) and mouth_ms >= YAWN_MIN:
            _yawn_ev.push(ts)
            _yawn_latch = True
    elif mar_1000 >= MAR_OPEN:
        _mouth_open = True
        _mouth_start = ts
        _yawn_latch = False

    _perclos.push(ts, dt, _eye_closed)
    pc = _perclos.value()

    _blink_ev.purge(ts)
    _yawn_ev.purge(ts)
    _micro_ev.purge(ts)
    blink_rpm = _blink_ev.size() * (60000.0 / WIN_BLINK)
    yawn_rpm = _yawn_ev.size() * (60000.0 / WIN_YAWN)
    micro_cnt = _micro_ev.size()

    abs_yaw = abs(yaw)
    abs_roll = abs(roll)

    _side_h = _accum(_side_h, dt) if (abs_yaw * 1000 > YAW_THRESH) else _decay(_side_h, dt)
    _down_h = _accum(_down_h, dt) if (pitch_1000 > PITCH_THRESH) else _decay(_down_h, dt)
    _tilt_h = _accum(_tilt_h, dt) if (abs_roll * 1000 > ROLL_THRESH) else _decay(_tilt_h, dt)

    if _down_h >= POSE_HOLD:
        head = "HEAD DOWN"
    elif _side_h >= POSE_HOLD:
        head = "LOOKING SIDE"
    elif _tilt_h >= POSE_HOLD:
        head = "HEAD TILT"
    else:
        head = "CENTER"

    lat_1000 = int(lateral * 1000)
    _left_h = _accum(_left_h, dt) if (lat_1000 <= -ATTN_LAT) else _decay(_left_h, dt)
    _right_h = _accum(_right_h, dt) if (lat_1000 >= ATTN_LAT) else _decay(_right_h, dt)
    _adown_h = _accum(_adown_h, dt) if (pitch_1000 >= ATTN_DOWN) else _decay(_adown_h, dt)

    if _adown_h >= ATTN_HOLD:
        attn = "LOOKING DOWN"
    elif _left_h >= ATTN_HOLD:
        attn = "LOOKING LEFT"
    elif _right_h >= ATTN_HOLD:
        attn = "LOOKING RIGHT"
    else:
        attn = "ATTENTIVE"

    if attn != "ATTENTIVE":
        _away_h = _accum(_away_h, dt)
    else:
        _away_h = _decay(_away_h, dt)
    distracted = _away_h >= DISTRACT_HOLD

    delta = -RATE_BASE_REC
    pc_1000 = int(pc * 1000)
    if pc_1000 >= 450:
        delta += RATE_PERCLOS_HIGH
    elif pc_1000 >= 350:
        delta += RATE_PERCLOS_MED
    elif pc_1000 >= 250:
        delta += RATE_PERCLOS_LOW

    if _eye_closed:
        if closed_ms >= EYE_DROWSY:
            delta += RATE_EYE_DROWSY
        elif closed_ms >= EYE_WARN:
            delta += RATE_EYE_WARN

    if blink_rpm >= 30.0:
        delta += RATE_BLINK_HIGH
    elif blink_rpm >= 22.0:
        delta += RATE_BLINK_MED

    if yawn_rpm >= 3.0:
        delta += RATE_YAWN_HIGH
    elif yawn_rpm >= 2.0:
        delta += RATE_YAWN_MED
    elif yawn_rpm >= 1.0:
        delta += RATE_YAWN_LOW

    if head == "HEAD DOWN":
        delta += RATE_HEAD_DOWN
    elif head == "HEAD TILT":
        delta += RATE_HEAD_TILT
    elif head == "LOOKING SIDE":
        delta += RATE_HEAD_SIDE

    if attn in ("LOOKING LEFT", "LOOKING RIGHT", "LOOKING DOWN"):
        delta += RATE_ATTN_AWAY
    if distracted:
        delta += RATE_DISTRACT
    if microsleep_now:
        delta += RATE_MICROSLEEP

    eyes_fwd = (not _eye_closed) and (attn == "ATTENTIVE") and (head == "CENTER")
    if eyes_fwd:
        if _fatigue >= 70.0:
            delta -= RATE_POST_DROWSY
        elif _fatigue >= 40.0:
            delta -= RATE_OPEN_REC
        elif _fatigue > 0.0:
            delta -= 100

    if eyes_open_ms >= 2000.0 and _fatigue > 20.0:
        bonus = eyes_open_ms * 0.001
        if bonus > 5.0:
            bonus = 5.0
        delta -= int(bonus * 30)

    if (
        (not _eye_closed)
        and (not _mouth_open)
        and (attn == "ATTENTIVE")
        and (head == "CENTER")
        and (pc_1000 < 250)
        and (blink_rpm < 28.0)
    ):
        delta -= RATE_ALERT_REC

    actual_delta = delta * 0.1 * dt_s
    if micro_event:
        actual_delta += 2.0
    _fatigue = _clamp(_fatigue + actual_delta)

    # Smooth fatigue for state decisions (keep raw _fatigue for telemetry).
    if _fatigue_ema <= 0.0:
        _fatigue_ema = _fatigue
    else:
        if _fatigue <= _fatigue_ema:
            ema_alpha = FATIGUE_EMA_ALPHA_FALL
        else:
            ema_alpha = FATIGUE_EMA_ALPHA_RISE
        _fatigue_ema = ((1.0 - ema_alpha) * _fatigue_ema) + (ema_alpha * _fatigue)
    fatigue_eval = _fatigue_ema

    prev_status = _last_out.get("status", "NO FACE")
    forced = micro_cnt >= MICRO_FORCE

    # Fatigue state with hysteresis (enter/exit thresholds differ).
    if microsleep_now:
        fatigue_state = "MICROSLEEP"
        _drowsy_latched = True
    else:
        enter_drowsy = (
            (forced and fatigue_eval >= 68.0)
            or (fatigue_eval >= DROWSY_ENTER)
            or (fatigue_eval >= 78.0 and pc_1000 >= 380)
        )
        keep_drowsy = (
            _drowsy_latched
            and (fatigue_eval >= DROWSY_EXIT or pc_1000 >= 320 or _eye_closed)
        )
        if enter_drowsy or keep_drowsy:
            fatigue_state = "DROWSY"
            _drowsy_latched = True
        else:
            _drowsy_latched = False
            if fatigue_eval >= 62.0 or (pc_1000 >= 350 and fatigue_eval >= 45.0):
                fatigue_state = "VERY TIRED"
            elif prev_status == "VERY TIRED" and fatigue_eval >= VERY_TIRED_EXIT:
                fatigue_state = "VERY TIRED"
            elif fatigue_eval >= 42.0 or (pc_1000 >= 250 and fatigue_eval >= 25.0):
                fatigue_state = "TIRED"
            elif prev_status == "TIRED" and fatigue_eval >= TIRED_EXIT:
                fatigue_state = "TIRED"
            elif fatigue_eval <= 18.0 and attn == "ATTENTIVE" and pc_1000 < 150:
                fatigue_state = "ATTENTIVE"
            else:
                fatigue_state = "AWAKE"

    # Head/attention branch (lower priority than fatigue tiers).
    if head == "HEAD DOWN":
        posture_state = "HEAD DOWN"
    elif distracted:
        posture_state = "DISTRACTED"
    elif attn == "LOOKING DOWN":
        posture_state = "LOOKING DOWN"
    elif attn == "LOOKING LEFT":
        posture_state = "LOOKING LEFT"
    elif attn == "LOOKING RIGHT":
        posture_state = "LOOKING RIGHT"
    elif head == "LOOKING SIDE":
        posture_state = "LOOKING SIDE"
    elif head == "HEAD TILT":
        posture_state = "HEAD TILT"
    else:
        posture_state = "ATTENTIVE"

    recovered_now = (
        (not _eye_closed)
        and (not _mouth_open)
        and (head == "CENTER")
        and (attn == "ATTENTIVE")
        and (pc_1000 < 220)
    )
    if recovered_now:
        if _recovery_start_ts == 0:
            _recovery_start_ts = ts
    else:
        _recovery_start_ts = 0
    fast_recovered = (
        _recovery_start_ts > 0
        and (ts - _recovery_start_ts) >= FAST_RECOVERY_MS
        and fatigue_eval <= FAST_RECOVERY_FATIGUE
    )

    # Strict priority:
    # MICROSLEEP > DROWSY > VERY TIRED > TIRED > HEAD/ATTN > AWAKE.
    status_candidate = fatigue_state

    if fatigue_state not in ("MICROSLEEP", "DROWSY"):
        if _priority(posture_state) > _priority(status_candidate):
            status_candidate = posture_state
    # Hold danger states to prevent unsafe->safe flicker.
    if status_candidate in ("MICROSLEEP", "DROWSY"):
        _last_drowsy_ts = ts
        _last_danger_ts = ts
    elif status_candidate in DANGER_STATES:
        _last_danger_ts = ts

    if (
        prev_status in ("MICROSLEEP", "DROWSY")
        and (ts - _last_drowsy_ts) < DROWSY_HOLD_MS
        and (not fast_recovered)
    ):
        if _priority(status_candidate) < _priority(prev_status):
            status_candidate = prev_status

    if (
        prev_status in DANGER_STATES
        and (ts - _last_danger_ts) < DANGER_HOLD_MS
        and (not fast_recovered)
    ):
        if _priority(status_candidate) < _priority(prev_status):
            status_candidate = prev_status

    # Fast recovery path: if the driver is clearly alert again, clear danger latches early.
    if fast_recovered and status_candidate in DANGER_STATES:
        _drowsy_latched = False
        _status_vote.clear()
        if fatigue_eval <= 20.0:
            status_candidate = "ATTENTIVE"
        else:
            status_candidate = "AWAKE"

    # Optional rolling vote for non-danger states only.
    if fast_recovered and status_candidate in ("ATTENTIVE", "AWAKE"):
        _status_vote.clear()
    elif status_candidate in DANGER_STATES:
        _status_vote.clear()
        _status_vote.append(status_candidate)
    else:
        _status_vote.append(status_candidate)
        if len(_status_vote) >= 3:
            vote_counts = {}
            for s in _status_vote:
                vote_counts[s] = vote_counts.get(s, 0) + 1
            voted = max(vote_counts.items(), key=lambda kv: (kv[1], _priority(kv[0])))[0]
            if _priority(voted) >= _priority(status_candidate):
                status_candidate = voted

    # Do not emit low-value status flips too frequently.
    if status_candidate != prev_status and (ts - _last_status_change_ms) < STATUS_MIN_SWITCH_MS:
        if _priority(status_candidate) <= _priority(prev_status):
            status_candidate = prev_status

    if status_candidate != prev_status:
        _last_status_change_ms = ts

    # Keep forward_face for status/telemetry meaning.
    forward_face = (
        (not _eye_closed)
        and (not distracted)
        and (head in ("CENTER", "LOOKING SIDE"))
        and (attn in ("ATTENTIVE", "LOOKING LEFT", "LOOKING RIGHT"))
    )
    # Arm gate start condition (demo UX):
    # only require "face present + eyes open" so startup lock is faster and
    # robust even when camera is mounted lower (which may bias pitch/attn).
    arm_face_ready = (not _eye_closed)
    if PI_ARM_GATE_ENABLED and (not _drowsy_armed):
        if arm_face_ready:
            _attentive_break_since_ms = 0
            if _face_lock_since_ms == 0:
                _face_lock_since_ms = ts
            if (ts - _face_lock_since_ms) >= ARM_FACE_LOCK_MS:
                if _attentive_since_ms == 0:
                    _attentive_since_ms = ts
                    print("[ARM] face lock -> start 5s countdown")
                elif (ts - _attentive_since_ms) >= ATTENTIVE_ARM_MS:
                    _drowsy_armed = True
                    print("[ARM] face present 5s -> drowsy detection enabled")
        else:
            _face_lock_since_ms = 0
            if _attentive_since_ms != 0:
                if _attentive_break_since_ms == 0:
                    _attentive_break_since_ms = ts
                elif (ts - _attentive_break_since_ms) >= ATTENTIVE_BREAK_GRACE_MS:
                    _attentive_since_ms = 0
                    _attentive_break_since_ms = 0

        if not _drowsy_armed:
            status_candidate = "ATTENTIVE"
            _drowsy_latched = False
            _status_vote.clear()

    face_lock_now = 1 if (
        arm_face_ready
        and (
            _drowsy_armed
            or (
                _face_lock_since_ms > 0
                and (ts - _face_lock_since_ms) >= ARM_FACE_LOCK_MS
            )
        )
    ) else 0

    status = status_candidate

    signal = STATUS_SIGNAL.get(status, 0)

    _last_out["status"] = status
    _last_out["fatigue"] = int(_fatigue)
    _last_out["fatigue_eval"] = int(fatigue_eval)
    _last_out["blink_total"] = _blink_total
    _last_out["ear"] = ear
    _last_out["mar"] = mar
    _last_out["perclos"] = pc
    _last_out["blink_rpm"] = blink_rpm
    _last_out["yawn_rpm"] = yawn_rpm
    _last_out["micro_cnt"] = micro_cnt
    _last_out["head"] = head
    _last_out["attn"] = attn
    _last_out["distracted"] = int(distracted)
    _last_out["signal"] = signal
    _last_out["armed"] = 1 if _drowsy_armed else 0
    _last_out["face_lock"] = int(face_lock_now)

    _log_status(status, _fatigue, now)
    _publish_signal(status, signal, _fatigue, now)
    _publish_alert_event(status, _fatigue, now)
    return dict(_last_out), frame


_stop_event = threading.Event()

_frame_lock = threading.Lock()
_latest_cam_frame = None
_latest_cam_ts = 0.0
_latest_cam_seq = 0
_new_frame_event = threading.Event()

_proc_lock = threading.Lock()
_latest_proc_frame = None
_latest_proc_out = dict(_last_out)
_latest_proc_seq = 0
_latest_proc_ts = 0.0
_new_proc_event = threading.Event()

_perf_lock = threading.Lock()
_proc_fps = 0.0
_proc_last_ms = 0.0
_proc_skip_n = 2


def _draw_fatigue_bar(panel, x, y, w, h, fatigue):
    """Draw a horizontal fatigue meter with gradient fill."""
    # Background
    cv2.rectangle(panel, (x, y), (x + w, y + h), COLOR_BAR_BG, -1)
    cv2.rectangle(panel, (x, y), (x + w, y + h), COLOR_PANEL_BORDER, 1)
    # Fill
    fill_w = max(0, int((fatigue / 100.0) * (w - 2)))
    if fill_w > 0:
        if fatigue >= 70:
            bar_color = COLOR_DANG
        elif fatigue >= 40:
            bar_color = COLOR_WARN
        else:
            bar_color = COLOR_SAFE
        cv2.rectangle(panel, (x + 1, y + 1), (x + 1 + fill_w, y + h - 1), bar_color, -1)


def _draw_calibration_overlay(frame, out, now_ms):
    """Full-screen calibration overlay with circular progress and countdown."""
    h, w = frame.shape[:2]
    armed = int(out.get("armed", 1)) == 1
    if armed or not PI_ARM_GATE_ENABLED:
        return frame

    if _attentive_since_ms > 0:
        elapsed = max(0, now_ms - _attentive_since_ms)
        arm_ms = max(1, ATTENTIVE_ARM_MS)
        pct = min(99, int((elapsed * 100) / arm_ms))
        remain_s = max(0, int((arm_ms - elapsed) / 1000))
    else:
        pct = 0
        remain_s = int(ATTENTIVE_ARM_MS / 1000)

    # Semi-transparent dark overlay at the bottom
    overlay_h = 38
    oy = h - overlay_h
    overlay = frame[oy:h, 0:w].copy()
    dark = np.zeros_like(overlay)
    cv2.addWeighted(dark, 0.55, overlay, 0.45, 0, overlay)
    frame[oy:h, 0:w] = overlay

    # Progress arc (mini circle at bottom-right)
    cx = w - 24
    cy = h - 20
    radius = 14
    # Background circle
    cv2.circle(frame, (cx, cy), radius, COLOR_PANEL_BORDER, 2)
    # Arc progress
    angle = int(pct * 3.6)  # 0-360
    if angle > 0:
        cv2.ellipse(frame, (cx, cy), (radius, radius), -90, 0, angle, COLOR_ACCENT, 2)

    # Percentage text inside arc
    pct_text = f"{pct}%"
    (tw, _), _ = cv2.getTextSize(pct_text, cv2.FONT_HERSHEY_SIMPLEX, 0.30, 1)
    cv2.putText(frame, pct_text, (cx - tw // 2, cy + 4),
                cv2.FONT_HERSHEY_SIMPLEX, 0.30, COLOR_TEXT, 1)

    # Countdown text
    calib_label = f"NHIN THANG: {remain_s}s"
    cv2.putText(frame, calib_label, (6, h - 22),
                cv2.FONT_HERSHEY_SIMPLEX, 0.38, COLOR_ACCENT, 1)

    # Animated progress bar
    bar_x = 6
    bar_y = h - 10
    bar_w = w - 48
    bar_h = 5
    cv2.rectangle(frame, (bar_x, bar_y), (bar_x + bar_w, bar_y + bar_h), COLOR_PANEL_BORDER, -1)
    fill = int(pct * bar_w / 100)
    if fill > 0:
        cv2.rectangle(frame, (bar_x, bar_y), (bar_x + fill, bar_y + bar_h), COLOR_ACCENT, -1)

    return frame


def _draw_danger_vignette(frame, now_ms):
    """Draw pulsing red vignette border for danger states."""
    h, w = frame.shape[:2]
    # Pulsing intensity
    phase = (now_ms % 800) / 800.0
    intensity = abs(math.sin(phase * math.pi))
    thickness = max(2, int(3 + intensity * 2))

    # Multi-layer border with decreasing opacity
    for i in range(3):
        alpha_factor = (3 - i) / 3.0 * intensity
        border_color = (
            int(COLOR_DANG[0] * alpha_factor),
            int(COLOR_DANG[1] * alpha_factor),
            int(COLOR_DANG[2] * alpha_factor),
        )
        offset = i * 2
        cv2.rectangle(frame, (offset, offset), (w - 1 - offset, h - 1 - offset),
                      border_color, thickness - i)


def _draw_ui(frame, out, fps, infer_ms, now_ms, ui_state, redraw_panel):
    global _attentive_since_ms
    status = out.get("status", "NO FACE")
    fatigue = int(out.get("fatigue", 0))
    blink = int(out.get("blink_total", 0))
    armed = int(out.get("armed", 1)) == 1

    target = _status_color(status)
    ui_color = ui_state["color"]
    ui_color[0] = (ui_color[0] * 0.75) + (target[0] * 0.25)
    ui_color[1] = (ui_color[1] * 0.75) + (target[1] * 0.25)
    ui_color[2] = (ui_color[2] * 0.75) + (target[2] * 0.25)
    smooth_color = (int(ui_color[0]), int(ui_color[1]), int(ui_color[2]))

    h, w = frame.shape[:2]
    panel_w = min(PANEL_W, w)
    panel_h = min(PANEL_H, h)
    x1 = 3
    y1 = 3
    x2 = min(x1 + panel_w, w)
    y2 = min(y1 + panel_h, h)
    panel_w = x2 - x1
    panel_h = y2 - y1
    roi = frame[y1:y2, x1:x2]

    # ─── Re-render panel text only when needed ───
    if (
        redraw_panel
        or ui_state["panel"] is None
        or ui_state["panel_w"] != panel_w
        or ui_state["panel_h"] != panel_h
    ):
        panel = roi.copy()
        # Dark glassmorphism panel background
        cv2.rectangle(panel, (0, 0), (panel_w - 1, panel_h - 1), COLOR_PANEL_BG, -1)
        # Accent top bar (color follows status)
        cv2.rectangle(panel, (0, 0), (panel_w - 1, 2), smooth_color, -1)
        # Subtle border
        cv2.rectangle(panel, (0, 0), (panel_w - 1, panel_h - 1), COLOR_PANEL_BORDER, 1)

        # ─── Status badge with background highlight ───
        status_short = status
        if status == "ATTENTIVE":
            status_short = "AN TOAN"
        elif status == "AWAKE":
            status_short = "TINH TAO"
        elif status == "NO FACE":
            status_short = "KHONG MAT"
        elif status == "MICROSLEEP":
            status_short = "NGU GAT!"

        # Status text with colored background pill
        (stw, sth), _ = cv2.getTextSize(status_short, cv2.FONT_HERSHEY_SIMPLEX, 0.40, 1)
        badge_x = 5
        badge_y = 6
        badge_pad = 3
        cv2.rectangle(panel,
                      (badge_x, badge_y),
                      (badge_x + stw + badge_pad * 2, badge_y + sth + badge_pad * 2),
                      smooth_color, -1)
        cv2.putText(panel, status_short,
                    (badge_x + badge_pad, badge_y + sth + badge_pad),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.40, COLOR_PANEL_BG, 1)

        # ─── Fatigue meter ───
        y_off = 26
        cv2.putText(panel, "Fatigue", (5, y_off + 4),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.32, COLOR_TEXT_DIM, 1)
        _draw_fatigue_bar(panel, 50, y_off - 5, panel_w - 56, 8, fatigue)
        cv2.putText(panel, f"{fatigue}", (panel_w - 22, y_off + 4),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.32, COLOR_TEXT, 1)

        # ─── Metrics grid (2 columns) ───
        y_off = 40
        col1_x = 5
        col2_x = panel_w // 2 + 2
        line_h = 14

        # Blink count
        cv2.putText(panel, f"Blink:{blink:3d}", (col1_x, y_off),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.33, COLOR_TEXT_DIM, 1)
        # FPS
        cv2.putText(panel, f"FPS:{fps:4.1f}", (col2_x, y_off),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.33, COLOR_TEXT_DIM, 1)

        y_off += line_h
        # Inference time
        cv2.putText(panel, f"INF:{infer_ms:4.1f}ms", (col1_x, y_off),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.33, COLOR_TEXT_DIM, 1)

        # EAR value if available
        ear_val = out.get("ear", 0.0)
        if isinstance(ear_val, (int, float)):
            cv2.putText(panel, f"EAR:{int(ear_val * 1000):3d}", (col2_x, y_off),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.33, COLOR_TEXT_DIM, 1)

        # ─── Separator line ───
        y_off += 6
        cv2.line(panel, (5, y_off), (panel_w - 6, y_off), COLOR_PANEL_BORDER, 1)

        # ─── Arm/Detection status ───
        y_off += 12
        if PI_ARM_GATE_ENABLED and (not armed):
            if _attentive_since_ms > 0:
                remain_ms = max(0, ATTENTIVE_ARM_MS - (now_ms - _attentive_since_ms))
            else:
                remain_ms = ATTENTIVE_ARM_MS
            remain_s = int(remain_ms / 1000)
            arm_text = f"Calib: {remain_s:2d}s"
            arm_color = COLOR_ACCENT
            # Mini calibration bar inside panel
            pct_done = 100 - int((remain_ms * 100) / ATTENTIVE_ARM_MS)
            cv2.putText(panel, arm_text, (col1_x, y_off),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.35, arm_color, 1)
            bar_y = y_off + 4
            bar_w = panel_w - 12
            cv2.rectangle(panel, (col1_x, bar_y), (col1_x + bar_w, bar_y + 4), COLOR_BAR_BG, -1)
            fill_w = int(pct_done * bar_w / 100)
            if fill_w > 0:
                cv2.rectangle(panel, (col1_x, bar_y), (col1_x + fill_w, bar_y + 4), arm_color, -1)
        else:
            buzz = _expected_buzzer_code(status, armed)
            det_label = "ON" if armed else "OFF"
            det_color = COLOR_SAFE if armed else COLOR_WARN
            cv2.putText(panel, f"DET:{det_label}", (col1_x, y_off),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.33, det_color, 1)
            cv2.putText(panel, f"BZ:{buzz}", (col2_x, y_off),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.33, det_color, 1)

        ui_state["panel"] = panel
        ui_state["panel_w"] = panel_w
        ui_state["panel_h"] = panel_h

    # ─── Blend panel onto frame (glassmorphism) ───
    cv2.addWeighted(ui_state["panel"], 0.58, roi, 0.42, 0, roi)

    # ─── Calibration overlay at bottom ───
    if PI_ARM_GATE_ENABLED and not armed:
        frame = _draw_calibration_overlay(frame, out, now_ms)

    # ─── Danger state: pulsing vignette border ───
    if status in ("DROWSY", "MICROSLEEP", "HEAD DOWN"):
        _draw_danger_vignette(frame, now_ms)

    return frame


def _cloud_push_worker():
    global _last_cloud_err_ms
    headers = {"Content-Type": "application/json; charset=utf-8"}
    if CLOUD_API_TOKEN:
        headers["Authorization"] = f"Bearer {CLOUD_API_TOKEN}"

    while not _stop_event.is_set():
        item = _cloud_next_item()
        if item is None:
            _cloud_queue_event.clear()
            _cloud_queue_event.wait(0.25)
            continue

        now_ms = int(time.monotonic() * 1000)
        if NETWORK_SEND_REQUIRE_WIFI and (not _can_send_network(now_ms)):
            item["retry"] = int(item.get("retry", 0)) + 1
            if item["retry"] <= 2:
                _cloud_requeue_front(item)
            _stop_event.wait(0.25)
            continue

        url = f"{CLOUD_API_BASE_URL}{item.get('path', '')}"
        try:
            body = json.dumps(item.get("payload", {}), separators=(",", ":")).encode("utf-8")
            req = urllib_request.Request(url, data=body, headers=headers, method="POST")
            with urllib_request.urlopen(req, timeout=CLOUD_PUSH_TIMEOUT_S) as resp:
                code = int(getattr(resp, "status", 200))
            if code < 200 or code >= 300:
                raise RuntimeError(f"http {code}")
        except Exception as exc:
            item["retry"] = int(item.get("retry", 0)) + 1
            if item["retry"] <= 2:
                _cloud_requeue_front(item)

            if isinstance(exc, urllib_error.HTTPError):
                detail = f"HTTP {exc.code}"
            else:
                detail = str(exc)
            if (now_ms - _last_cloud_err_ms) >= 2500:
                print(f"[CLOUD] push failed: {detail}")
                _last_cloud_err_ms = now_ms
            _stop_event.wait(0.12 if item["retry"] <= 2 else 0.35)


def _mqtt_reconnect_worker():
    global _mqtt_retry_ms, _mqtt_next_retry_ms

    while not _stop_event.is_set():
        if mqtt_client is None or _mqtt_connected:
            _stop_event.wait(0.2)
            continue

        now_ms = int(time.monotonic() * 1000)
        if NETWORK_SEND_REQUIRE_WIFI and (not _can_send_network(now_ms)):
            _stop_event.wait(0.25)
            continue
        if _mqtt_next_retry_ms == 0:
            _mqtt_next_retry_ms = now_ms + _mqtt_retry_ms

        if now_ms < _mqtt_next_retry_ms:
            _stop_event.wait(0.05)
            continue

        try:
            rc = mqtt_client.reconnect()
            if rc == mqtt.MQTT_ERR_SUCCESS:
                _mqtt_next_retry_ms = 0
                _mqtt_retry_ms = MQTT_RETRY_BASE_MS
            else:
                _mqtt_next_retry_ms = now_ms + _mqtt_retry_ms
                _mqtt_retry_ms = min(_mqtt_retry_ms * 2, MQTT_RETRY_MAX_MS)
        except Exception:
            _mqtt_next_retry_ms = now_ms + _mqtt_retry_ms
            _mqtt_retry_ms = min(_mqtt_retry_ms * 2, MQTT_RETRY_MAX_MS)

        _stop_event.wait(0.05)


def _wifi_lock_worker():
    while not _stop_event.is_set():
        _enforce_wifi_lock()
        _stop_event.wait(max(0.4, WIFI_LOCK_CHECK_MS / 1000.0))


def _usb_api_candidates():
    api_map = {
        "any": "CAP_ANY",
        "auto": "CAP_ANY",
        "v4l2": "CAP_V4L2",
        "dshow": "CAP_DSHOW",
        "msmf": "CAP_MSMF",
        "avfoundation": "CAP_AVFOUNDATION",
        "gstreamer": "CAP_GSTREAMER",
        "ffmpeg": "CAP_FFMPEG",
    }
    primary_const = api_map.get(USB_CAMERA_API, "CAP_ANY")
    primary = getattr(cv2, primary_const, cv2.CAP_ANY)
    any_api = cv2.CAP_ANY
    if primary == any_api:
        return [any_api]
    return [primary, any_api]


def _open_usb_camera():
    source = _parse_camera_source(USB_CAMERA_SOURCE)
    for api in _usb_api_candidates():
        try:
            if api == cv2.CAP_ANY:
                cap = cv2.VideoCapture(source)
            else:
                cap = cv2.VideoCapture(source, api)
        except Exception:
            continue
        if cap is None or (not cap.isOpened()):
            if cap is not None:
                cap.release()
            continue
        if USB_CAMERA_WIDTH > 0:
            cap.set(cv2.CAP_PROP_FRAME_WIDTH, USB_CAMERA_WIDTH)
        if USB_CAMERA_HEIGHT > 0:
            cap.set(cv2.CAP_PROP_FRAME_HEIGHT, USB_CAMERA_HEIGHT)
        if USB_CAMERA_FPS > 0:
            cap.set(cv2.CAP_PROP_FPS, USB_CAMERA_FPS)
        cap.set(cv2.CAP_PROP_BUFFERSIZE, 1)
        return cap
    return None


def _camera_worker_usb(cap, stream_format):
    global _latest_cam_frame, _latest_cam_ts, _latest_cam_seq
    last_cam_err_ms = 0
    last_cam_invalid_ms = 0
    fail_count = 0
    CAM_FAIL_REOPEN = 5

    while not _stop_event.is_set():
        ok, raw = cap.read()
        if (not ok) or raw is None:
            fail_count += 1
            now_ms = int(time.monotonic() * 1000)
            if now_ms - last_cam_err_ms > CAM_LOG_GAP_MS:
                print(f"USB CAMERA READ FAILED (x{fail_count})")
                last_cam_err_ms = now_ms
            if fail_count >= CAM_FAIL_REOPEN:
                print("[CAM] forcing camera reopen")
                try:
                    cap.release()
                except Exception:
                    pass
                _stop_event.wait(0.5)
                new_cap = _open_usb_camera()
                if new_cap is not None:
                    cap = new_cap
                    fail_count = 0
                    print("[CAM] camera reopened OK")
                else:
                    print("[CAM] camera reopen FAILED, retrying...")
                    _stop_event.wait(1.0)
                continue
            _stop_event.wait(0.008)
            continue

        fail_count = 0

        frame = _normalize_camera_frame(raw, stream_format)
        if not _is_valid_color_frame(frame):
            now_ms = int(time.monotonic() * 1000)
            if now_ms - last_cam_invalid_ms >= CAM_LOG_GAP_MS:
                print(f"USB CAMERA INVALID FRAME SHAPE: {getattr(frame, 'shape', None)}")
                last_cam_invalid_ms = now_ms
            _stop_event.wait(0.003)
            continue

        if not _is_expected_frame_size(frame):
            frame = cv2.resize(frame, (FRAME_W, FRAME_H), interpolation=cv2.INTER_AREA)

        frame = np.ascontiguousarray(frame)
        if not _is_valid_color_frame(frame):
            _stop_event.wait(0.003)
            continue

        frame_ts = time.monotonic()
        with _frame_lock:
            _latest_cam_frame = frame
            _latest_cam_ts = frame_ts
            _latest_cam_seq += 1
        _new_frame_event.set()


def _processing_worker():
    global _latest_proc_frame, _latest_proc_out, _latest_proc_seq, _latest_proc_ts
    global _proc_fps, _proc_last_ms, _proc_skip_n

    last_seq = -1
    last_invalid_log_ms = 0
    frame_count = 0
    output_count = 0
    fps_t0 = time.monotonic()
    last_perf_log_ms = 0
    last_frame_seen_ts = time.monotonic()
    frame_stale_for_noface_s = 0.35

    while not _stop_event.is_set():
        if not _new_frame_event.wait(0.03):
            now_mono = time.monotonic()
            if (now_mono - last_frame_seen_ts) >= frame_stale_for_noface_s:
                out, _ = process_frame(None)
                with _proc_lock:
                    _latest_proc_out = dict(out)
                    _latest_proc_seq += 1
                    _latest_proc_ts = now_mono
                _new_proc_event.set()
            else:
                last_out = _last_out
                now_ms = int(now_mono * 1000)
                _publish_signal(
                    last_out.get("status", "NO FACE"),
                    last_out.get("signal", 0),
                    last_out.get("fatigue", 0),
                    now_ms,
                )
            continue

        with _frame_lock:
            seq = _latest_cam_seq
            frame = _latest_cam_frame
            frame_ts = _latest_cam_ts
            _new_frame_event.clear()

        if frame is None or seq == last_seq:
            continue
        last_frame_seen_ts = frame_ts if frame_ts > 0.0 else time.monotonic()
        frame = _ensure_frame_ownership(frame)
        if frame is None:
            continue
        if frame_ts > 0.0 and (time.monotonic() - frame_ts) > 0.2:
            _stop_event.wait(0.002)
            continue
        if not _is_valid_color_frame(frame):
            now_ms = int(time.monotonic() * 1000)
            if now_ms - last_invalid_log_ms >= CAM_LOG_GAP_MS:
                print(f"PROC SKIP INVALID FRAME: type={type(frame).__name__} shape={getattr(frame, 'shape', None)}")
                last_invalid_log_ms = now_ms
            _stop_event.wait(0.002)
            continue
        if not _is_expected_frame_size(frame):
            _stop_event.wait(0.002)
            continue
        last_seq = seq
        frame_count += 1

        skip_n = _proc_skip_n
        if skip_n > 1 and (frame_count % skip_n) != 0:
            last_out = _last_out
            now_ms = int(time.monotonic() * 1000)
            _publish_signal(
                last_out.get("status", "NO FACE"),
                last_out.get("signal", 0),
                last_out.get("fatigue", 0),
                now_ms,
            )
            skip_frame = frame
            with _proc_lock:
                _latest_proc_frame = skip_frame
                _latest_proc_out = dict(last_out)
                _latest_proc_seq += 1
                _latest_proc_ts = frame_ts if frame_ts > 0.0 else time.monotonic()
            _new_proc_event.set()

            output_count += 1
            if output_count >= 30:
                t1 = time.monotonic()
                fps_val = output_count / (t1 - fps_t0 + 1e-9)
                output_count = 0
                fps_t0 = t1
                with _perf_lock:
                    _proc_fps = fps_val
            continue

        proc_start = time.monotonic()
        out, proc_frame = process_frame(frame)
        proc_ms = (time.monotonic() - proc_start) * 1000.0

        if proc_frame is None or proc_frame.size == 0:
            _stop_event.wait(0.005)
            continue

        infer_ms = _last_infer_time_ms
        if infer_ms > 100:
            base_skip_n = 6
        elif infer_ms > 80:
            base_skip_n = 4
        elif infer_ms > 60:
            base_skip_n = 3
        else:
            base_skip_n = 1

        # Keep status transitions responsive while still reducing load.
        status_now = out.get("status", "NO FACE")
        if status_now in DANGER_STATES:
            _proc_skip_n = min(base_skip_n, 1)
        elif status_now in WARN_STATES:
            _proc_skip_n = min(base_skip_n, 2)
        else:
            _proc_skip_n = base_skip_n
        output_count += 1
        if output_count >= 30:
            t1 = time.monotonic()
            fps_val = output_count / (t1 - fps_t0 + 1e-9)
            output_count = 0
            fps_t0 = t1
            with _perf_lock:
                _proc_fps = fps_val

        with _perf_lock:
            _proc_last_ms = proc_ms

        with _proc_lock:
            _latest_proc_frame = proc_frame
            _latest_proc_out = out
            _latest_proc_seq += 1
            _latest_proc_ts = frame_ts if frame_ts > 0.0 else time.monotonic()
        _new_proc_event.set()

        now_ms = int(time.monotonic() * 1000)
        if now_ms - last_perf_log_ms >= PERF_LOG_GAP_MS:
            with _perf_lock:
                fps_snapshot = _proc_fps
                proc_snapshot = _proc_last_ms
                skip_snapshot = _proc_skip_n
            print(
                f"PERF FPS:{fps_snapshot:4.1f} "
                f"INF:{infer_ms:4.1f}ms PROC:{proc_snapshot:4.1f}ms SKIP:{skip_snapshot}"
            )
            last_perf_log_ms = now_ms


def _display_loop():
    cv2.namedWindow("Drowsy Monitor", cv2.WINDOW_NORMAL)

    ui_state = {
        "panel": None,
        "panel_w": 0,
        "panel_h": 0,
        "color": [float(COLOR_SAFE[0]), float(COLOR_SAFE[1]), float(COLOR_SAFE[2])],
        "status": "",
        "fatigue": -1,
        "blink": -1,
        "fps": -1.0,
    }

    ui_tick = 0
    local_seq = -1
    frame = None
    last_rendered_frame = None
    last_display_invalid_ms = 0
    out = dict(_last_out)

    while not _stop_event.is_set():
        _new_proc_event.wait(0.008)
        with _proc_lock:
            proc_frame = _latest_proc_frame
            proc_ts = _latest_proc_ts
            if _latest_proc_seq != local_seq:
                out = dict(_latest_proc_out)
                proc_frame = _latest_proc_frame
                proc_ts = _latest_proc_ts
                local_seq = _latest_proc_seq
            _new_proc_event.clear()

        now_monotonic = time.monotonic()
        is_stale = (proc_ts > 0.0) and ((now_monotonic - proc_ts) > 0.35)
        if proc_frame is None or is_stale or (not _is_valid_color_frame(proc_frame)):
            now_ms = int(time.monotonic() * 1000)
            if now_ms - last_display_invalid_ms >= CAM_LOG_GAP_MS:
                if proc_frame is None:
                    print("DISPLAY WAIT PROC FRAME")
                elif is_stale:
                    print(f"DISPLAY STALE FRAME: age={int((now_monotonic - proc_ts) * 1000)}ms")
                else:
                    print(
                        f"DISPLAY INVALID FRAME: type={type(proc_frame).__name__} "
                        f"shape={getattr(proc_frame, 'shape', None)}"
                    )
                last_display_invalid_ms = now_ms
            if last_rendered_frame is not None:
                cv2.imshow("Drowsy Monitor", last_rendered_frame)
            if cv2.waitKey(1) & 0xFF == ord("q"):
                _stop_event.set()
                break
            _stop_event.wait(0.002)
            continue

        frame = proc_frame.copy()

        with _perf_lock:
            fps = _proc_fps
        infer_ms = _last_infer_time_ms

        status = out.get("status", "NO FACE")
        fatigue = int(out.get("fatigue", 0))
        blink = int(out.get("blink_total", 0))

        if _bbox_valid:
            bx1, by1, bx2, by2 = _bbox_smooth
            if bx2 > bx1 and by2 > by1:
                box_color = _status_color(status)
                bw = bx2 - bx1
                bh = by2 - by1
                corner_len = max(6, min(bw, bh) // 4)
                t = 2
                # Top-left corner
                cv2.line(frame, (bx1, by1), (bx1 + corner_len, by1), box_color, t)
                cv2.line(frame, (bx1, by1), (bx1, by1 + corner_len), box_color, t)
                # Top-right corner
                cv2.line(frame, (bx2, by1), (bx2 - corner_len, by1), box_color, t)
                cv2.line(frame, (bx2, by1), (bx2, by1 + corner_len), box_color, t)
                # Bottom-left corner
                cv2.line(frame, (bx1, by2), (bx1 + corner_len, by2), box_color, t)
                cv2.line(frame, (bx1, by2), (bx1, by2 - corner_len), box_color, t)
                # Bottom-right corner
                cv2.line(frame, (bx2, by2), (bx2 - corner_len, by2), box_color, t)
                cv2.line(frame, (bx2, by2), (bx2, by2 - corner_len), box_color, t)

        redraw_panel = (
            (ui_tick % 2) == 0
            or status != ui_state["status"]
            or fatigue != ui_state["fatigue"]
            or blink != ui_state["blink"]
            or abs(fps - ui_state["fps"]) >= 0.6
        )
        now_ms = int(time.monotonic() * 1000)
        frame = _draw_ui(frame, out, fps, infer_ms, now_ms, ui_state, redraw_panel)

        if redraw_panel:
            ui_state["status"] = status
            ui_state["fatigue"] = fatigue
            ui_state["blink"] = blink
            ui_state["fps"] = fps
        ui_tick += 1

        last_rendered_frame = frame
        try:
            cv2.imshow("Drowsy Monitor", frame)
            if cv2.waitKey(1) & 0xFF == ord("q"):
                _stop_event.set()
                break
        except Exception:
            pass


def _headless_loop():
    """Run without display window (SSH / headless Pi)."""
    import signal as _sig

    def _handle_stop(_s, _f):
        _stop_event.set()

    _sig.signal(_sig.SIGINT, _handle_stop)
    _sig.signal(_sig.SIGTERM, _handle_stop)

    while not _stop_event.is_set():
        _stop_event.wait(0.1)


def main():
    global MQTT_BROKER, MQTT_PORT
    global ESP32_WIFI_SERIAL_PORT, ESP32_WIFI_SERIAL_BAUD, PI_WIFI_INTERFACE
    global USB_CAMERA_SOURCE, USB_CAMERA_WIDTH, USB_CAMERA_HEIGHT, USB_CAMERA_FPS

    parser = argparse.ArgumentParser(description="Drowsiness Edge Detection — RPi4 + ESP32")
    parser.add_argument("--camera", default="0", help="Camera source (default: 0)")
    parser.add_argument("--mqtt-host", default=None, help="MQTT broker host (default: 127.0.0.1)")
    parser.add_argument("--mqtt-port", type=int, default=None, help="MQTT broker port (default: 1883)")
    parser.add_argument("--width", type=int, default=224, help="Frame width (default: 224)")
    parser.add_argument("--height", type=int, default=168, help="Frame height (default: 168)")
    parser.add_argument("--fps", type=int, default=30, help="Camera FPS target (default: 30)")
    parser.add_argument("--esp32-serial", default=None, help="ESP32 serial device for WiFi sync (default: /dev/ttyUSB0)")
    parser.add_argument("--esp32-baud", type=int, default=None, help="ESP32 serial baud for WiFi sync (default: 115200)")
    parser.add_argument("--pi-wifi-iface", default=None, help="Pi WiFi interface for nmcli connect (default: wlan0)")
    parser.add_argument("--no-preview", dest="preview", action="store_false", default=True,
                        help="Disable preview window (headless mode)")
    parser.add_argument("--verbose", action="store_true", help="Verbose logging")
    args = parser.parse_args()

    # Apply CLI overrides
    USB_CAMERA_SOURCE = args.camera
    USB_CAMERA_WIDTH = args.width
    USB_CAMERA_HEIGHT = args.height
    USB_CAMERA_FPS = args.fps
    if args.mqtt_host is not None:
        MQTT_BROKER = args.mqtt_host
    if args.mqtt_port is not None:
        MQTT_PORT = args.mqtt_port
    if args.esp32_serial is not None:
        ESP32_WIFI_SERIAL_PORT = args.esp32_serial
    if args.esp32_baud is not None and args.esp32_baud > 0:
        ESP32_WIFI_SERIAL_BAUD = args.esp32_baud
    if args.pi_wifi_iface is not None:
        PI_WIFI_INTERFACE = args.pi_wifi_iface

    # Init MQTT after CLI args are applied
    _init_mqtt()

    camera = _open_usb_camera()
    if camera is None:
        print(f"Camera init failed: cannot open USB camera source '{USB_CAMERA_SOURCE}'")
        return
    stream_format = "BGR"

    print(
        f"USB source={USB_CAMERA_SOURCE} api={USB_CAMERA_API} "
        f"target={USB_CAMERA_WIDTH}x{USB_CAMERA_HEIGHT}@{USB_CAMERA_FPS}"
    )
    print(f"MQTT broker={MQTT_BROKER}:{MQTT_PORT}")
    if CLOUD_PUSH_ENABLED:
        print(f"Cloud API push=ON base={CLOUD_API_BASE_URL} device={EDGE_DEVICE_ID}")
    else:
        print("Cloud API push=OFF")
    if INTERNAL_WIFI_SYNC_ENABLED:
        print(f"WiFi sync mode=INTERNAL (in drowsy_edge.py)")
        print(f"WiFi sync serial={ESP32_WIFI_SERIAL_PORT}@{ESP32_WIFI_SERIAL_BAUD} iface={PI_WIFI_INTERFACE}")
        print(f"WiFi lock mode={'ON (ESP32 SSID only)' if WIFI_LOCK_TO_ESP32 else 'OFF'}")
    else:
        print("WiFi sync mode=EXTERNAL daemon (esp32_wifi_bridge.py)")
    print(f"Pi arm gate={'ON(5s)' if PI_ARM_GATE_ENABLED else 'OFF (ESP32 handles 5s gate)'}")
    print(f"Preview={'ON' if args.preview else 'OFF (headless)'}")

    try:
        actual_w = int(camera.get(cv2.CAP_PROP_FRAME_WIDTH))
        actual_h = int(camera.get(cv2.CAP_PROP_FRAME_HEIGHT))
        actual_fps = float(camera.get(cv2.CAP_PROP_FPS))
    except Exception:
        actual_w = 0
        actual_h = 0
        actual_fps = 0.0
    if actual_w > 0 and actual_h > 0:
        print(f"USB active mode: {actual_w}x{actual_h}@{actual_fps:.1f}")

    print("Press q to quit" if args.preview else "Press Ctrl+C to quit")

    cam_thread = threading.Thread(
        target=_camera_worker_usb,
        args=(camera, stream_format),
        name="camera",
        daemon=True,
    )
    proc_thread = threading.Thread(target=_processing_worker, name="processor", daemon=True)
    mqtt_thread = threading.Thread(target=_mqtt_reconnect_worker, name="mqtt-reconnect", daemon=True)
    cloud_thread = None
    wifi_sync_thread = None
    wifi_lock_thread = None
    cam_thread.start()
    proc_thread.start()
    mqtt_thread.start()
    if CLOUD_PUSH_ENABLED:
        cloud_thread = threading.Thread(target=_cloud_push_worker, name="cloud-push", daemon=True)
        cloud_thread.start()
    if INTERNAL_WIFI_SYNC_ENABLED:
        wifi_sync_thread = threading.Thread(target=_esp32_wifi_sync_worker, name="wifi-sync", daemon=True)
        wifi_lock_thread = threading.Thread(target=_wifi_lock_worker, name="wifi-lock", daemon=True)
        wifi_sync_thread.start()
        wifi_lock_thread.start()

    try:
        if args.preview:
            _display_loop()
        else:
            _headless_loop()
    finally:
        _stop_event.set()
        _new_frame_event.set()
        _new_proc_event.set()
        cam_thread.join(timeout=1.5)
        proc_thread.join(timeout=1.5)
        mqtt_thread.join(timeout=1.0)
        if cloud_thread is not None:
            cloud_thread.join(timeout=1.0)
        if wifi_sync_thread is not None:
            wifi_sync_thread.join(timeout=1.0)
        if wifi_lock_thread is not None:
            wifi_lock_thread.join(timeout=1.0)

        # Send SAFE signal to ESP32 before disconnecting
        try:
            if mqtt_client is not None:
                mqtt_client.publish(MQTT_TOPIC, "0", qos=MQTT_STATUS_QOS, retain=False)
                time.sleep(0.05)
                mqtt_client.publish(MQTT_TOPIC, "0", qos=MQTT_STATUS_QOS, retain=False)
                mqtt_client.disconnect()
                mqtt_client.loop_stop()
        except Exception as exc:
            print("MQTT cleanup error:", exc)

        try:
            camera.release()
        except Exception:
            pass
        try:
            cv2.destroyAllWindows()
        except Exception:
            pass
        print("Shutdown complete.")


if __name__ == "__main__":
    main()
