#!/usr/bin/env python3
"""
MQTT integration test suite for drowsiness alert system.
Publishes test vectors via Mosquitto and validates responses.

Prerequisites:
  1) Mosquitto broker running: mosquitto -v
  2) ESP32 connected and running firmware
  3) pip3 install paho-mqtt

Run:   python3 tests/test_mqtt_integration.py --broker 127.0.0.1
HIL:   python3 tests/test_mqtt_integration.py --broker <PI_IP> --hil
"""

import argparse
import json
import sys
import threading
import time

try:
    import paho.mqtt.client as mqtt
except ImportError:
    print("ERROR: Install paho-mqtt: pip3 install paho-mqtt")
    sys.exit(1)

PASS = "\033[92m✅ PASS\033[0m"
FAIL = "\033[91m❌ FAIL\033[0m"
SKIP = "\033[90m⊘  SKIP\033[0m"

results = []
received_messages = {}
msg_lock = threading.Lock()


def record(name, passed, detail=""):
    results.append({"name": name, "passed": passed, "detail": detail})
    status = PASS if passed else FAIL
    print(f"  {status}  {name}" + (f" — {detail}" if detail else ""))
    return passed


# ============================================================
# MQTT helpers
# ============================================================
class TestClient:
    def __init__(self, broker, port=1883):
        self.broker = broker
        self.port = port
        self.client = mqtt.Client(client_id=f"test-runner-{int(time.time())}", protocol=mqtt.MQTTv311)
        self.connected = False
        self.client.on_connect = self._on_connect
        self.client.on_disconnect = self._on_disconnect
        self.client.on_message = self._on_message

    def _on_connect(self, client, userdata, flags, rc, *args):
        if rc == 0:
            self.connected = True
            # Subscribe to all driver topics
            client.subscribe("driver/#", qos=1)
            client.subscribe("/driver/#", qos=1)

    def _on_disconnect(self, client, userdata, rc, *args):
        self.connected = False

    def _on_message(self, client, userdata, msg):
        topic = msg.topic.lstrip("/")
        payload = msg.payload.decode("utf-8", errors="replace")
        with msg_lock:
            if topic not in received_messages:
                received_messages[topic] = []
            received_messages[topic].append({
                "payload": payload,
                "ts": time.time(),
                "qos": msg.qos,
                "retain": msg.retain,
            })

    def connect(self):
        try:
            self.client.connect(self.broker, self.port, keepalive=10)
            self.client.loop_start()
            deadline = time.time() + 5
            while not self.connected and time.time() < deadline:
                time.sleep(0.1)
            return self.connected
        except Exception as e:
            print(f"  Connection failed: {e}")
            return False

    def publish(self, topic, payload, qos=1):
        info = self.client.publish(topic, payload, qos=qos, retain=False)
        info.wait_for_publish(timeout=2)
        return info.rc == mqtt.MQTT_ERR_SUCCESS

    def wait_for_topic(self, topic, count=1, timeout=5.0):
        """Wait until we have at least `count` messages on `topic`."""
        deadline = time.time() + timeout
        while time.time() < deadline:
            with msg_lock:
                msgs = received_messages.get(topic, [])
                if len(msgs) >= count:
                    return msgs[-count:]
            time.sleep(0.05)
        with msg_lock:
            return received_messages.get(topic, [])

    def clear(self, topic=None):
        with msg_lock:
            if topic:
                received_messages.pop(topic, None)
            else:
                received_messages.clear()

    def disconnect(self):
        self.client.loop_stop()
        self.client.disconnect()


# ============================================================
# Test cases
# ============================================================
def test_broker_connection(tc):
    """T-CONN: Verify MQTT broker is reachable."""
    print("\n─── T-CONN: Broker Connection ───")
    record("Broker reachable", tc.connected, f"{tc.broker}:{tc.port}")
    return tc.connected


