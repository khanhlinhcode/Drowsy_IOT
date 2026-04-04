"""
Production Raspberry Pi realtime drowsiness pipeline.

Architecture:
  camera thread -> inference thread -> state-engine thread -> mqtt-publisher thread
  with latest-frame handoff (no queue backlog).

MQTT protocol:
  driver/status      : integer signal 0..3
  driver/status_meta : {
      "seq": uint64,
      "ts_ms": uint64 monotonic,
      "status": "ATTENTIVE|TIRED|SLEEPY|MICROSLEEP",
      "signal": 0..3,
      "fatigue": 0..100,
      "ttl_ms": int
  }
"""

from __future__ import annotations

import argparse
import json
import logging
import random
import signal
import threading
import time
from collections import deque
from dataclasses import dataclass
from typing import Optional, Tuple, Union

import cv2
import numpy as np
import paho.mqtt.client as mqtt
import os
import resource
import psutil  # pip install psutil


SIG_SAFE = 0
SIG_TIRED = 1
SIG_SLEEPY = 2
SIG_SLEEP = 3
VALID_SIGNALS = {SIG_SAFE, SIG_TIRED, SIG_SLEEPY, SIG_SLEEP}

STATUS_TEXT = {
    SIG_SAFE: "ATTENTIVE",
    SIG_TIRED: "TIRED",
    SIG_SLEEPY: "SLEEPY",
    SIG_SLEEP: "MICROSLEEP",
}

# CRITICAL: split fine-grained locks to reduce contention under high FPS + MQTT bursts.
infer_lock = threading.Lock()
state_lock = threading.Lock()
mqtt_lock = threading.Lock()


