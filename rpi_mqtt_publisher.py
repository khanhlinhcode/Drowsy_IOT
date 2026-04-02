"""Production MQTT publisher for Raspberry Pi drowsiness AI pipelines.

Message format:
    {
      "state": "sleep|sleepy|normal",
      "confidence": 0.0..1.0,
      "time": <epoch_ms>
    }

Integration example:
    from rpi_mqtt_publisher import DrowsyMqttPublisher, MqttConfig, map_detector_label_to_state

    publisher = DrowsyMqttPublisher(
        MqttConfig(
            broker="192.168.0.163",
            port=1883,
            topic="drowsy/status",
            qos=1,
            retain=True,
            min_publish_interval_ms=1000,
            enable_debug_logs=True,
        )
    )
    publisher.start()

    # In your inference loop:
    state = map_detector_label_to_state(detector_status)
    publisher.publish_state(state=state, confidence=confidence_score)

    # On shutdown:
    publisher.stop()
"""

from __future__ import annotations

import json
import logging
import threading
import time
from dataclasses import dataclass
from typing import Optional

import paho.mqtt.client as mqtt

VALID_STATES = {"sleep", "sleepy", "normal"}


@dataclass(frozen=True)
class MqttConfig:
    broker: str = "127.0.0.1"
    port: int = 1883
    topic: str = "drowsy/status"
    client_id: str = "rpi-drowsy-edge"
    keepalive_s: int = 30
    qos: int = 1
    retain: bool = True
    min_publish_interval_ms: int = 1000
    username: Optional[str] = None
    password: Optional[str] = None
    tls_enabled: bool = False
    tls_ca_cert: Optional[str] = None
    tls_certfile: Optional[str] = None
    tls_keyfile: Optional[str] = None
    tls_insecure: bool = False
    min_retry_ms: int = 500
    max_retry_ms: int = 30_000
    enable_debug_logs: bool = True