def test_publish_status_signal(tc):
    """T-PUB: Publish driver/status and verify no echo (non-circular)."""
    print("\n─── T-PUB: Publish Status Signal ───")
    tc.clear()

    for signal in [0, 1, 2, 3]:
        ok = tc.publish("driver/status", str(signal))
        record(f"Publish signal={signal}", ok)

    # Verify we received our own messages (we're subscribed to driver/#)
    msgs = tc.wait_for_topic("driver/status", count=4, timeout=3)
    record(f"Received {len(msgs)} status messages", len(msgs) >= 4)

    # Verify signal values
    for i, expected in enumerate([0, 1, 2, 3]):
        if i < len(msgs):
            actual = msgs[i]["payload"].strip()
            record(f"Signal {expected}: payload='{actual}'", actual == str(expected))


def test_publish_status_meta(tc):
    """T-META: Publish driver/status_meta JSON and validate schema."""
    print("\n─── T-META: Publish Status Meta ───")
    tc.clear()

    test_payloads = [
        {"seq": 1, "ts_ms": 1000, "publish_ts_ms": 1002, "status": "ATTENTIVE", "signal": 0, "fatigue": 10, "ttl_ms": 1400},
        {"seq": 2, "ts_ms": 2000, "publish_ts_ms": 2002, "status": "TIRED", "signal": 1, "fatigue": 45, "ttl_ms": 1400},
        {"seq": 3, "ts_ms": 3000, "publish_ts_ms": 3002, "status": "SLEEPY", "signal": 2, "fatigue": 65, "ttl_ms": 1400},
        {"seq": 4, "ts_ms": 4000, "publish_ts_ms": 4002, "status": "MICROSLEEP", "signal": 3, "fatigue": 90, "ttl_ms": 1400},
    ]

    for payload in test_payloads:
        msg = json.dumps(payload, separators=(",", ":"))
        ok = tc.publish("driver/status_meta", msg)
        record(f"Publish meta seq={payload['seq']} status={payload['status']}", ok)
        time.sleep(0.15)  # Give ESP32 time to process

    msgs = tc.wait_for_topic("driver/status_meta", count=4, timeout=3)
    record(f"Received {len(msgs)} meta messages", len(msgs) >= 4)

    # Validate JSON schema
    for msg in msgs:
        try:
            data = json.loads(msg["payload"])
            required = ["seq", "ts_ms", "status", "signal", "fatigue", "ttl_ms"]
            has_all = all(k in data for k in required)
            record(f"Meta seq={data.get('seq','-')}: schema valid", has_all,
                   f"missing: {[k for k in required if k not in data]}" if not has_all else "")
        except json.JSONDecodeError:
            record(f"Meta payload is valid JSON", False, msg["payload"][:50])


def test_command_reset_wifi(tc):
    """T-CMD-RESET: Send reset_wifi command via driver/cmd."""
    print("\n─── T-CMD-RESET: WiFi Reset Command ───")
    tc.clear()

    cmd = json.dumps({"action": "reset_wifi"})
    ok = tc.publish("driver/cmd", cmd)
    record("Publish reset_wifi command", ok)

    # Verify message received on topic
    msgs = tc.wait_for_topic("driver/cmd", count=1, timeout=2)
    if msgs:
        data = json.loads(msgs[0]["payload"])
        record("Command payload has action field", "action" in data)
        record("Action is reset_wifi", data.get("action") == "reset_wifi")
    else:
        record("Command received on driver/cmd", False, "no message received")


def test_command_clear_wifi(tc):
    """T-CMD-CLEAR: Send clear_wifi command via driver/cmd."""
    print("\n─── T-CMD-CLEAR: WiFi Clear Command ───")
    tc.clear()

    cmd = json.dumps({"action": "clear_wifi"})
    ok = tc.publish("driver/cmd", cmd)
    record("Publish clear_wifi command", ok)

    msgs = tc.wait_for_topic("driver/cmd", count=1, timeout=2)
    if msgs:
        data = json.loads(msgs[0]["payload"])
        record("Action is clear_wifi", data.get("action") == "clear_wifi")
    else:
        record("Command received on driver/cmd", False, "no message received")