def monotonic_ms() -> int:
    return int(time.monotonic_ns() // 1_000_000)


def clamp01(v: float) -> float:
    if v < 0.0:
        return 0.0
    if v > 1.0:
        return 1.0
    return float(v)


def clamp100(v: int) -> int:
    if v < 0:
        return 0
    if v > 100:
        return 100
    return int(v)
_rate_limit_cache = {}

def rate_limited_log(log, level: str, key: str, msg: str, interval_ms: int = 2000):
    now = monotonic_ms()
    last = _rate_limit_cache.get(key, 0)
    if (now - last) > interval_ms:
        _rate_limit_cache[key] = now
        getattr(log, level)(msg)

@dataclass(frozen=True)
class MqttConfig:
    broker: str = "127.0.0.1"
    port: int = 1883
    client_id: str = "rpi-drowsy-edge"
    username: Optional[str] = None
    password: Optional[str] = None
    keepalive_s: int = 10
    qos: int = 1
    retain: bool = True
    topic_status: str = "driver/status"
    topic_meta: str = "driver/status_meta"
    min_interval_ms: int = 100
    heartbeat_interval_ms: int = 300
    retry_base_ms: int = 250
    retry_max_ms: int = 5000
    ttl_ms: int = 3000
    demo_mode: bool = False


@dataclass(frozen=True)
class PipelineConfig:
    camera_source: Union[int, str] = 0
    frame_width: int = 320
    frame_height: int = 240
    camera_fps: int = 30
    camera_reopen_backoff_ms: int = 700
    # CRITICAL: stale frames above 200ms are discarded to remove perceptible jitter.
    stale_frame_ms: int = 200
    infer_interval_ms: int = 85
    infer_interval_min_ms: int = 60
    infer_interval_max_ms: int = 140
    window_size: int = 12
    sleep_ratio_threshold: float = 0.60
    sleepy_ratio_threshold: float = 0.52
    tired_ratio_threshold: float = 0.35
    sleepy_persist_ms: int = 3000
    recovery_fatigue_threshold: int = 30
    min_confidence_gate: float = 0.28
    render_every_n: int = 2


@dataclass
class InferencePacket:
    seq: int
    ts_ms: int
    capture_ts_ms: int
    infer_done_ts_ms: int
    raw: RawRisk


@dataclass
class FramePacket:
    frame: np.ndarray
    ts_ms: int


@dataclass
class RawRisk:
    p_safe: float
    p_tired: float
    p_sleepy: float
    p_sleep: float
    confidence: float
    fatigue_hint: int


@dataclass
class SmoothedRisk:
    signal: int
    fatigue: int
    confidence: float
    ratio_safe: float
    ratio_tired: float
    ratio_sleepy: float
    ratio_sleep: float


@dataclass
class PublishEvent:
    signal: int
    fatigue: int
    ts_ms: int
    capture_ts_ms: int
    infer_done_ts_ms: int
    bench: Optional[dict]


@dataclass
class Metrics:
    fps: float
    infer_ms_avg: float
    latency_avg: float


class FrameGrabber:
    """Capture worker keeping only latest frame to avoid queue latency."""

    def __init__(self, cfg: PipelineConfig, log: logging.Logger) -> None:
        self._cfg = cfg
        self._log = log
        self._stop = threading.Event()
        self._thread: Optional[threading.Thread] = None
        self._lock = threading.Lock()
        self._cap: Optional[cv2.VideoCapture] = None
        self._latest: Optional[FramePacket] = None
        self._last_open_try_ms = 0

        self._reopen_requested = False

        self._cap_count = 0
        self._cap_mark_ms = monotonic_ms()
        self._cap_fps = 0.0
    def request_reopen(self):
        with self._lock:
            self._reopen_requested = True

    def start(self) -> None:
        if self._thread and self._thread.is_alive():
            return
        self._stop.clear()
        self._thread = threading.Thread(target=self._run, name="camera-grabber", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        if self._thread:
            self._thread.join(timeout=1.5)
        self._close()

    def latest(self) -> Optional[FramePacket]:
        with self._lock:
            pkt = self._latest

        if pkt is None:
            return None

        # FIX: ensure safe ownership
        frame = pkt.frame
        if not frame.flags["OWNDATA"] or not frame.flags["C_CONTIGUOUS"]:
            frame = frame.copy()

        return FramePacket(frame=frame, ts_ms=pkt.ts_ms)

    def capture_fps(self) -> float:
        with self._lock:
            return self._cap_fps

    def _open(self) -> None:
        now = monotonic_ms()
        if (now - self._last_open_try_ms) < self._cfg.camera_reopen_backoff_ms:
            return
        self._last_open_try_ms = now

        cap = cv2.VideoCapture(self._cfg.camera_source)
        if not cap or not cap.isOpened():
            self._log.warning("Camera open failed source=%s", self._cfg.camera_source)
            if cap:
                cap.release()
            return

        cap.set(cv2.CAP_PROP_FRAME_WIDTH, self._cfg.frame_width)
        cap.set(cv2.CAP_PROP_FRAME_HEIGHT, self._cfg.frame_height)
        cap.set(cv2.CAP_PROP_FPS, self._cfg.camera_fps)
        try:
            cap.set(cv2.CAP_PROP_BUFFERSIZE, 1)
        except Exception:
            pass

        self._cap = cap
        self._log.info(
            "Camera opened source=%s size=%dx%d fps=%d",
            self._cfg.camera_source,
            self._cfg.frame_width,
            self._cfg.frame_height,
            self._cfg.camera_fps,
        )

    def _close(self) -> None:
        if self._cap is not None:
            self._cap.release()
            self._cap = None

    def _mark_fps(self, now_ms: int) -> None:
        self._cap_count += 1
        elapsed = now_ms - self._cap_mark_ms
        if elapsed < 1000:
            return
        fps = (self._cap_count * 1000.0) / max(1, elapsed)
        self._cap_count = 0
        self._cap_mark_ms = now_ms
        with self._lock:
            self._cap_fps = fps

    def _run(self) -> None:
        fail_count = 0
        while not self._stop.is_set():
            with self._lock:
                reopen_now = self._reopen_requested
                if reopen_now:
                    self._reopen_requested = False

            if reopen_now:
                self._log.warning("[CAM] forced reopen requested")
                self._close()
                time.sleep(0.1)
                continue

            if self._cap is None:
                self._open()
                if self._cap is None:
                    time.sleep(0.04)
                    continue

            ok, frame = self._cap.read()
            now = monotonic_ms()
            if not ok or frame is None:
                fail_count += 1
                if fail_count >= 4:
                    self._log.warning("Camera unstable -> reopen")
                    self._close()
                    fail_count = 0
                time.sleep(0.01)
                continue

            fail_count = 0
            safe_frame = frame
            # CRITICAL: never handoff non-owning frame buffers across threads.
            if not safe_frame.flags["OWNDATA"] or not safe_frame.flags["C_CONTIGUOUS"]:
                safe_frame = safe_frame.copy()
            with self._lock:
                self._latest = FramePacket(frame=safe_frame, ts_ms=now)
            self._mark_fps(now)


class BaseVisionEngine:
    def analyze(self, frame: np.ndarray, now_ms: int) -> RawRisk:
        raise NotImplementedError


class MediaPipeVisionEngine(BaseVisionEngine):
    """Face + attention based drowsiness inference using MediaPipe FaceMesh."""

    LEFT_EYE = (33, 160, 158, 133, 153, 144)
    RIGHT_EYE = (362, 385, 387, 263, 373, 380)
    NOSE = 1
    FOREHEAD = 10
    CHIN = 152
    LEFT_CHEEK = 234
    RIGHT_CHEEK = 454

    def __init__(self, log: logging.Logger) -> None:
        import mediapipe as mp  # Imported here to allow fallback if unavailable.

        self._log = log
        self._mesh = mp.solutions.face_mesh.FaceMesh(
            static_image_mode=False,
            max_num_faces=1,
            refine_landmarks=True,
            min_detection_confidence=0.5,
            min_tracking_confidence=0.5,
        )

        self._last_face_ms = 0
        self._eye_closed_since: Optional[int] = None
        self._away_since: Optional[int] = None

    @staticmethod
    def _dist(a: Tuple[float, float], b: Tuple[float, float]) -> float:
        dx = a[0] - b[0]
        dy = a[1] - b[1]
        return float((dx * dx + dy * dy) ** 0.5)

    def _ear(self, lm: list, idx: Tuple[int, int, int, int, int, int]) -> float:
        p1 = (lm[idx[0]].x, lm[idx[0]].y)
        p2 = (lm[idx[1]].x, lm[idx[1]].y)
        p3 = (lm[idx[2]].x, lm[idx[2]].y)
        p4 = (lm[idx[3]].x, lm[idx[3]].y)
        p5 = (lm[idx[4]].x, lm[idx[4]].y)
        p6 = (lm[idx[5]].x, lm[idx[5]].y)
        denom = max(1e-6, 2.0 * self._dist(p1, p4))
        return (self._dist(p2, p6) + self._dist(p3, p5)) / denom

    def _is_forward(self, lm: list) -> bool:
        nose = lm[self.NOSE]
        forehead = lm[self.FOREHEAD]
        chin = lm[self.CHIN]
        lcheek = lm[self.LEFT_CHEEK]
        rcheek = lm[self.RIGHT_CHEEK]

        face_w = max(1e-6, rcheek.x - lcheek.x)
        face_h = max(1e-6, chin.y - forehead.y)

        yaw = abs(((nose.x - lcheek.x) / face_w) - 0.5)
        pitch = abs(((nose.y - forehead.y) / face_h) - 0.52)

        return yaw < 0.20 and pitch < 0.22

    @staticmethod
    def _normalize_probs(ps: Tuple[float, float, float, float]) -> Tuple[float, float, float, float]:
        p_safe, p_tired, p_sleepy, p_sleep = ps
        p_safe = clamp01(p_safe)
        p_tired = clamp01(p_tired)
        p_sleepy = clamp01(p_sleepy)
        p_sleep = clamp01(p_sleep)
        s = max(1e-6, p_safe + p_tired + p_sleepy + p_sleep)
        return (p_safe / s, p_tired / s, p_sleepy / s, p_sleep / s)

    def analyze(self, frame: np.ndarray, now_ms: int) -> RawRisk:
        rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
        res = self._mesh.process(rgb)

        if not res.multi_face_landmarks:
            no_face_ms = 0 if self._last_face_ms == 0 else (now_ms - self._last_face_ms)
            if no_face_ms >= 3000:
                p = self._normalize_probs((0.05, 0.25, 0.70, 0.00))
                return RawRisk(*p, confidence=max(p), fatigue_hint=75)
            if no_face_ms >= 1200:
                p = self._normalize_probs((0.15, 0.60, 0.25, 0.00))
                return RawRisk(*p, confidence=max(p), fatigue_hint=50)
            p = self._normalize_probs((0.65, 0.25, 0.10, 0.00))
            return RawRisk(*p, confidence=max(p), fatigue_hint=20)

        lm = res.multi_face_landmarks[0].landmark
        self._last_face_ms = now_ms

        ear_l = self._ear(lm, self.LEFT_EYE)
        ear_r = self._ear(lm, self.RIGHT_EYE)
        ear = (ear_l + ear_r) / 2.0
        eye_closed = ear < 0.19

        if eye_closed:
            if self._eye_closed_since is None:
                self._eye_closed_since = now_ms
        else:
            self._eye_closed_since = None
        closed_ms = 0 if self._eye_closed_since is None else (now_ms - self._eye_closed_since)

        forward = self._is_forward(lm)
        if not forward:
            if self._away_since is None:
                self._away_since = now_ms
        else:
            self._away_since = None
        away_ms = 0 if self._away_since is None else (now_ms - self._away_since)

        fatigue_hint = clamp100(int((closed_ms / 35) + (away_ms / 120)))

        if closed_ms >= 1500:
            p = self._normalize_probs((0.01, 0.03, 0.06, 0.90))
            return RawRisk(*p, confidence=max(p), fatigue_hint=95)

        if closed_ms >= 500:
            p = self._normalize_probs((0.05, 0.15, 0.75, 0.05))
            return RawRisk(*p, confidence=max(p), fatigue_hint=max(70, fatigue_hint))

        if away_ms >= 2500:
            p = self._normalize_probs((0.05, 0.20, 0.72, 0.03))
            return RawRisk(*p, confidence=max(p), fatigue_hint=max(72, fatigue_hint))

        if away_ms >= 900:
            p = self._normalize_probs((0.15, 0.70, 0.12, 0.03))
            return RawRisk(*p, confidence=max(p), fatigue_hint=max(45, fatigue_hint))

        if ear < 0.23:
            p = self._normalize_probs((0.18, 0.62, 0.17, 0.03))
            return RawRisk(*p, confidence=max(p), fatigue_hint=max(40, fatigue_hint))

        p = self._normalize_probs((0.88, 0.08, 0.03, 0.01))
        return RawRisk(*p, confidence=max(p), fatigue_hint=min(25, fatigue_hint))


class HeuristicVisionEngine(BaseVisionEngine):
    """Fallback if MediaPipe is unavailable."""

    def analyze(self, frame: np.ndarray, now_ms: int) -> RawRisk:
        gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
        blur = float(cv2.Laplacian(gray, cv2.CV_32F).var())
        dark = float(np.mean(gray))

        p_sleep = clamp01((28.0 - min(28.0, blur)) / 28.0) * clamp01((70.0 - min(70.0, dark)) / 70.0)
        p_sleepy = clamp01((65.0 - min(65.0, blur)) / 65.0) * 0.75
        p_tired = clamp01((85.0 - min(85.0, blur)) / 85.0) * 0.6
        p_safe = clamp01(1.0 - max(p_sleep, p_sleepy, p_tired))

        s = max(1e-6, p_safe + p_tired + p_sleepy + p_sleep)
        p_safe, p_tired, p_sleepy, p_sleep = p_safe / s, p_tired / s, p_sleepy / s, p_sleep / s

        fatigue = clamp100(int((p_tired * 45) + (p_sleepy * 75) + (p_sleep * 100)))
        conf = max(p_safe, p_tired, p_sleepy, p_sleep)
        return RawRisk(p_safe=p_safe, p_tired=p_tired, p_sleepy=p_sleepy, p_sleep=p_sleep, confidence=conf, fatigue_hint=fatigue)


class SignalEmaSmoother:
    """Layer 1 smoothing: smooth raw vision signals (EAR/MAR-derived risk + fatigue)."""

    def __init__(self, alpha: float = 0.28) -> None:
        self._alpha = max(0.05, min(0.9, alpha))
        self._init = False
        self._p_safe = 1.0
        self._p_tired = 0.0
        self._p_sleepy = 0.0
        self._p_sleep = 0.0
        self._fatigue = 0.0

    def add(self, raw: RawRisk) -> RawRisk:
        if not self._init:
            self._p_safe = raw.p_safe
            self._p_tired = raw.p_tired
            self._p_sleepy = raw.p_sleepy
            self._p_sleep = raw.p_sleep
            self._fatigue = float(raw.fatigue_hint)
            self._init = True
        else:
            a = self._alpha
            self._p_safe += a * (raw.p_safe - self._p_safe)
            self._p_tired += a * (raw.p_tired - self._p_tired)
            self._p_sleepy += a * (raw.p_sleepy - self._p_sleepy)
            self._p_sleep += a * (raw.p_sleep - self._p_sleep)
            self._fatigue += a * (float(raw.fatigue_hint) - self._fatigue)

        s = max(1e-6, self._p_safe + self._p_tired + self._p_sleepy + self._p_sleep)
        ps = self._p_safe / s
        pt = self._p_tired / s
        py = self._p_sleepy / s
        pp = self._p_sleep / s
        conf = max(ps, pt, py, pp)

        return RawRisk(
            p_safe=ps,
            p_tired=pt,
            p_sleepy=py,
            p_sleep=pp,
            confidence=conf,
            fatigue_hint=clamp100(int(self._fatigue)),
        )


class TemporalSmoother:
    def __init__(self, cfg: PipelineConfig) -> None:
        self._cfg = cfg
        self._window: deque[RawRisk] = deque(maxlen=max(4, cfg.window_size))
        # FIX: fatigue hysteresis prevents threshold-edge flicker.
        self._tired_latched = False
        self._drowsy_latched = False
        self._very_tired_latched = False
        self._enter_tired = 58
        self._exit_tired = 48
        self._enter_drowsy = 80
        self._exit_drowsy = 70
        self._enter_very_tired = 90
        self._exit_very_tired = 82

    def add(self, raw: RawRisk) -> SmoothedRisk:
        self._window.append(raw)

        w_safe = 0.0
        w_tired = 0.0
        w_sleepy = 0.0
        w_sleep = 0.0
        hint_sum = 0.0
        total_w = 0.0

        for item in self._window:
            w = max(0.05, clamp01(item.confidence))
            total_w += w
            w_safe += item.p_safe * w
            w_tired += item.p_tired * w
            w_sleepy += item.p_sleepy * w
            w_sleep += item.p_sleep * w
            hint_sum += float(item.fatigue_hint)

        total_w = max(1e-6, total_w)
        ratio_safe = w_safe / total_w
        ratio_tired = w_tired / total_w
        ratio_sleepy = w_sleepy / total_w
        ratio_sleep = w_sleep / total_w

        ratio_fatigue = int((ratio_tired * 45.0) + (ratio_sleepy * 75.0) + (ratio_sleep * 100.0))
        hint_avg = int(hint_sum / max(1, len(self._window)))
        fatigue = clamp100(int((0.6 * ratio_fatigue) + (0.4 * hint_avg)))

        if fatigue >= self._enter_tired:
            self._tired_latched = True
        elif fatigue <= self._exit_tired:
            self._tired_latched = False

        if fatigue >= self._enter_drowsy:
            self._drowsy_latched = True
        elif fatigue <= self._exit_drowsy:
            self._drowsy_latched = False

        if fatigue >= self._enter_very_tired:
            self._very_tired_latched = True
        elif fatigue <= self._exit_very_tired:
            self._very_tired_latched = False

        if max(ratio_safe, ratio_tired, ratio_sleepy, ratio_sleep) < self._cfg.min_confidence_gate:
            signal = SIG_SAFE
        elif ratio_sleep >= self._cfg.sleep_ratio_threshold:
            signal = SIG_SLEEP
        elif ratio_sleepy >= self._cfg.sleepy_ratio_threshold or self._drowsy_latched or self._very_tired_latched:
            signal = SIG_SLEEPY
        elif ratio_tired >= self._cfg.tired_ratio_threshold or fatigue >= 45 or self._tired_latched:
            signal = SIG_TIRED
        else:
            signal = SIG_SAFE

        confidence = max(ratio_safe, ratio_tired, ratio_sleepy, ratio_sleep)
        return SmoothedRisk(
            signal=signal,
            fatigue=fatigue,
            confidence=clamp01(confidence),
            ratio_safe=ratio_safe,
            ratio_tired=ratio_tired,
            ratio_sleepy=ratio_sleepy,
            ratio_sleep=ratio_sleep,
        )


class StatePersistence:
    """
    Time rules:
      - microsleep (3) immediate
      - sleepy (2) requires >= sleepy_persist_ms (default 3s)
      - normal (0) reset immediate
    """

    def __init__(self, sleepy_persist_ms: int, recovery_fatigue_threshold: int, recovery_hold_ms: int = 300) -> None:
        self._sleepy_persist_ms = sleepy_persist_ms
        self._recovery_fatigue_threshold = recovery_fatigue_threshold
        self._recovery_hold_ms = max(0, int(recovery_hold_ms))
        self._sleepy_since_ms: Optional[int] = None
        self._recover_since_ms: Optional[int] = None
        self._last_output = SIG_SAFE

    def resolve(self, candidate_signal: int, fatigue: int, now_ms: int) -> int:
        if candidate_signal == SIG_SLEEP:
            self._sleepy_since_ms = None
            self._recover_since_ms = None
            self._last_output = SIG_SLEEP
            return self._last_output

        if candidate_signal == SIG_SAFE:
            # FIX: recovery hold (300ms) avoids DROWSY->NORMAL->DROWSY flicker.
            if fatigue <= self._recovery_fatigue_threshold:
                if self._recover_since_ms is None:
                    self._recover_since_ms = now_ms
                if (now_ms - self._recover_since_ms) >= self._recovery_hold_ms:
                    self._sleepy_since_ms = None
                    self._last_output = SIG_SAFE
                    return self._last_output
                return self._last_output
            self._recover_since_ms = None
            # If fatigue still high, downgrade progressively.
            self._sleepy_since_ms = None
            self._last_output = SIG_TIRED
            return self._last_output

        self._recover_since_ms = None

        if candidate_signal == SIG_SLEEPY:
            if self._sleepy_since_ms is None:
                self._sleepy_since_ms = now_ms
            if (now_ms - self._sleepy_since_ms) >= self._sleepy_persist_ms:
                self._sleepy_since_ms = None
                self._last_output = SIG_SLEEPY
                return self._last_output
            # Before persistence threshold, degrade to TIRED.
            self._last_output = SIG_TIRED
            return self._last_output

        self._sleepy_since_ms = None
        self._last_output = SIG_TIRED
        return self._last_output


class MqttPublisher:
    """Thread-safe non-spam publisher with reconnect backoff."""

    def __init__(self, cfg: MqttConfig, log: logging.Logger) -> None:
        self._cfg = cfg
        self._log = log
        self._lock = mqtt_lock

        try:
            self._client = mqtt.Client(
                callback_api_version=mqtt.CallbackAPIVersion.VERSION1,
                client_id=cfg.client_id,
                protocol=mqtt.MQTTv311,
            )
        except Exception:
            self._client = mqtt.Client(client_id=cfg.client_id, protocol=mqtt.MQTTv311)

        if cfg.username:
            self._client.username_pw_set(cfg.username, cfg.password)

        self._client.on_connect = self._on_connect
        self._client.on_disconnect = self._on_disconnect
        self._client.reconnect_delay_set(min_delay=1, max_delay=max(1, cfg.retry_max_ms // 1000))
        # FIX: cap inflight/queue to avoid burst overflow and publish lag.
        self._client.max_inflight_messages_set(5)
        self._client.max_queued_messages_set(20)

        self._running = False
        self._connected = False
        self._backoff_ms = cfg.retry_base_ms
        self._next_retry_ms = 0

        self._seq = 0
        self._last_publish_ms = 0
        self._last_sent: Optional[PublishEvent] = None
        self._pending: Optional[PublishEvent] = None
        self._worker_stop = threading.Event()
        self._worker_thread: Optional[threading.Thread] = None
        self._pub_count = 0
        self._pub_mark_ms = monotonic_ms()
        self._pub_rate_hz = 0.0

    def start(self) -> None:
        with self._lock:
            self._running = True
            self._backoff_ms = self._cfg.retry_base_ms
            self._next_retry_ms = 0
            self._worker_stop.clear()
        self._client.loop_start()
        self._connect_async()
        # CRITICAL: dedicated MQTT thread removes jitter from publish timing.
        self._worker_thread = threading.Thread(target=self._worker_loop, name="mqtt-publisher", daemon=True)
        self._worker_thread.start()

    def stop(self) -> None:
        with self._lock:
            self._running = False
        self._worker_stop.set()
        if self._worker_thread:
            self._worker_thread.join(timeout=1.0)
        try:
            self._client.disconnect()
        except Exception:
            pass
        self._client.loop_stop()

    def offer(self, signal_value: int, fatigue: int, ts_ms: Optional[int] = None) -> None:
        if signal_value not in VALID_SIGNALS:
            return
        base_ts = monotonic_ms() if ts_ms is None else int(ts_ms)
        event = PublishEvent(
            signal=signal_value,
            fatigue=clamp100(fatigue),
            ts_ms=base_ts,
            capture_ts_ms=base_ts,
            infer_done_ts_ms=base_ts,
            bench=None,
        )
        with self._lock:
            # FIX: suppress exact duplicates in pending/last state.
            if self._pending is not None and self._pending.signal == event.signal and self._pending.fatigue == event.fatigue:
                return
            if self._last_sent is not None and self._last_sent.signal == event.signal and self._last_sent.fatigue == event.fatigue:
                self._pending = event
                return
            self._pending = event

    def offer_with_latency(
        self,
        signal_value: int,
        fatigue: int,
        ts_ms: int,
        capture_ts_ms: int,
        infer_done_ts_ms: int,
        bench: Optional[dict],
    ) -> None:
        if signal_value not in VALID_SIGNALS:
            return
        event = PublishEvent(
            signal=signal_value,
            fatigue=clamp100(fatigue),
            ts_ms=int(ts_ms),
            capture_ts_ms=int(capture_ts_ms),
            infer_done_ts_ms=int(infer_done_ts_ms),
            bench=bench,
        )
        with self._lock:
            if self._pending is not None and self._pending.signal == event.signal and self._pending.fatigue == event.fatigue:
                self._pending = event
                return
            if self._last_sent is not None and self._last_sent.signal == event.signal and self._last_sent.fatigue == event.fatigue:
                self._pending = event
                return
            self._pending = event

    def publish_rate_hz(self) -> float:
        with self._lock:
            return self._pub_rate_hz

    def is_connected(self) -> bool:
        with self._lock:
            return self._connected

    def _mark_publish_rate_locked(self, now_ms: int) -> None:
        self._pub_count += 1
        elapsed = now_ms - self._pub_mark_ms
        if elapsed < 1000:
            return
        self._pub_rate_hz = (self._pub_count * 1000.0) / max(1, elapsed)
        self._pub_count = 0
        self._pub_mark_ms = now_ms

    def tick(self, now_ms: int) -> None:
        with self._lock:
            running = self._running
            connected = self._connected
        if not running:
            return
        if not connected:
            self._try_reconnect(now_ms)
            return
        self._publish_if_due(now_ms)

    def _worker_loop(self) -> None:
        while not self._worker_stop.is_set():
            self.tick(monotonic_ms())
            time.sleep(0.002)

    def _connect_async(self) -> None:
        try:
            self._client.connect_async(self._cfg.broker, self._cfg.port, self._cfg.keepalive_s)
            self._log.info("MQTT connect_async %s:%d", self._cfg.broker, self._cfg.port)
        except Exception as exc:
            self._log.warning("MQTT connect_async failed: %s", exc)
            with self._lock:
                self._connected = False
                self._next_retry_ms = monotonic_ms() + self._backoff_ms

    def _try_reconnect(self, now_ms: int) -> None:
        with self._lock:
            if now_ms < self._next_retry_ms:
                return
            self._next_retry_ms = now_ms + self._backoff_ms
            self._backoff_ms = min(self._backoff_ms * 2, self._cfg.retry_max_ms)
        try:
            self._client.reconnect()
        except Exception:
            pass

    def _on_connect(self, _client: mqtt.Client, _userdata: object, _flags: dict, rc: int) -> None:
        if rc == 0:
            with self._lock:
                self._connected = True
                self._backoff_ms = self._cfg.retry_base_ms
                self._next_retry_ms = 0
            self._log.info("MQTT connected")
            return
        with self._lock:
            self._connected = False
            self._next_retry_ms = monotonic_ms() + self._backoff_ms
        self._log.warning("MQTT connect rejected rc=%d", rc)

    def _on_disconnect(self, _client: mqtt.Client, _userdata: object, rc: int) -> None:
        with self._lock:
            self._connected = False
            self._next_retry_ms = monotonic_ms() + self._backoff_ms
            self._backoff_ms = min(self._backoff_ms * 2, self._cfg.retry_max_ms)
        self._log.warning("MQTT disconnected rc=%d", rc)

    def _next_seq_locked(self) -> int:
        self._seq += 1
        return self._seq

    def _publish_if_due(self, now_ms: int) -> None:
        event: Optional[PublishEvent] = None
        with self._lock:
            elapsed = now_ms - self._last_publish_ms
            min_ok = elapsed >= self._cfg.min_interval_ms
            # CRITICAL: fixed heartbeat interval = 300ms.
            heartbeat_due = elapsed >= self._cfg.heartbeat_interval_ms
            pending = self._pending
            last = self._last_sent
            changed = pending is not None and (last is None or pending.signal != last.signal)
            immediate_critical = changed and pending is not None and pending.signal == SIG_SLEEP

            if changed and (min_ok or immediate_critical):
                event = pending
                self._pending = None
            elif heartbeat_due and min_ok:
                if pending is not None:
                    event = PublishEvent(
                        signal=pending.signal,
                        fatigue=pending.fatigue,
                        ts_ms=monotonic_ms(),
                        capture_ts_ms=pending.capture_ts_ms,
                        infer_done_ts_ms=pending.infer_done_ts_ms,
                        bench=pending.bench,
                    )
                    self._pending = None
                elif last is not None:
                    event = PublishEvent(
                        signal=last.signal,
                        fatigue=last.fatigue,
                        ts_ms=monotonic_ms(),
                        capture_ts_ms=last.capture_ts_ms,
                        infer_done_ts_ms=last.infer_done_ts_ms,
                        bench=last.bench,
                    )

        if event is None:
            return

        status_payload = str(event.signal)
        publish_ts_ms = now_ms
        cap_to_infer = max(0, event.infer_done_ts_ms - event.capture_ts_ms)
        infer_to_publish = max(0, publish_ts_ms - event.infer_done_ts_ms)
        total_latency = max(0, cap_to_infer + infer_to_publish)
        with self._lock:
            seq = self._next_seq_locked()

        meta_payload = {
            "seq": int(seq),
            "ts_ms": int(event.capture_ts_ms),
            "publish_ts_ms": int(publish_ts_ms),
            "status": STATUS_TEXT[event.signal],
            "signal": int(event.signal),
            "fatigue": int(clamp100(event.fatigue)),
            "ttl_ms": int(self._cfg.ttl_ms),
            "latency": {
                "capture_to_infer": int(cap_to_infer),
                "infer_to_publish": int(infer_to_publish),
                "publish_to_esp32": -1,
                "esp32_to_alert": -1,
                "total": int(total_latency),
            },
        }
        if event.bench is not None:
            meta_payload["bench"] = event.bench

        if self._cfg.demo_mode and event.signal != SIG_SLEEP and random.random() < 0.12:
            with self._lock:
                self._pending = event
            return

        try:
            info_status = self._client.publish(
                self._cfg.topic_status,
                payload=status_payload,
                qos=self._cfg.qos,
                retain=self._cfg.retain,
            )
            info_meta = self._client.publish(
                self._cfg.topic_meta,
                payload=json.dumps(meta_payload, separators=(",", ":")),
                qos=self._cfg.qos,
                retain=self._cfg.retain,
            )
            if info_status.rc == mqtt.MQTT_ERR_SUCCESS and info_meta.rc == mqtt.MQTT_ERR_SUCCESS:
                with self._lock:
                    self._last_sent = event
                    self._last_publish_ms = now_ms
                    self._mark_publish_rate_locked(now_ms)
                self._log.debug("[MQTT] latency=%dms state=%s", total_latency, STATUS_TEXT[event.signal])
            else:
                with self._lock:
                    self._pending = event
        except Exception:
            with self._lock:
                self._pending = event


class RealtimePipeline:
    def __init__(
        self,
        p_cfg: PipelineConfig,
        m_cfg: MqttConfig,
        engine: BaseVisionEngine,
        log: logging.Logger,
        preview: bool = False,
        metrics_file: Optional[str] = None,
    ) -> None:
        self._cfg = p_cfg
        self._log = log
        self._camera = FrameGrabber(p_cfg, log)
        self._engine = engine
        # CRITICAL: layer 1 smoothing for raw signals (EAR/MAR/fatigue proxy).
        self._raw_smoother = SignalEmaSmoother(alpha=0.28)
        # CRITICAL: layer 2 smoothing for final state transitions.
        self._state_smoother = TemporalSmoother(p_cfg)
        self._persist = StatePersistence(p_cfg.sleepy_persist_ms, p_cfg.recovery_fatigue_threshold)
        self._mqtt = MqttPublisher(m_cfg, log)
        self._stop = threading.Event()

        self._infer_thread: Optional[threading.Thread] = None
        self._state_thread: Optional[threading.Thread] = None

        self._infer_interval_ms = p_cfg.infer_interval_ms
        self._infer_count = 0
        self._infer_mark_ms = monotonic_ms()
        self._infer_fps = 0.0

        # FIX: fine-grained lock for inference handoff only.
        self._infer_lock = infer_lock
        self._latest_infer: Optional[InferencePacket] = None
        self._infer_seq = 0

        # FIX: separate state lock for state machine/UI readback.
        self._state_lock = state_lock
        self._latest_state: Optional[SmoothedRisk] = None
        self._last_signal = SIG_SAFE
        self._last_frame_age_ms = 0
        self._last_infer_cost_ms = 0

        self._preview = preview
        self._demo_mode = bool(m_cfg.demo_mode)
        self._metrics_file = metrics_file
        self._render_counter = 0
        self._ui_color = np.array([50.0, 220.0, 50.0], dtype=np.float32)
        self._last_log_ms = 0
        self._last_metrics_dump_ms = 0
        self._frames_seen = 0
        self._dropped_frames = 0
        self._infer_cost_sum = 0.0
        self._infer_cost_count = 0
        self._infer_cost_min = 10**9
        self._infer_cost_max = 0
        self._latency_sum_ms = 0
        self._latency_count = 0
        self._confirmed_signal = SIG_SAFE
        self._confirm_candidate = SIG_SAFE
        self._confirm_since_ms = monotonic_ms()
        self._confirm_hold_ms = 180

        self._watchdog = threading.Thread(target=self._watchdog_loop, daemon=True)

    def start(self) -> None:
        self._camera.start()
        self._mqtt.start()
        self._stop.clear()

        self._infer_thread = threading.Thread(target=self._inference_loop, name="inference-thread", daemon=True)
        self._state_thread = threading.Thread(target=self._state_engine_loop, name="state-thread", daemon=True)
        self._infer_thread.start()
        self._state_thread.start()
        self._watchdog.start()
        self._log.info("Pipeline started")

    def stop(self) -> None:
        self._stop.set()
        if self._infer_thread:
            self._infer_thread.join(timeout=1.5)
        if self._state_thread:
            self._state_thread.join(timeout=1.5)
        self._mqtt.stop()
        self._camera.stop()
        if self._preview:
            try:
                cv2.destroyAllWindows()
            except Exception:
                pass
        self._log.info("Pipeline stopped")

    def request_stop(self) -> None:
        self._stop.set()

    def run_forever(self) -> None:
        self.start()
        try:
            while not self._stop.is_set():
                now = monotonic_ms()
                self._maybe_log(now)
                time.sleep(0.02)
        finally:
            self.stop()

    def _inference_loop(self) -> None:
        last_frame_ts = 0
        next_infer_ms = monotonic_ms()
        while not self._stop.is_set():
            now = monotonic_ms()
            packet = self._camera.latest()
            if packet is None:
                time.sleep(0.002)
                continue

            frame_age = now - packet.ts_ms
            if frame_age > self._cfg.stale_frame_ms:
                stale_streak = getattr(self, "_stale_streak", 0) + 1
                self._stale_streak = stale_streak

                if stale_streak % 10 == 0:
                    rate_limited_log(self._log, "warning", "stale_frame", f"[CAM] stale x{stale_streak} age={frame_age}ms")

                if stale_streak >= 15:
                    self._log.error("[CAM] forcing camera reopen")
                    self._camera.request_reopen()
                    self._stale_streak = 0

                with self._state_lock:
                    self._frames_seen += 1
                    self._dropped_frames += 1

                time.sleep(0.002)
                continue

            self._stale_streak = 0

            if packet.ts_ms == last_frame_ts:
                time.sleep(0.001)
                continue

            with self._state_lock:
                self._frames_seen += 1

            if now < next_infer_ms:
                time.sleep(0.001)
                continue

            infer_start = monotonic_ms()
            raw = self._safe_analyze(packet.frame, now)
            raw = self._raw_smoother.add(raw)
            infer_done_ms = monotonic_ms()
            infer_cost = infer_done_ms - infer_start

            # FIX: clamp inference cadence between 60..140ms.
            if infer_cost > 118:
                self._infer_interval_ms = min(self._cfg.infer_interval_max_ms, self._infer_interval_ms + 8)
            elif infer_cost < 74:
                self._infer_interval_ms = max(self._cfg.infer_interval_min_ms, self._infer_interval_ms - 3)
            self._infer_interval_ms = max(self._cfg.infer_interval_min_ms, min(self._cfg.infer_interval_max_ms, self._infer_interval_ms))
            next_infer_ms = now + self._infer_interval_ms
            last_frame_ts = packet.ts_ms

            with self._infer_lock:
                self._infer_seq += 1
                self._latest_infer = InferencePacket(
                    seq=self._infer_seq,
                    ts_ms=infer_done_ms,
                    capture_ts_ms=packet.ts_ms,
                    infer_done_ts_ms=infer_done_ms,
                    raw=raw,
                )

            self._mark_infer_rate(monotonic_ms())
            with self._state_lock:
                self._last_frame_age_ms = frame_age
                self._last_infer_cost_ms = infer_cost
                self._infer_cost_sum += float(infer_cost)
                self._infer_cost_count += 1
                if infer_cost < self._infer_cost_min:
                    self._infer_cost_min = infer_cost
                if infer_cost > self._infer_cost_max:
                    self._infer_cost_max = infer_cost

            if self._demo_mode and random.random() < 0.025:
                # IMPROVE: demo mode introduces mild jitter without blocking architecture.
                time.sleep(0.01)

    def _confirm_state(self, candidate_signal: int, now_ms: int) -> int:
        if candidate_signal == self._confirmed_signal:
            self._confirm_candidate = candidate_signal
            self._confirm_since_ms = now_ms
            return self._confirmed_signal
        if candidate_signal != self._confirm_candidate:
            self._confirm_candidate = candidate_signal
            self._confirm_since_ms = now_ms
            return self._confirmed_signal
        if (now_ms - self._confirm_since_ms) >= self._confirm_hold_ms:
            self._confirmed_signal = candidate_signal
        return self._confirmed_signal

    def _bench_snapshot(self, now_ms: int, fatigue: int) -> dict:
        with self._state_lock:
            infer_count = max(1, self._infer_cost_count)
            infer_avg = self._infer_cost_sum / infer_count
            infer_min = 0 if self._infer_cost_min == 10**9 else self._infer_cost_min
            infer_max = self._infer_cost_max
            frames_seen = max(1, self._frames_seen)
            dropped_pct = (self._dropped_frames * 100.0) / float(frames_seen)
            latency_avg = 0.0 if self._latency_count <= 0 else (self._latency_sum_ms / self._latency_count)
            signal_value = self._last_signal

        metric_roll = Metrics(
            fps=float(self._infer_fps),
            infer_ms_avg=float(infer_avg),
            latency_avg=float(latency_avg),
        )

        return {
            "capture_fps": round(self._camera.capture_fps(), 2),
            "infer_fps": round(metric_roll.fps, 2),
            "infer_ms_avg": round(metric_roll.infer_ms_avg, 2),
            "infer_ms_min": int(infer_min),
            "infer_ms_max": int(infer_max),
            "mqtt_pub_rate_hz": round(self._mqtt.publish_rate_hz(), 2),
            "dropped_frames_pct": round(dropped_pct, 2),
            "latency_avg_ms": round(metric_roll.latency_avg, 2),
            "state": STATUS_TEXT.get(signal_value, "ATTENTIVE"),
            "fatigue": int(fatigue),
            "mqtt_connected": bool(self._mqtt.is_connected()),
            "ts_ms": int(now_ms),
        }

    def _state_engine_loop(self) -> None:
        last_seq = 0
        while not self._stop.is_set():
            pkt: Optional[InferencePacket] = None
            with self._infer_lock:
                src = self._latest_infer
                if src is not None and src.seq != last_seq:
                    # CRITICAL: atomic snapshot copy under lock, used outside lock.
                    pkt = InferencePacket(
                        seq=src.seq,
                        ts_ms=src.ts_ms,
                        capture_ts_ms=src.capture_ts_ms,
                        infer_done_ts_ms=src.infer_done_ts_ms,
                        raw=RawRisk(
                            p_safe=src.raw.p_safe,
                            p_tired=src.raw.p_tired,
                            p_sleepy=src.raw.p_sleepy,
                            p_sleep=src.raw.p_sleep,
                            confidence=src.raw.confidence,
                            fatigue_hint=src.raw.fatigue_hint,
                        ),
                    )
            if pkt is None:
                time.sleep(0.002)
                continue

            last_seq = pkt.seq
            now = monotonic_ms()

            smooth = self._state_smoother.add(pkt.raw)
            final_signal = self._persist.resolve(smooth.signal, smooth.fatigue, now)

            if self._demo_mode:
                phase = (now // 1000) % 30
                if 8 <= phase < 10:
                    final_signal = SIG_SLEEP
                elif 10 <= phase < 14:
                    final_signal = SIG_SLEEPY

            final_signal = self._confirm_state(final_signal, now)

            # CRITICAL: explicit recovery latch clear to avoid stuck DROWSY/TIRED.
            if smooth.ratio_safe >= 0.72 and smooth.fatigue <= self._cfg.recovery_fatigue_threshold:
                final_signal = SIG_SAFE
                self._persist.resolve(SIG_SAFE, smooth.fatigue, now)

            total_latency = max(0, now - pkt.capture_ts_ms)
            if total_latency > self._cfg.stale_frame_ms:
                rate_limited_log(self._log, "warning", "latency_drop", f"[STATE] drop latency={total_latency}ms")
                continue
            with self._state_lock:
                self._latency_sum_ms += float(total_latency)
                self._latency_count += 1
            bench = self._bench_snapshot(now, smooth.fatigue)
            with self._state_lock:
                prev_sig = self._last_signal
            if prev_sig != final_signal:
                self._log.info("[STATE] transition=%s->%s fatigue=%d", STATUS_TEXT.get(prev_sig, "ATTENTIVE"), STATUS_TEXT.get(final_signal, "ATTENTIVE"), smooth.fatigue)

            self._mqtt.offer_with_latency(
                final_signal,
                smooth.fatigue,
                now,
                pkt.capture_ts_ms,
                pkt.infer_done_ts_ms,
                bench,
            )
            with self._state_lock:
                self._last_signal = final_signal
                self._latest_state = smooth

            if self._preview:
                self._render_counter += 1
                if (self._render_counter % max(1, self._cfg.render_every_n)) == 0:
                    self._render_preview(final_signal)
    def _watchdog_loop(self):
        while not self._stop.is_set():
            fps = self._camera.capture_fps()

            if fps < 5:
                rate_limited_log(self._log, "warning", "low_fps", "[WATCHDOG] low camera fps")
                self._camera.request_reopen()

            if not self._mqtt.is_connected():
                rate_limited_log(self._log, "warning", "mqtt_down", "[WATCHDOG] MQTT disconnected")

            process = psutil.Process(os.getpid())
            mem_mb = process.memory_info().rss / (1024 * 1024)

            if mem_mb > 500:
                rate_limited_log(self._log, "warning", "mem", f"[WATCHDOG] memory high {mem_mb:.1f}MB")

            time.sleep(2)

    def _safe_analyze(self, frame: np.ndarray, now_ms: int) -> RawRisk:
        try:
            return self._engine.analyze(frame, now_ms)
        except Exception as exc:
            self._log.exception("Vision analyze exception: %s", exc)
            return RawRisk(
                p_safe=1.0,
                p_tired=0.0,
                p_sleepy=0.0,
                p_sleep=0.0,
                confidence=0.0,
                fatigue_hint=0,
            )

    def _mark_infer_rate(self, now_ms: int) -> None:
        self._infer_count += 1
        elapsed = now_ms - self._infer_mark_ms
        if elapsed < 1000:
            return
        self._infer_fps = (self._infer_count * 1000.0) / max(1, elapsed)
        self._infer_count = 0
        self._infer_mark_ms = now_ms

    def _render_preview(self, signal_value: int) -> None:
        packet = self._camera.latest()
        if packet is None:
            return
        frame = packet.frame.copy()

        if signal_value == SIG_SLEEP:
            target = np.array([0.0, 0.0, 255.0], dtype=np.float32)
        elif signal_value == SIG_SLEEPY:
            target = np.array([0.0, 165.0, 255.0], dtype=np.float32)
        elif signal_value == SIG_TIRED:
            target = np.array([80.0, 200.0, 240.0], dtype=np.float32)
        else:
            target = np.array([60.0, 220.0, 80.0], dtype=np.float32)

        # IMPROVE: smooth UI color transitions (no abrupt flicker).
        self._ui_color += 0.24 * (target - self._ui_color)
        c = tuple(int(x) for x in self._ui_color)
        cv2.rectangle(frame, (0, 0), (frame.shape[1], 42), c, -1)
        cv2.putText(frame, STATUS_TEXT.get(signal_value, "ATTENTIVE"), (10, 28), cv2.FONT_HERSHEY_SIMPLEX, 0.75, (16, 16, 16), 2)
        cv2.imshow("Drowsy Preview", frame)
        cv2.waitKey(1)

    def _maybe_log(self, now_ms: int) -> None:
        if (now_ms - self._last_log_ms) < 1000:
            return
        self._last_log_ms = now_ms

        with self._state_lock:
            smooth = self._latest_state
            sig = self._last_signal
            frame_age_ms = self._last_frame_age_ms
            infer_cost_ms = self._last_infer_cost_ms

        if smooth is None:
            rate_limited_log(
                self._log,
                "info",
                "pipeline_log",
                f"[PIPELINE] sig={sig}({STATUS_TEXT.get(sig, 'ATTENTIVE')}) infer_fps={self._infer_fps:.1f} cap_fps={self._camera.capture_fps():.1f} frame_age={frame_age_ms}ms infer_cost={infer_cost_ms}ms interval={self._infer_interval_ms}ms pub_rate={self._mqtt.publish_rate_hz():.2f}"
            )
            return

        rate_limited_log(
            self._log,
            "info",
            "pipeline_log",
            f"[PIPELINE] sig={sig}({STATUS_TEXT.get(sig, 'ATTENTIVE')}) fatigue={smooth.fatigue} conf={smooth.confidence:.2f} safe={smooth.ratio_safe:.2f} tired={smooth.ratio_tired:.2f} sleepy={smooth.ratio_sleepy:.2f} sleep={smooth.ratio_sleep:.2f} infer_fps={self._infer_fps:.1f} cap_fps={self._camera.capture_fps():.1f} frame_age={frame_age_ms}ms infer_cost={infer_cost_ms}ms interval={self._infer_interval_ms}ms pub_rate={self._mqtt.publish_rate_hz():.2f}"
        )

        if self._metrics_file and (now_ms - self._last_metrics_dump_ms) >= 300:
            self._last_metrics_dump_ms = now_ms
            payload = self._bench_snapshot(now_ms, smooth.fatigue)
            payload["status"] = STATUS_TEXT.get(sig, "ATTENTIVE")
            payload["mqtt_connected"] = True
            try:
                with open(self._metrics_file, "w", encoding="utf-8") as f:
                    json.dump(payload, f, separators=(",", ":"))
            except Exception:
                pass


def parse_camera_source(raw: str) -> Union[int, str]:
    raw = str(raw).strip()
    try:
        return int(raw)
    except Exception:
        return raw


def build_engine(log: logging.Logger) -> BaseVisionEngine:
    try:
        engine = MediaPipeVisionEngine(log)
        log.info("Using MediaPipe vision engine")
        return engine
    except Exception as exc:
        log.warning("MediaPipe unavailable (%s), using heuristic fallback", exc)
        return HeuristicVisionEngine()


def build_logger(verbose: bool) -> logging.Logger:
    log = logging.getLogger("rpi-drowsy-pipeline")
    if not log.handlers:
        handler = logging.StreamHandler()
        handler.setFormatter(logging.Formatter("[%(asctime)s] %(levelname)s %(message)s"))
        log.addHandler(handler)
    log.setLevel(logging.DEBUG if verbose else logging.INFO)
    return log


def main() -> None:
    parser = argparse.ArgumentParser(description="Driver drowsiness realtime MQTT pipeline")
    parser.add_argument("--camera", default="0")
    parser.add_argument("--width", type=int, default=320)
    parser.add_argument("--height", type=int, default=240)
    parser.add_argument("--fps", type=int, default=30)

    parser.add_argument("--mqtt-host", default="127.0.0.1")
    parser.add_argument("--mqtt-port", type=int, default=1883)
    parser.add_argument("--mqtt-user", default=None)
    parser.add_argument("--mqtt-pass", default=None)
    parser.add_argument("--topic-status", default="driver/status")
    parser.add_argument("--topic-meta", default="driver/status_meta")
    parser.add_argument("--min-pub-ms", type=int, default=100)
    parser.add_argument("--ttl-ms", type=int, default=3000)

    parser.add_argument("--sleepy-ms", type=int, default=3000, help="Sleepy persistence ms")
    parser.add_argument("--preview", action="store_true", help="Show local preview window")
    parser.add_argument("--demo-mode", action="store_true", help="Enable demo instability + simulated events")
    parser.add_argument("--metrics-file", default="/tmp/drowsy_metrics.json")
    parser.add_argument("--dashboard", action="store_true", help="Run local dashboard server")
    parser.add_argument("--dashboard-port", type=int, default=8088)
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()

    log = build_logger(args.verbose)

    min_pub = max(100, int(args.min_pub_ms))
    ttl_ms = max(1200, int(args.ttl_ms))
    sleepy_ms = max(3000, int(args.sleepy_ms))

    p_cfg = PipelineConfig(
        camera_source=parse_camera_source(args.camera),
        frame_width=int(args.width),
        frame_height=int(args.height),
        camera_fps=int(args.fps),
        sleepy_persist_ms=sleepy_ms,
    )
    m_cfg = MqttConfig(
        broker=args.mqtt_host,
        port=int(args.mqtt_port),
        username=args.mqtt_user,
        password=args.mqtt_pass,
        topic_status=args.topic_status,
        topic_meta=args.topic_meta,
        min_interval_ms=min_pub,
        heartbeat_interval_ms=300,
        ttl_ms=ttl_ms,
        demo_mode=bool(args.demo_mode),
    )

    engine = build_engine(log)
    pipeline = RealtimePipeline(
        p_cfg,
        m_cfg,
        engine,
        log,
        preview=args.preview,
        metrics_file=args.metrics_file,
    )

    if args.dashboard:
        try:
            from realtime_dashboard import start_dashboard_server

            start_dashboard_server(
                metrics_file=args.metrics_file,
                mqtt_host=args.mqtt_host,
                mqtt_port=int(args.mqtt_port),
                dashboard_port=int(args.dashboard_port),
                log=log,
            )
        except Exception as exc:
            log.warning("Dashboard disabled: %s", exc)

    def _handle_signal(_sig: int, _frame: object) -> None:
        log.info("Shutdown signal received")
        pipeline.request_stop()

    signal.signal(signal.SIGINT, _handle_signal)
    signal.signal(signal.SIGTERM, _handle_signal)

    pipeline.run_forever()


def run_with_restart():
    while True:
        try:
            main()
        except Exception as e:
            print("[FATAL] restarting:", e)
            time.sleep(2)

if __name__ == "__main__":
    run_with_restart()
