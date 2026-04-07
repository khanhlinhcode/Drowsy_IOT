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
MQTT_HEARTBEAT_MS = 400       # mandatory for ESP32 anti-freeze
MQTT_RETRY_MIN_S = 1
MQTT_RETRY_MAX_S = 8
MQTT_ERR_LOG_GAP_MS = 3000
MQTT_STATE_TTL_MS = 1400
MQTT_LOG_GAP_MS = 1500
MQTT_META_MIN_MS = 100
MQTT_RETRY_BASE_MS = 500
MQTT_RETRY_MAX_MS = 8000

ESP32_WIFI_SERIAL_PORT = os.getenv("ESP32_WIFI_SERIAL_PORT", "/dev/ttyUSB0")
ESP32_WIFI_SERIAL_BAUD = int(os.getenv("ESP32_WIFI_SERIAL_BAUD", "115200"))
PI_WIFI_INTERFACE = os.getenv("PI_WIFI_INTERFACE", "wlan0")
DEFAULT_CMD_TIMEOUT_S = 25
WIFI_SYNC_DUP_WINDOW_MS = 15000
WIFI_SYNC_RETRY_DELAY_S = 2.0

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


def _on_mqtt_connect(_client, _userdata, _flags, rc, *_args):
    global _mqtt_connected, _mqtt_force_sync
    global _mqtt_retry_ms, _mqtt_next_retry_ms
    if rc == 0:
        _mqtt_connected = True
        _mqtt_force_sync = True
        _mqtt_retry_ms = MQTT_RETRY_BASE_MS
        _mqtt_next_retry_ms = 0
        print(f"MQTT connected broker={MQTT_BROKER}:{MQTT_PORT}")
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
    mqtt_client.max_inflight_messages_set(10)
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
            line = (res.stdout or "").strip().splitlines()
            if line:
                parts = line[0].split()
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


def _connect_pi_wifi(ssid, password, interface):
    global _wifi_sync_last_signature, _wifi_sync_last_attempt_ms
    now_ms = int(time.monotonic() * 1000)
    signature = f"{ssid}\n{password}\n{interface}"
    if signature == _wifi_sync_last_signature and (now_ms - _wifi_sync_last_attempt_ms) < WIFI_SYNC_DUP_WINDOW_MS:
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
    except Exception as exc:
        print(f"[WIFI_SYNC] Pi WiFi connect error: {exc}")


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
        _connect_pi_wifi(
            str(data.get("ssid", "")).strip(),
            str(data.get("pass", "")),
            PI_WIFI_INTERFACE,
        )
    elif msg_type == "wifi_connected":
        esp_ip = str(data.get("esp_ip", "")).strip()
        ssid = str(data.get("ssid", "")).strip()
        if esp_ip:
            print(f"[WIFI_SYNC] ESP32 connected: ssid='{ssid}' esp_ip={esp_ip}")


def _esp32_wifi_sync_worker():
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
            fd = os.open(serial_path, os.O_RDONLY | os.O_NONBLOCK)
            print(f"[WIFI_SYNC] listening {serial_path}@{ESP32_WIFI_SERIAL_BAUD}")
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
INFER_SAFE_MS = 125
INFER_RISK_MS = 75
INFER_NO_FACE_MS = 90

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
YAW_THRESH = 120
PITCH_THRESH = 560
ROLL_THRESH = 45
POSE_HOLD = 220
ATTN_LAT = 160
ATTN_DOWN = 500
ATTN_HOLD = 180
DISTRACT_HOLD = 1000

RELEASE_X10 = 18
MAX_HOLD = 4000

# State stability for demo-safe classification
DROWSY_HOLD_MS = 700
DANGER_HOLD_MS = 900
STATUS_MIN_SWITCH_MS = 180
DROWSY_ENTER = 80.0
DROWSY_EXIT = 62.0
VERY_TIRED_EXIT = 54.0
TIRED_EXIT = 34.0
FATIGUE_EMA_ALPHA_RISE = 0.18
FATIGUE_EMA_ALPHA_FALL = 0.34
STATUS_VOTE_WINDOW = 3
INFER_INTERVAL_MAX_MS = 220
FAST_RECOVERY_MS = 300
FAST_RECOVERY_FATIGUE = 60.0

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