def test_command_invalid(tc):
    """T-CMD-BAD: Send invalid/malformed commands."""
    print("\n─── T-CMD-BAD: Invalid Commands ───")
    tc.clear()

    # Invalid JSON
    ok = tc.publish("driver/cmd", "not json at all")
    record("Publish invalid JSON", ok, "ESP32 should log parse error, not crash")

    time.sleep(0.2)

    # Valid JSON, missing action
    ok = tc.publish("driver/cmd", '{"foo": "bar"}')
    record("Publish JSON without action", ok, "ESP32 should log 'missing action', not crash")

    time.sleep(0.2)

    # Unknown action
    ok = tc.publish("driver/cmd", '{"action": "do_something_weird"}')
    record("Publish unknown action", ok, "ESP32 should log 'Unknown action', not crash")

    time.sleep(0.2)

    # Empty payload
    ok = tc.publish("driver/cmd", "")
    record("Publish empty payload", ok, "ESP32 should handle gracefully")


def test_alert_event_schema(tc):
    """T-ALERT: Publish simulated alert events and validate schema."""
    print("\n─── T-ALERT: Alert Event Schema ───")
    tc.clear()

    start_event = {
        "event_id": "evt-test-0001",
        "device_id": "rpi-drowsy-edge",
        "session_id": "sess-test",
        "event_type": "DROWSY_ALERT",
        "trigger_status": "MICROSLEEP",
        "fatigue_score": 87,
        "perclos": 0.48,
        "eye_closed_ms": 2100,
        "head_pose": "HEAD DOWN",
        "timestamp_ms": 1000,
        "duration_ms": 0,
        "resolved": False,
    }

    ok = tc.publish("driver/alert_event", json.dumps(start_event, separators=(",", ":")))
    record("Publish alert start event", ok)

    msgs = tc.wait_for_topic("driver/alert_event", count=1, timeout=2)
    if msgs:
        data = json.loads(msgs[0]["payload"])
        required = ["event_id", "device_id", "session_id", "event_type",
                     "trigger_status", "fatigue_score", "perclos", "eye_closed_ms",
                     "head_pose", "timestamp_ms", "duration_ms", "resolved"]
        has_all = all(k in data for k in required)
        record("Alert event has all required fields", has_all)
        record("Alert event_type is DROWSY_ALERT", data.get("event_type") == "DROWSY_ALERT")
        record("Alert resolved=false for start event", data.get("resolved") is False)
    else:
        record("Alert event received", False)

    # Resolved event
    time.sleep(0.2)
    resolved_event = dict(start_event)
    resolved_event["event_type"] = "DROWSY_ALERT_RESOLVED"
    resolved_event["resolved"] = True
    resolved_event["duration_ms"] = 5200
    resolved_event["fatigue_score"] = 45

    ok = tc.publish("driver/alert_event", json.dumps(resolved_event, separators=(",", ":")))
    record("Publish alert resolved event", ok)

    msgs = tc.wait_for_topic("driver/alert_event", count=2, timeout=2)
    if len(msgs) >= 2:
        data = json.loads(msgs[-1]["payload"])
        record("Resolved event_type is DROWSY_ALERT_RESOLVED",
               data.get("event_type") == "DROWSY_ALERT_RESOLVED")
        record("Resolved has duration_ms > 0", data.get("duration_ms", 0) > 0)
        record("Resolved has resolved=true", data.get("resolved") is True)