class DrowsyMqttPublisher:
    """Thread-safe state publisher with dedup, debounce, buffering, and reconnect."""

    def __init__(self, config: MqttConfig) -> None:
        self._config = config
        self._lock = threading.Lock()

        self._logger = logging.getLogger("rpi_mqtt_publisher")
        if not self._logger.handlers:
            handler = logging.StreamHandler()
            handler.setFormatter(
                logging.Formatter("[%(asctime)s] %(levelname)s %(message)s")
            )
            self._logger.addHandler(handler)
        self._logger.setLevel(logging.DEBUG if config.enable_debug_logs else logging.INFO)

        # paho-mqtt >=2 recommends explicitly selecting callback API version.
        try:
            self._client = mqtt.Client(
                callback_api_version=mqtt.CallbackAPIVersion.VERSION1,
                client_id=config.client_id,
                protocol=mqtt.MQTTv311,
            )
        except (AttributeError, TypeError):
            # Backward compatibility with paho-mqtt <2.
            self._client = mqtt.Client(
                client_id=config.client_id,
                protocol=mqtt.MQTTv311,
            )
        if config.username:
            self._client.username_pw_set(config.username, config.password)

        if config.tls_enabled:
            self._client.tls_set(
                ca_certs=config.tls_ca_cert,
                certfile=config.tls_certfile,
                keyfile=config.tls_keyfile,
            )
            self._client.tls_insecure_set(config.tls_insecure)

        self._client.on_connect = self._on_connect
        self._client.on_disconnect = self._on_disconnect
        self._client.on_publish = self._on_publish
        self._client.reconnect_delay_set(
            min_delay=max(1, config.min_retry_ms // 1000),
            max_delay=max(1, config.max_retry_ms // 1000),
        )
        self._client.max_inflight_messages_set(20)
        self._client.max_queued_messages_set(200)

        self._running = False
        self._connected = False

        self._last_published_state: Optional[str] = None
        self._last_publish_ts_ms = 0

        self._pending_payload: Optional[str] = None
        self._pending_state: Optional[str] = None

        self._retry_ms = config.min_retry_ms
        self._next_retry_ts_ms = 0
        self._worker: Optional[threading.Thread] = None

    def start(self) -> None:
        with self._lock:
            if self._running:
                return
            self._running = True
            self._retry_ms = self._config.min_retry_ms
            self._next_retry_ts_ms = 0

        self._logger.info(
            "Starting MQTT publisher broker=%s port=%s topic=%s",
            self._config.broker,
            self._config.port,
            self._config.topic,
        )

        self._client.loop_start()
        self._connect_async()

        self._worker = threading.Thread(
            target=self._worker_loop,
            name="mqtt-reconnect-worker",
            daemon=True,
        )
        self._worker.start()

    def stop(self) -> None:
        with self._lock:
            if not self._running:
                return
            self._running = False

        self._logger.info("Stopping MQTT publisher")

        if self._worker is not None:
            self._worker.join(timeout=1.0)

        try:
            self._client.disconnect()
        except Exception:
            pass

        self._client.loop_stop()

    def publish_state(
        self,
        state: str,
        confidence: float,
        timestamp_ms: Optional[int] = None,
        force: bool = False,
    ) -> bool:
        """Queue/publish a state update.

        Returns True when immediately accepted by MQTT client publish queue.
        Returns False when deduped/debounced/offline-buffered.
        """
        normalized_state = _normalize_state(state)
        if normalized_state not in VALID_STATES:
            raise ValueError(f"Unsupported state: {state!r}")

        confidence_value = _clamp_confidence(confidence)
        ts_ms = timestamp_ms if timestamp_ms is not None else int(time.time() * 1000)

        payload = json.dumps(
            {
                "state": normalized_state,
                "confidence": confidence_value,
                "time": ts_ms,
            },
            separators=(",", ":"),
            ensure_ascii=False,
        )

        now_ms = int(time.time() * 1000)
        with self._lock:
            duplicate = (
                not force
                and (
                    normalized_state == self._last_published_state
                    or normalized_state == self._pending_state
                )
            )
            within_debounce = (
                (now_ms - self._last_publish_ts_ms)
                < self._config.min_publish_interval_ms
            )
            connected = self._connected

        if duplicate:
            self._logger.debug("Skip duplicate state=%s", normalized_state)
            return False

        if within_debounce:
            self._logger.debug(
                "Debounced state=%s, buffering latest payload",
                normalized_state,
            )
            self._buffer_pending(payload, normalized_state)
            return False

        if connected and self._publish_payload(payload, normalized_state, now_ms):
            return True

        self._logger.debug("Offline or publish failed, buffering state=%s", normalized_state)
        self._buffer_pending(payload, normalized_state)
        return False

    def _buffer_pending(self, payload: str, state: str) -> None:
        with self._lock:
            self._pending_payload = payload
            self._pending_state = state
            self._schedule_retry_locked(int(time.time() * 1000))

    def _on_connect(self, _client: mqtt.Client, _userdata: object, _flags: dict, rc: int) -> None:
        if rc != 0:
            self._logger.warning("MQTT connect rejected rc=%s", rc)
            with self._lock:
                self._connected = False
                self._schedule_retry_locked(int(time.time() * 1000))
            return

        self._logger.info("MQTT connected")
        with self._lock:
            self._connected = True
            self._retry_ms = self._config.min_retry_ms
            self._next_retry_ts_ms = 0

    def _on_disconnect(self, _client: mqtt.Client, _userdata: object, rc: int) -> None:
        self._logger.warning("MQTT disconnected rc=%s", rc)
        with self._lock:
            self._connected = False
            if self._running:
                self._schedule_retry_locked(int(time.time() * 1000))

    def _on_publish(self, _client: mqtt.Client, _userdata: object, mid: int) -> None:
        self._logger.debug("MQTT publish acknowledged mid=%s", mid)

    def _publish_payload(self, payload: str, state: str, now_ms: int) -> bool:
        try:
            info = self._client.publish(
                topic=self._config.topic,
                payload=payload,
                qos=self._config.qos,
                retain=self._config.retain,
            )
            if info.rc == mqtt.MQTT_ERR_SUCCESS:
                with self._lock:
                    self._last_published_state = state
                    self._last_publish_ts_ms = now_ms
                self._logger.debug("Published state=%s payload=%s", state, payload)
                return True

            self._logger.warning("MQTT publish rc=%s", info.rc)
        except Exception as exc:
            self._logger.exception("MQTT publish exception: %s", exc)

        with self._lock:
            self._connected = False
        return False

    def _connect_async(self) -> None:
        try:
            self._client.connect_async(
                host=self._config.broker,
                port=self._config.port,
                keepalive=self._config.keepalive_s,
            )
        except Exception as exc:
            self._logger.exception("connect_async failed: %s", exc)
            with self._lock:
                self._schedule_retry_locked(int(time.time() * 1000))

    def _worker_loop(self) -> None:
        while True:
            with self._lock:
                running = self._running
                connected = self._connected
                next_retry_ts_ms = self._next_retry_ts_ms
                pending_payload = self._pending_payload
                pending_state = self._pending_state
                last_publish_ts_ms = self._last_publish_ts_ms

            if not running:
                return

            now_ms = int(time.time() * 1000)

            if not connected and next_retry_ts_ms != 0 and now_ms >= next_retry_ts_ms:
                self._try_reconnect(now_ms)

            if connected and pending_payload and pending_state:
                if (now_ms - last_publish_ts_ms) >= self._config.min_publish_interval_ms:
                    ok = self._publish_payload(pending_payload, pending_state, now_ms)
                    if ok:
                        with self._lock:
                            # Clear only if this is still the latest buffered payload.
                            if self._pending_payload == pending_payload:
                                self._pending_payload = None
                                self._pending_state = None

            time.sleep(0.2)

    def _try_reconnect(self, now_ms: int) -> None:
        try:
            rc = self._client.reconnect()
            if rc == mqtt.MQTT_ERR_SUCCESS:
                self._logger.info("MQTT reconnect attempted")
                with self._lock:
                    self._next_retry_ts_ms = 0
                    self._retry_ms = self._config.min_retry_ms
            else:
                self._logger.warning("MQTT reconnect rc=%s", rc)
                with self._lock:
                    self._schedule_retry_locked(now_ms)
        except Exception as exc:
            self._logger.exception("MQTT reconnect exception: %s", exc)
            with self._lock:
                self._schedule_retry_locked(now_ms)

    def _schedule_retry_locked(self, now_ms: int) -> None:
        if self._next_retry_ts_ms != 0 and now_ms < self._next_retry_ts_ms:
            return

        self._next_retry_ts_ms = now_ms + self._retry_ms
        self._retry_ms = min(self._retry_ms * 2, self._config.max_retry_ms)
        self._logger.debug(
            "Next reconnect in %sms (next retry=%s)",
            self._next_retry_ts_ms - now_ms,
            self._next_retry_ts_ms,
        )


def _normalize_state(state: str) -> str:
    return state.strip().lower()


def _clamp_confidence(confidence: float) -> float:
    value = float(confidence)
    if value < 0:
        return 0.0
    if value > 1:
        return 1.0
    return value


def map_detector_label_to_state(detector_label: str) -> str:
    """Map arbitrary model labels into app states: sleep|sleepy|normal."""
    normalized = detector_label.strip().upper()

    if normalized in {"SLEEP", "MICROSLEEP", "DROWSY"}:
        return "sleep"
    if normalized in {"SLEEPY", "VERY TIRED", "TIRED"}:
        return "sleepy"
    return "normal"