# UI + colors
COLOR_SAFE = (0, 220, 0)
COLOR_WARN = (0, 215, 255)
COLOR_DANG = (0, 0, 255)
COLOR_TEXT = (245, 245, 245)
PANEL_H = 88
PANEL_W = 124
CAM_LOG_GAP_MS = 2000


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
}

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
    "HEAD DOWN": 3,
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
    "HEAD DOWN": "MICROSLEEP",
    "DISTRACTED": "SLEEPY",
    "LOOKING DOWN": "LOOKING DOWN",
    "LOOKING LEFT": "TIRED",
    "LOOKING RIGHT": "TIRED",
    "LOOKING SIDE": "TIRED",
    "HEAD TILT": "TIRED",
    "NO FACE": "ATTENTIVE",
}

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


def _publish_signal(status, signal, fatigue, now_ms):
    global _last_sent, _last_sent_signal, _last_sent_ms
    global _mqtt_seq, _mqtt_force_sync
    global _last_mqtt_meta_ms, _last_mqtt_meta_status
    global _last_mqtt_err_ms, _last_mqtt_log_ms, _last_mqtt_log_status

    if mqtt_client is None:
        return

    sig = int(signal)
    fat = int(fatigue)
    # Translate to text ESP32 understands
    esp_status = STATUS_TO_ESP32_TEXT.get(status, "ATTENTIVE")

    with _mqtt_pub_lock:
        status_changed = (status != _last_sent) or (sig != _last_sent_signal)
        should_send = _mqtt_force_sync or status_changed or ((now_ms - _last_sent_ms) >= MQTT_HEARTBEAT_MS)
        if not should_send:
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
            or (now_ms - _last_mqtt_meta_ms) >= MQTT_META_MIN_MS
        )
        meta_payload = None
        if meta_due:
            meta_payload = json.dumps(
                {
                    "seq": _mqtt_seq,
                    "ts_ms": now_ms,
                    "publish_ts_ms": publish_ts_ms,
                    "status": esp_status,
                    "signal": sig,
                    "fatigue": fat,
                    "ttl_ms": MQTT_STATE_TTL_MS,
                },
                separators=(",", ":"),
            )

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

    if status_changed or status != _last_mqtt_log_status or (now_ms - _last_mqtt_log_ms) >= MQTT_LOG_GAP_MS:
        print("MQTT PUB:", sig, "|", esp_status, "| FATIGUE:", fat)
        _last_mqtt_log_ms = now_ms
        _last_mqtt_log_status = status


def _log_status(status, fatigue, now_ms):
    global _last_print_status, _last_status_log_ms
    if status != _last_print_status or (now_ms - _last_status_log_ms) >= 5000:
        print("STATUS:", status, "| FATIGUE:", int(fatigue))
        _last_print_status = status
        _last_status_log_ms = now_ms