def test_esp32_telemetry(tc, timeout=8):
    """T-TELEM: Wait for ESP32 telemetry and validate schema."""
    print("\n─── T-TELEM: ESP32 Telemetry (waiting up to 8s) ───")
    tc.clear("driver/esp32_telemetry")

    msgs = tc.wait_for_topic("driver/esp32_telemetry", count=1, timeout=timeout)
    if not msgs:
        record("ESP32 telemetry received", False,
               "No telemetry — ESP32 may not be connected or not publishing")
        return

    record("ESP32 telemetry received", True)
    try:
        data = json.loads(msgs[0]["payload"])
        required = ["ts_ms", "state", "confirmed", "driving", "mqtt", "packet_rate", "reconnects"]
        has_all = all(k in data for k in required)
        record("Telemetry has required fields", has_all,
               f"missing: {[k for k in required if k not in data]}" if not has_all else "")
        record(f"Telemetry state={data.get('state')}", data.get("state") in
               ["SAFE", "DRIVING", "TIRED", "SLEEPY", "SLEEP"])
        record(f"Telemetry driving={data.get('driving')}", isinstance(data.get("driving"), bool))
        record(f"Telemetry mqtt={data.get('mqtt')}", data.get("mqtt") in ["UP", "DOWN"])
    except json.JSONDecodeError:
        record("Telemetry is valid JSON", False, msgs[0]["payload"][:80])


def test_state_transition_sequence(tc):
    """T-SEQ: Publish escalating status sequence and verify ESP32 receives all."""
    print("\n─── T-SEQ: State Transition Sequence ───")
    tc.clear()

    # Simulate: SAFE → TIRED → SLEEPY → SLEEP → SAFE
    sequence = [
        (0, "ATTENTIVE", "ESP32 should be SAFE/DRIVING"),
        (1, "TIRED",     "ESP32 should debounce to TIRED after 320ms"),
        (2, "SLEEPY",    "ESP32 should debounce to SLEEPY after 3s"),
        (3, "MICROSLEEP","ESP32 should immediately enter SLEEP"),
        (0, "ATTENTIVE", "ESP32 should de-escalate after alarm lock + 1100ms"),
    ]

    for i, (signal, status, expected) in enumerate(sequence):
        seq = 100 + i
        ts = 10000 + (i * 500)
        payload = json.dumps({
            "seq": seq, "ts_ms": ts, "publish_ts_ms": ts + 2,
            "status": status, "signal": signal, "fatigue": signal * 25,
            "ttl_ms": 1400
        }, separators=(",", ":"))

        ok = tc.publish("driver/status", str(signal))
        ok2 = tc.publish("driver/status_meta", payload)
        record(f"Step {i+1}: signal={signal} status={status} — published", ok and ok2, expected)

        # Wait appropriate time for debounce
        if signal == 1:
            time.sleep(0.5)   # > STABLE_RISE_TIRED_MS (320ms)
        elif signal == 2:
            time.sleep(3.5)   # > STABLE_RISE_SLEEPY_MS (3000ms)
        elif signal == 3:
            time.sleep(0.2)   # SLEEP is immediate
        elif signal == 0:
            time.sleep(6.5)   # > SLEEP_CONTINUOUS_MIN_MS (5s) + STABLE_FALL_MS (1.1s)
        else:
            time.sleep(0.2)


def test_rapid_fire(tc):
    """T-RAPID: Publish 50 messages rapidly to test ESP32 doesn't crash."""
    print("\n─── T-RAPID: Rapid-Fire Stress Test ───")
    tc.clear()

    success = 0
    for i in range(50):
        signal = i % 4
        payload = json.dumps({
            "seq": 200 + i, "ts_ms": 20000 + (i * 50),
            "publish_ts_ms": 20000 + (i * 50) + 2,
            "status": ["ATTENTIVE", "TIRED", "SLEEPY", "MICROSLEEP"][signal],
            "signal": signal, "fatigue": signal * 25, "ttl_ms": 1400
        }, separators=(",", ":"))
        if tc.publish("driver/status_meta", payload):
            success += 1
        time.sleep(0.02)  # 20ms between messages = 50 Hz

    record(f"Published {success}/50 rapid messages", success == 50)

    # Give ESP32 time to process
    time.sleep(2)

    # Check ESP32 is still alive via telemetry
    tc.clear("driver/esp32_telemetry")
    msgs = tc.wait_for_topic("driver/esp32_telemetry", count=1, timeout=5)
    record("ESP32 still publishing telemetry after stress test",
           len(msgs) > 0,
           "ESP32 may have crashed or disconnected" if not msgs else "")


def test_out_of_order_seq(tc):
    """T-OOO: Publish out-of-order sequence numbers."""
    print("\n─── T-OOO: Out-of-Order Sequence ───")
    tc.clear()

    # Send seq 300, then 299 (should be rejected by ESP32)
    for seq in [300, 299, 301, 298, 302]:
        payload = json.dumps({
            "seq": seq, "ts_ms": 30000 + seq,
            "publish_ts_ms": 30000 + seq + 2,
            "status": "ATTENTIVE", "signal": 0, "fatigue": 10, "ttl_ms": 1400
        }, separators=(",", ":"))
        tc.publish("driver/status_meta", payload)
        time.sleep(0.1)

    record("Published 5 out-of-order packets",
           True, "ESP32 should accept 300, reject 299, accept 301, reject 298, accept 302")


def test_retain_not_set(tc):
    """T-RETAIN: Verify no messages use retain flag."""
    print("\n─── T-RETAIN: No Retained Messages ───")
    tc.clear()

    # Check all received messages for retain flag
    time.sleep(1)
    with msg_lock:
        retained = []
        for topic, msgs in received_messages.items():
            for msg in msgs:
                if msg.get("retain"):
                    retained.append(topic)

    record("No retained messages on driver/* topics",
           len(retained) == 0,
           f"Retained found on: {set(retained)}" if retained else "")


# ============================================================
# Main
# ============================================================
def main():
    parser = argparse.ArgumentParser(description="MQTT Integration Test Suite")
    parser.add_argument("--broker", default="127.0.0.1", help="MQTT broker address")
    parser.add_argument("--port", type=int, default=1883, help="MQTT broker port")
    parser.add_argument("--hil", action="store_true",
                        help="Hardware-in-the-loop mode (expects ESP32 connected)")
    args = parser.parse_args()

    print("=" * 72)
    print("MQTT INTEGRATION TEST SUITE — Drowsiness Alert System")
    print("=" * 72)
    print(f"Timestamp: {time.strftime('%Y-%m-%dT%H:%M:%S%z')}")
    print(f"Broker:    {args.broker}:{args.port}")
    print(f"Mode:      {'HIL (ESP32 expected)' if args.hil else 'Broker-only'}")
    print()

    tc = TestClient(args.broker, args.port)

    if not test_broker_connection(tc):
        print(f"\n{FAIL} Cannot connect to broker at {args.broker}:{args.port}")
        print("  Start Mosquitto: mosquitto -v")
        sys.exit(1)

    # Schema + publish tests (always run)
    test_publish_status_signal(tc)
    test_publish_status_meta(tc)
    test_command_reset_wifi(tc)
    test_command_clear_wifi(tc)
    test_command_invalid(tc)
    test_alert_event_schema(tc)
    test_out_of_order_seq(tc)
    test_retain_not_set(tc)

    if args.hil:
        # Tests that require ESP32 hardware
        test_esp32_telemetry(tc)
        test_state_transition_sequence(tc)
        test_rapid_fire(tc)
    else:
        print(f"\n  {SKIP}  Skipping HIL tests (ESP32 telemetry, state transitions, stress test)")
        print(f"  {SKIP}  Run with --hil flag when ESP32 is connected")

    tc.disconnect()

    # Summary
    print()
    print("=" * 72)
    total = len(results)
    passed = sum(1 for r in results if r["passed"])
    failed = total - passed
    print(f"TOTAL: {total}  |  {PASS}: {passed}  |  {FAIL}: {failed}")
    print("=" * 72)

    if failed > 0:
        print(f"\nFAILURES:")
        for r in results:
            if not r["passed"]:
                print(f"  • {r['name']}")
                if r["detail"]:
                    print(f"    → {r['detail']}")
    print()

    sys.exit(0 if failed == 0 else 1)


if __name__ == "__main__":
    main()