def _publish_alert_event(status, fatigue, now_ms):
    """Publish structured alert event to driver/alert_event when entering danger state."""
    global _alert_event_active, _alert_event_id
    global _alert_event_start_ms, _alert_event_trigger, _alert_event_last_status

    if mqtt_client is None or not _mqtt_connected:
        return

    is_danger = status in DANGER_STATES
    was_danger = _alert_event_last_status in DANGER_STATES

    if is_danger and not was_danger:
        # Entering danger state — publish alert start event.
        _alert_event_active = True
        _alert_event_id += 1
        _alert_event_start_ms = now_ms
        _alert_event_trigger = status

        event = {
            "event_id": f"evt-{_alert_session_id}-{_alert_event_id:04d}",
            "device_id": "rpi-drowsy-edge",
            "session_id": _alert_session_id,
            "event_type": "DROWSY_ALERT",
            "trigger_status": status,
            "fatigue_score": int(fatigue),
            "perclos": round(_perclos.value(), 3),
            "eye_closed_ms": int(float(now_ms - _eye_start) if _eye_closed and _eye_start > 0 else 0),
            "head_pose": _last_out.get("head", "CENTER"),
            "timestamp_ms": now_ms,
            "duration_ms": 0,
            "resolved": False,
        }
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

        event = {
            "event_id": f"evt-{_alert_session_id}-{_alert_event_id:04d}",
            "device_id": "rpi-drowsy-edge",
            "session_id": _alert_session_id,
            "event_type": "DROWSY_ALERT_RESOLVED",
            "trigger_status": _alert_event_trigger,
            "fatigue_score": int(fatigue),
            "perclos": round(_perclos.value(), 3),
            "eye_closed_ms": 0,
            "head_pose": _last_out.get("head", "CENTER"),
            "timestamp_ms": now_ms,
            "duration_ms": duration_ms,
            "resolved": True,
        }
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

    now = int(time.monotonic() * 1000)

    if frame is None or frame.size == 0:
        _fatigue = _clamp(_fatigue - 1.0)
        _bbox_valid = False
        _drowsy_latched = False
        _recovery_start_ts = 0
        _status_vote.clear()

        # 🔥 GIỮ trạng thái nguy hiểm
        if _last_out.get("status") in ["DROWSY", "MICROSLEEP"]:
            _publish_signal(_last_out["status"], _last_out["signal"], _fatigue, now)
            return dict(_last_out), frame

        if _last_out.get("status") != "NO FACE":
            _last_status_change_ms = now

        _last_out["status"] = "NO FACE"
        _last_out["fatigue"] = int(_fatigue)
        _last_out["fatigue_eval"] = int(_fatigue_ema)
        _last_out["blink_total"] = _blink_total
        _last_out["signal"] = 0

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
        _fatigue = _clamp(_fatigue - RATE_NO_FACE * 0.1 * dt_s)
        _bbox_valid = False
        _drowsy_latched = False
        _recovery_start_ts = 0
        _status_vote.clear()
        if _last_out.get("status") != "NO FACE":
            _last_status_change_ms = now
        _last_out["status"] = "NO FACE"
        _last_out["fatigue"] = int(_fatigue)
        _last_out["fatigue_eval"] = int(_fatigue_ema)
        _last_out["blink_total"] = _blink_total
        _last_out["signal"] = 0
        _publish_signal("NO FACE", 0, _fatigue, now)
        return dict(_last_out), frame

    _blink_ev.purge(ts)
    _yawn_ev.purge(ts)
    _micro_ev.purge(ts)

    if not res.face_landmarks:
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
        if _last_out.get("status") in ["DROWSY", "MICROSLEEP"]:
            _publish_signal(_last_out["status"], _last_out["signal"], _fatigue, now)
            return dict(_last_out), frame

        if _last_out.get("status") != "NO FACE":
            _last_status_change_ms = now

        _last_out["status"] = "NO FACE"
        _last_out["fatigue"] = int(_fatigue)
        _last_out["fatigue_eval"] = int(_fatigue_ema)
        _last_out["blink_total"] = _blink_total
        _last_out["signal"] = 0

        _publish_signal("NO FACE", 0, _fatigue, now)
        return dict(_last_out), frame
    lm = res.face_landmarks[0]
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
    _down_h = _accum(_down_h, dt) if (pitch * 1000 > PITCH_THRESH) else _decay(_down_h, dt)
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
    _adown_h = _accum(_adown_h, dt) if (pitch * 1000 >= ATTN_DOWN) else _decay(_adown_h, dt)

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


def _draw_ui(frame, out, fps, infer_ms, now_ms, ui_state, redraw_panel):
    status = out.get("status", "NO FACE")
    fatigue = int(out.get("fatigue", 0))
    blink = int(out.get("blink_total", 0))

    target = _status_color(status)
    ui_color = ui_state["color"]
    ui_color[0] = (ui_color[0] * 0.78) + (target[0] * 0.22)
    ui_color[1] = (ui_color[1] * 0.78) + (target[1] * 0.22)
    ui_color[2] = (ui_color[2] * 0.78) + (target[2] * 0.22)
    smooth_color = (int(ui_color[0]), int(ui_color[1]), int(ui_color[2]))

    h, w = frame.shape[:2]
    panel_w = min(PANEL_W, w)
    panel_h = min(PANEL_H, h)
    x1 = 4
    y1 = 4
    x2 = min(x1 + panel_w, w)
    y2 = min(y1 + panel_h, h)
    panel_w = x2 - x1
    panel_h = y2 - y1
    roi = frame[y1:y2, x1:x2]

    # Re-render panel text only every 2 frames or on value changes.
    if (
        redraw_panel
        or ui_state["panel"] is None
        or ui_state["panel_w"] != panel_w
        or ui_state["panel_h"] != panel_h
    ):
        panel = roi.copy()
        cv2.rectangle(panel, (0, 0), (panel_w - 1, panel_h - 1), (16, 16, 16), -1)
        cv2.rectangle(panel, (0, 0), (panel_w - 1, panel_h - 1), (42, 42, 42), 1)
        cv2.putText(panel, f"STATUS: {status}", (6, 16), cv2.FONT_HERSHEY_SIMPLEX, 0.40, smooth_color, 1)
        cv2.putText(panel, f"Fatigue: {fatigue:3d}", (6, 32), cv2.FONT_HERSHEY_SIMPLEX, 0.39, COLOR_TEXT, 1)
        cv2.putText(panel, f"Blink:   {blink:3d}", (6, 48), cv2.FONT_HERSHEY_SIMPLEX, 0.39, COLOR_TEXT, 1)
        cv2.putText(panel, f"FPS:     {fps:4.1f}", (6, 64), cv2.FONT_HERSHEY_SIMPLEX, 0.39, COLOR_TEXT, 1)
        cv2.putText(panel, f"INF:     {infer_ms:4.1f}ms", (6, 80), cv2.FONT_HERSHEY_SIMPLEX, 0.39, COLOR_TEXT, 1)
        ui_state["panel"] = panel
        ui_state["panel_w"] = panel_w
        ui_state["panel_h"] = panel_h

    cv2.addWeighted(ui_state["panel"], 0.52, roi, 0.48, 0, roi)

    if status in ("DROWSY", "MICROSLEEP", "HEAD DOWN") and ((now_ms // 220) & 1) == 0:
        cv2.rectangle(frame, (1, 1), (w - 2, h - 2), COLOR_DANG, 2)

    return frame


def _mqtt_reconnect_worker():
    global _mqtt_retry_ms, _mqtt_next_retry_ms

    while not _stop_event.is_set():
        if mqtt_client is None or _mqtt_connected:
            _stop_event.wait(0.2)
            continue

        now_ms = int(time.monotonic() * 1000)
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

        frame = np.ascontiguousarray(frame).copy()
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

    while not _stop_event.is_set():
        if not _new_frame_event.wait(0.03):
            last_out = _last_out
            now_ms = int(time.monotonic() * 1000)
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
        if frame_ts > 0.0 and (time.monotonic() - frame_ts) > 0.3:
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
            base_skip_n = 8
        elif infer_ms > 80:
            base_skip_n = 6
        elif infer_ms > 60:
            base_skip_n = 4
        else:
            base_skip_n = 2

        # Keep status transitions responsive while still reducing load.
        status_now = out.get("status", "NO FACE")
        if status_now in DANGER_STATES:
            _proc_skip_n = min(base_skip_n, 2)
        elif status_now in WARN_STATES:
            _proc_skip_n = min(base_skip_n, 3)
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
        if now_ms - last_perf_log_ms >= 2000:
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
    cv2.namedWindow("Drowsiness Edge", cv2.WINDOW_NORMAL)

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
                cv2.imshow("Drowsiness Edge", last_rendered_frame)
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
                cv2.rectangle(frame, (bx1, by1), (bx2, by2), _status_color(status), 2)

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
            cv2.imshow("Drowsiness Edge", frame)
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
    print(f"WiFi sync serial={ESP32_WIFI_SERIAL_PORT}@{ESP32_WIFI_SERIAL_BAUD} iface={PI_WIFI_INTERFACE}")
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
    wifi_sync_thread = threading.Thread(target=_esp32_wifi_sync_worker, name="wifi-sync", daemon=True)
    cam_thread.start()
    proc_thread.start()
    mqtt_thread.start()
    wifi_sync_thread.start()

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
        wifi_sync_thread.join(timeout=1.0)

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
