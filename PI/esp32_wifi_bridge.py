#!/usr/bin/env python3
"""
ESP32 -> Raspberry Pi WiFi bridge daemon.

Purpose:
- Listen serial messages from ESP32: [ESP32_WIFI] {...}
- Apply WiFi credentials to Pi via nmcli
- Lock Pi WiFi to ESP32 SSID (optional, default ON)
- Send broker hint back to ESP32 via serial: [PI_BROKER] {...}

Designed to run independently from drowsy_edge.py (headless demo safe).
"""

import json
import os
import re
import select
import shutil
import signal
import socket
import subprocess
import threading
import time
from glob import glob


ESP32_WIFI_SERIAL_PORT = os.getenv("ESP32_WIFI_SERIAL_PORT", "/dev/ttyUSB0")
ESP32_WIFI_SERIAL_BAUD = int(os.getenv("ESP32_WIFI_SERIAL_BAUD", "115200"))
PI_WIFI_INTERFACE = os.getenv("PI_WIFI_INTERFACE", "wlan0")
MQTT_BROKER = os.getenv("MQTT_BROKER", "127.0.0.1")
MQTT_PORT = int(os.getenv("MQTT_PORT", "1883"))
DEFAULT_CMD_TIMEOUT_S = 25
WIFI_SYNC_DUP_WINDOW_MS = 15000
WIFI_SYNC_RETRY_DELAY_S = 2.0
WIFI_LOCK_TO_ESP32 = os.getenv("WIFI_LOCK_TO_ESP32", "1").strip().lower() in (
    "1",
    "true",
    "yes",
    "on",
)
# Default ON for demo safety: Pi is locked to ESP32-provisioned target network.
WIFI_LOCK_CHECK_MS = int(os.getenv("WIFI_LOCK_CHECK_MS", "2500"))
WIFI_REQUIRE_ESP32_TARGET = os.getenv("WIFI_REQUIRE_ESP32_TARGET", "1").strip().lower() in (
    "1",
    "true",
    "yes",
    "on",
)
NO_TARGET_DISCONNECT_COOLDOWN_MS = int(os.getenv("NO_TARGET_DISCONNECT_COOLDOWN_MS", "15000"))
BROKER_HINT_INTERVAL_S = float(os.getenv("BROKER_HINT_INTERVAL_S", "5.0"))
ESP32_SYNC_REQUEST_INTERVAL_MS = int(os.getenv("ESP32_SYNC_REQUEST_INTERVAL_MS", "1800"))
NO_TARGET_FORCE_SERIAL_REOPEN_MS = int(os.getenv("NO_TARGET_FORCE_SERIAL_REOPEN_MS", "12000"))
ESP32_TARGET_WAIT_GRACE_MS = int(os.getenv("ESP32_TARGET_WAIT_GRACE_MS", "30000"))
ESP32_TARGET_LOSS_GRACE_MS = int(os.getenv("ESP32_TARGET_LOSS_GRACE_MS", "30000"))
ESP32_SERIAL_OFFLINE_GRACE_MS = int(os.getenv("ESP32_SERIAL_OFFLINE_GRACE_MS", "1500"))
KEEP_LAST_TARGET_WHEN_SERIAL_OFFLINE = os.getenv("KEEP_LAST_TARGET_WHEN_SERIAL_OFFLINE", "1").strip().lower() in (
    "1",
    "true",
    "yes",
    "on",
)
WIFI_HARD_LOCK_RADIO = os.getenv("WIFI_HARD_LOCK_RADIO", "1").strip().lower() in (
    "1",
    "true",
    "yes",
    "on",
)
WIFI_RADIO_TOGGLE_GAP_MS = int(os.getenv("WIFI_RADIO_TOGGLE_GAP_MS", "4000"))
WIFI_ENFORCE_RECONNECT_GAP_MS = int(os.getenv("WIFI_ENFORCE_RECONNECT_GAP_MS", "1200"))
WIFI_MISMATCH_HOLD_MS = int(os.getenv("WIFI_MISMATCH_HOLD_MS", "1800"))
WIFI_CONNECT_WAIT_S = max(4, int(os.getenv("WIFI_CONNECT_WAIT_S", "12")))
WIFI_CONNECT_TIMEOUT_S = max(WIFI_CONNECT_WAIT_S + 2, int(os.getenv("WIFI_CONNECT_TIMEOUT_S", "20")))
WIFI_FAIL_RECOVER_AFTER = max(2, int(os.getenv("WIFI_FAIL_RECOVER_AFTER", "2")))
WIFI_FAIL_RECOVER_COOLDOWN_MS = int(os.getenv("WIFI_FAIL_RECOVER_COOLDOWN_MS", "12000"))
AUTO_SERIAL_DISCOVERY = os.getenv("AUTO_SERIAL_DISCOVERY", "1").strip().lower() in (
    "1",
    "true",
    "yes",
    "on",
)
SERIAL_REOPEN_MIN_S = float(os.getenv("SERIAL_REOPEN_MIN_S", "0.4"))
SERIAL_REOPEN_MAX_S = float(os.getenv("SERIAL_REOPEN_MAX_S", "3.0"))

_stop_event = threading.Event()

_wifi_sync_last_signature = ""
_wifi_sync_last_attempt_ms = 0
_esp32_serial_fd = -1
_esp32_serial_lock = threading.Lock()
_last_serial_open_path = ""
_last_broker_hint = ""
_last_broker_hint_ms = 0
_last_esp32_conn_sig = ""
_last_esp32_conn_ms = 0
_last_esp32_cred_sig = ""
_last_esp32_cred_ms = 0
_last_esp32_raw_sig = ""
_last_esp32_raw_ms = 0
_wifi_target_lock = threading.Lock()
_esp32_target_ssid = ""
_esp32_target_password = ""
_last_wifi_lock_log_ms = 0
_last_no_target_action_ms = 0
_wifi_connect_lock = threading.Lock()
_wifi_lock_kick_event = threading.Event()
_last_sync_request_ms = 0
_daemon_start_ms = int(time.monotonic() * 1000)
_last_target_seen_ms = 0
_wifi_connect_fail_streak = 0
_last_wifi_recover_ms = 0
_last_serial_cfg_warn_ms = 0
_wifi_radio_state = None
_last_wifi_radio_toggle_ms = 0
_last_wifi_enforce_reconnect_ms = 0
_serial_offline_since_ms = 0
_ssid_mismatch_since_ms = 0
_last_serial_reopen_req_ms = 0


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
        # Keep serial sync alive even when Pi WiFi is not up yet.
        return ip if ip else "raspberrypi.local"
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

    with _esp32_serial_lock:
        if signature == _last_broker_hint and (now_ms - _last_broker_hint_ms) < 2500:
            return
        if _esp32_serial_fd < 0:
            return
        try:
            os.write(_esp32_serial_fd, f"[PI_BROKER] {payload}\n".encode("utf-8"))
            # FIX: only update dedup signature AFTER successful write.
            # Previously signature was updated before write, blocking retries on failure.
            _last_broker_hint = signature
            _last_broker_hint_ms = now_ms
            print(f"[WIFI_SYNC] sent broker to ESP32 ({reason}): {host}:{int(MQTT_PORT)}")
        except Exception as exc:
            print(f"[WIFI_SYNC] send broker failed: {exc}")
            # Do NOT update signature on failure — allow immediate retry.


def _request_esp32_sync(reason, force=False):
    global _last_sync_request_ms
    payload = json.dumps({"type": "pi_sync_request", "reason": str(reason)}, separators=(",", ":"))
    with _esp32_serial_lock:
        now_ms = int(time.monotonic() * 1000)
        if (not force) and (now_ms - _last_sync_request_ms) < max(300, ESP32_SYNC_REQUEST_INTERVAL_MS):
            return False
        if _esp32_serial_fd < 0:
            return False
        try:
            os.write(_esp32_serial_fd, f"[PI_SYNC_REQ] {payload}\n".encode("utf-8"))
            _last_sync_request_ms = now_ms
            print(f"[WIFI_SYNC] request ESP32 sync ({reason})")
            return True
        except Exception as exc:
            print(f"[WIFI_SYNC] request sync failed: {exc}")
    return False


def _kick_wifi_lock():
    _wifi_lock_kick_event.set()


def _force_serial_reopen(reason):
    global _last_serial_reopen_req_ms, _esp32_serial_fd
    now_ms = int(time.monotonic() * 1000)
    cooldown_ms = max(2500, NO_TARGET_FORCE_SERIAL_REOPEN_MS // 2)
    if (now_ms - _last_serial_reopen_req_ms) < cooldown_ms:
        return False

    fd = -1
    with _esp32_serial_lock:
        if _esp32_serial_fd < 0:
            return False
        fd = _esp32_serial_fd
        _last_serial_reopen_req_ms = now_ms
        # Force worker to reopen serial; this mirrors a manual service restart
        # without dropping the whole daemon process.
        _esp32_serial_fd = -1

    try:
        os.close(fd)
    except Exception:
        pass

    print(f"[WIFI_SYNC] force serial reopen ({reason})")
    _kick_wifi_lock()
    return True


def _serial_candidates():
    seen = set()
    out = []

    def _add(path):
        if not path:
            return
        if path in seen:
            return
        seen.add(path)
        out.append(path)

    _add(ESP32_WIFI_SERIAL_PORT)
    if AUTO_SERIAL_DISCOVERY:
        for p in sorted(glob("/dev/serial/by-id/*")):
            _add(p)
        for p in sorted(glob("/dev/ttyUSB*")):
            _add(p)
        for p in sorted(glob("/dev/ttyACM*")):
            _add(p)
    return out


def _pick_serial_path():
    for p in _serial_candidates():
        try:
            if os.path.exists(p):
                return p
        except Exception:
            continue
    return ""


def _set_wifi_target_from_esp32(ssid, password):
    global _esp32_target_ssid, _esp32_target_password, _last_target_seen_ms
    clean_ssid = _sanitize_wifi_text(ssid, 32)
    clean_pass = _sanitize_wifi_text(password, 64)
    if not clean_ssid:
        return
    with _wifi_target_lock:
        if _esp32_target_ssid == clean_ssid and (not clean_pass) and _esp32_target_password:
            clean_pass = _esp32_target_password
        _esp32_target_ssid = clean_ssid
        _esp32_target_password = clean_pass
    _last_target_seen_ms = int(time.monotonic() * 1000)
    _kick_wifi_lock()


def _clear_wifi_target(reason=""):
    global _esp32_target_ssid, _esp32_target_password, _last_target_seen_ms
    cleared = False
    with _wifi_target_lock:
        if _esp32_target_ssid or _esp32_target_password:
            _esp32_target_ssid = ""
            _esp32_target_password = ""
            _last_target_seen_ms = 0
            cleared = True
    if cleared:
        suffix = f" ({reason})" if reason else ""
        print(f"[WIFI_LOCK] cleared ESP32 target{suffix}")


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
        # More reliable than GENERAL.CONNECTION profile name; returns active SSID.
        res = _run_cmd(["nmcli", "-t", "-f", "ACTIVE,SSID", "dev", "wifi", "list", "ifname", interface], timeout=7)
        if res.returncode == 0:
            for ln in (res.stdout or "").splitlines():
                row = ln.strip()
                if not row:
                    continue
                parts = row.split(":", 1)
                if len(parts) != 2:
                    continue
                active, ssid = parts[0].strip(), parts[1].strip()
                if active.lower() == "yes" and ssid:
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


def _nmcli_detail(res):
    stderr = (res.stderr or "").strip()
    stdout = (res.stdout or "").strip()
    return stderr if stderr else stdout


def _set_wifi_radio(enabled, reason="", force=False):
    global _wifi_radio_state, _last_wifi_radio_toggle_ms
    desired = bool(enabled)
    now_ms = int(time.monotonic() * 1000)
    if (
        (not force)
        and (_wifi_radio_state is desired)
        and ((now_ms - _last_wifi_radio_toggle_ms) < max(500, WIFI_RADIO_TOGGLE_GAP_MS))
    ):
        return True

    cmd = ["nmcli", "radio", "wifi", "on" if desired else "off"]
    try:
        res = _run_cmd(cmd, timeout=8)
    except Exception as exc:
        print(f"[WIFI_LOCK] radio {'on' if desired else 'off'} error: {exc}")
        return False
    if res.returncode != 0:
        detail = _nmcli_detail(res)
        if detail:
            print(f"[WIFI_LOCK] radio {'on' if desired else 'off'} failed: {detail}")
        return False

    changed = (_wifi_radio_state is None) or (_wifi_radio_state != desired)
    _wifi_radio_state = desired
    _last_wifi_radio_toggle_ms = now_ms
    if changed:
        suffix = f" ({reason})" if reason else ""
        print(f"[WIFI_LOCK] WiFi radio {'ON' if desired else 'OFF'}{suffix}")
    return True


def _attempt_nmcli_connect(ssid, password, interface):
    wait_s = str(max(4, WIFI_CONNECT_WAIT_S))
    timeout_s = max(WIFI_CONNECT_TIMEOUT_S, WIFI_CONNECT_WAIT_S + 2)

    # Keep device in managed mode and radio on; this is cheap and prevents stale states.
    try:
        _set_wifi_radio(True, "connect_attempt")
        _run_cmd(["nmcli", "device", "set", interface, "managed", "yes"], timeout=6)
    except Exception:
        pass

    attempts = [
        ("profile_up", ["nmcli", "--wait", wait_s, "connection", "up", "id", ssid, "ifname", interface]),
    ]
    wifi_connect_cmd = ["nmcli", "--wait", wait_s, "dev", "wifi", "connect", ssid, "ifname", interface]
    if password:
        wifi_connect_cmd.extend(["password", password])
    attempts.append(("wifi_connect", wifi_connect_cmd))

    last_detail = ""
    for step, cmd in attempts:
        try:
            res = _run_cmd(cmd, timeout=timeout_s)
        except Exception as exc:
            last_detail = f"{step}: {exc}"
            continue
        if res.returncode == 0:
            return True, ""
        detail = _nmcli_detail(res)
        last_detail = f"{step}: {detail}" if detail else f"{step}: rc={res.returncode}"

    # Rescan once and retry direct connect quickly for roaming/demo changes.
    try:
        _run_cmd(["nmcli", "dev", "wifi", "rescan", "ifname", interface], timeout=7)
    except Exception:
        pass
    try:
        res = _run_cmd(wifi_connect_cmd, timeout=timeout_s)
        if res.returncode == 0:
            return True, ""
        detail = _nmcli_detail(res)
        if detail:
            last_detail = f"wifi_connect_rescan: {detail}"
    except Exception as exc:
        last_detail = f"wifi_connect_rescan: {exc}"
    return False, last_detail


def _recover_wifi_stack(interface, reason):
    global _last_wifi_recover_ms, _wifi_radio_state, _last_wifi_radio_toggle_ms
    now_ms = int(time.monotonic() * 1000)
    if (now_ms - _last_wifi_recover_ms) < max(2000, WIFI_FAIL_RECOVER_COOLDOWN_MS):
        return False

    _last_wifi_recover_ms = now_ms
    print(f"[WIFI_SYNC] recovering WiFi stack ({reason})")
    cmds = [
        (["nmcli", "device", "disconnect", interface], 10),
        (["ip", "link", "set", interface, "down"], 8),
        (["nmcli", "radio", "wifi", "off"], 8),
        (["nmcli", "radio", "wifi", "on"], 8),
        (["ip", "link", "set", interface, "up"], 8),
        (["nmcli", "device", "set", interface, "managed", "yes"], 8),
        (["nmcli", "dev", "wifi", "rescan", "ifname", interface], 8),
    ]

    for cmd, timeout in cmds:
        try:
            _run_cmd(cmd, timeout=timeout)
            if cmd[:3] == ["nmcli", "radio", "wifi"] and len(cmd) >= 4:
                mode = cmd[3].strip().lower()
                if mode in ("off", "on"):
                    _wifi_radio_state = (mode == "on")
                    _last_wifi_radio_toggle_ms = int(time.monotonic() * 1000)
            if cmd[2:4] == ["wifi", "off"]:
                time.sleep(0.25)
        except Exception:
            pass
    return True


def _connect_pi_wifi(ssid, password, interface, force=False):
    global _wifi_sync_last_signature, _wifi_sync_last_attempt_ms
    global _wifi_connect_fail_streak, _wifi_radio_state, _last_wifi_radio_toggle_ms
    now_ms = int(time.monotonic() * 1000)
    signature = f"{ssid}\n{password}\n{interface}"
    if (not force) and signature == _wifi_sync_last_signature and (now_ms - _wifi_sync_last_attempt_ms) < WIFI_SYNC_DUP_WINDOW_MS:
        return False

    _wifi_sync_last_signature = signature
    _wifi_sync_last_attempt_ms = now_ms
    interface = _sanitize_wifi_text(interface, 32)
    if not _is_valid_iface_name(interface):
        print(f"[WIFI_SYNC] invalid interface: '{interface}'")
        return False

    ssid = _sanitize_wifi_text(ssid, 32)
    password = _sanitize_wifi_text(password, 64)
    if not ssid:
        return False

    current_ssid = _get_current_wifi_ssid(interface)
    if current_ssid == ssid:
        _wifi_connect_fail_streak = 0
        _wifi_radio_state = True
        _last_wifi_radio_toggle_ms = now_ms
        return True

    if not _wifi_connect_lock.acquire(blocking=False):
        return False

    try:
        print(f"[WIFI_SYNC] request ssid='{ssid}' iface={interface}")
        ok, detail = _attempt_nmcli_connect(ssid, password, interface)
        if not ok:
            _wifi_connect_fail_streak += 1
            if detail:
                print(
                    f"[WIFI_SYNC] Pi WiFi connect failed (try={_wifi_connect_fail_streak}): {detail}"
                )
            else:
                print(
                    f"[WIFI_SYNC] Pi WiFi connect failed (try={_wifi_connect_fail_streak})"
                )

            if _wifi_connect_fail_streak >= WIFI_FAIL_RECOVER_AFTER:
                if _recover_wifi_stack(interface, "connect_failed"):
                    ok2, detail2 = _attempt_nmcli_connect(ssid, password, interface)
                    if not ok2:
                        if detail2:
                            print(f"[WIFI_SYNC] retry after recover failed: {detail2}")
                        return False
                    ok = True

        if not ok:
            return False

        _wifi_connect_fail_streak = 0
        _wifi_radio_state = True
        _last_wifi_radio_toggle_ms = int(time.monotonic() * 1000)
        pi_ip = _get_pi_ip(interface)
        if pi_ip:
            print(f"[WIFI_SYNC] Pi WiFi connected: ssid='{ssid}' ip={pi_ip}")
        else:
            print(f"[WIFI_SYNC] Pi WiFi connected: ssid='{ssid}' ip=unknown")
        _send_pi_broker_hint("pi_wifi_connected")
        return True
    except Exception as exc:
        print(f"[WIFI_SYNC] Pi WiFi connect error: {exc}")
    finally:
        _wifi_connect_lock.release()
    return False


def _disconnect_pi_wifi(interface):
    global _wifi_connect_fail_streak
    interface = _sanitize_wifi_text(interface, 32)
    if not _is_valid_iface_name(interface):
        return False
    if not _wifi_connect_lock.acquire(blocking=False):
        return False
    try:
        res = _run_cmd(["nmcli", "device", "disconnect", interface], timeout=12)
        if res.returncode == 0:
            _wifi_connect_fail_streak = 0
            return True
        err = (res.stderr or "").strip()
        out = (res.stdout or "").strip()
        msg = err if err else out
        if msg:
            print(f"[WIFI_LOCK] disconnect failed: {msg}")
    except Exception as exc:
        print(f"[WIFI_LOCK] disconnect error: {exc}")
    finally:
        _wifi_connect_lock.release()
    return False


def _enforce_wifi_lock():
    global _last_wifi_lock_log_ms, _last_no_target_action_ms, _last_wifi_enforce_reconnect_ms
    global _serial_offline_since_ms
    global _ssid_mismatch_since_ms
    if not WIFI_LOCK_TO_ESP32:
        return

    now_ms = int(time.monotonic() * 1000)
    with _esp32_serial_lock:
        serial_online = _esp32_serial_fd >= 0
    if serial_online:
        _serial_offline_since_ms = 0
    elif _serial_offline_since_ms == 0:
        _serial_offline_since_ms = now_ms

    target_ssid, target_pass = _get_wifi_target_from_esp32()
    # If ESP32 serial is offline for a while, invalidate target so Pi cannot
    # keep using/falling back to non-ESP32-controlled WiFi.
    if (
        target_ssid
        and WIFI_REQUIRE_ESP32_TARGET
        and (not serial_online)
        and _serial_offline_since_ms > 0
        and (now_ms - _serial_offline_since_ms) > max(1000, ESP32_SERIAL_OFFLINE_GRACE_MS)
    ):
        if KEEP_LAST_TARGET_WHEN_SERIAL_OFFLINE:
            if WIFI_HARD_LOCK_RADIO:
                _set_wifi_radio(False, "serial_offline")
        else:
            _clear_wifi_target("serial_offline")
            target_ssid = ""
            target_pass = ""

    # If ESP32 has been silent for too long, target may be stale.
    # However, when KEEP_LAST_TARGET_WHEN_SERIAL_OFFLINE is ON and serial is
    # currently offline, keep the last target so WiFi can recover immediately
    # once ESP32 is plugged back in.
    clear_stale_target = serial_online or (not KEEP_LAST_TARGET_WHEN_SERIAL_OFFLINE)
    if (
        target_ssid
        and WIFI_REQUIRE_ESP32_TARGET
        and clear_stale_target
        and _last_target_seen_ms > 0
        and (now_ms - _last_target_seen_ms) > max(1000, ESP32_TARGET_LOSS_GRACE_MS)
    ):
        _clear_wifi_target("target_stale")
        target_ssid = ""
        target_pass = ""

    if not target_ssid:
        if WIFI_REQUIRE_ESP32_TARGET:
            _request_esp32_sync("no_target")

            # Strict mode: during boot/no-target window, keep radio OFF so Pi
            # cannot auto-attach to stale/non-ESP32 WiFi profiles.
            if WIFI_HARD_LOCK_RADIO:
                _set_wifi_radio(False, "no_esp32_target_boot_wait")

            # On boot, give ESP32 some time to publish credentials before forcing disconnect.
            if (now_ms - _daemon_start_ms) < max(1000, ESP32_TARGET_WAIT_GRACE_MS):
                return

            # If target was seen recently, keep existing WiFi to avoid temporary serial gaps
            # causing network churn during demos.
            if _last_target_seen_ms > 0 and (now_ms - _last_target_seen_ms) < max(1000, ESP32_TARGET_LOSS_GRACE_MS):
                return

            # Self-heal case where serial link is "up" but ESP32 never replies
            # to sync requests until manual service restart.
            if serial_online:
                no_target_age_ms = (
                    (now_ms - _last_target_seen_ms)
                    if _last_target_seen_ms > 0
                    else (now_ms - _daemon_start_ms)
                )
                if no_target_age_ms >= max(3000, NO_TARGET_FORCE_SERIAL_REOPEN_MS):
                    _force_serial_reopen("no_target_timeout")

            current_ssid = _get_current_wifi_ssid(PI_WIFI_INTERFACE)
            if current_ssid and (now_ms - _last_no_target_action_ms) >= NO_TARGET_DISCONNECT_COOLDOWN_MS:
                print(
                    f"[WIFI_LOCK] no ESP32 target yet -> disconnect current ssid='{current_ssid}'"
                )
                _disconnect_pi_wifi(PI_WIFI_INTERFACE)
                _last_no_target_action_ms = now_ms
            # HARD LOCK: prevent NetworkManager from auto-falling back to old SSIDs.
            if WIFI_HARD_LOCK_RADIO:
                _set_wifi_radio(False, "no_esp32_target")
        return

    if WIFI_HARD_LOCK_RADIO:
        _set_wifi_radio(True, "target_available")

    current_ssid = _get_current_wifi_ssid(PI_WIFI_INTERFACE)
    if current_ssid == target_ssid:
        _ssid_mismatch_since_ms = 0
        return

    if _ssid_mismatch_since_ms == 0:
        _ssid_mismatch_since_ms = now_ms
    if (now_ms - _ssid_mismatch_since_ms) < max(300, WIFI_MISMATCH_HOLD_MS):
        return

    if (now_ms - _last_wifi_lock_log_ms) >= 3000:
        print(
            f"[WIFI_LOCK] ssid mismatch: current='{current_ssid or 'none'}' "
            f"target='{target_ssid}' -> reconnect"
        )
        _last_wifi_lock_log_ms = now_ms
    if (now_ms - _last_wifi_enforce_reconnect_ms) < max(900, WIFI_ENFORCE_RECONNECT_GAP_MS):
        return
    _last_wifi_enforce_reconnect_ms = now_ms
    _connect_pi_wifi(target_ssid, target_pass, PI_WIFI_INTERFACE, force=True)


def _handle_esp32_wifi_sync_line(line):
    global _last_esp32_conn_sig, _last_esp32_conn_ms
    global _last_esp32_cred_sig, _last_esp32_cred_ms
    global _last_esp32_raw_sig, _last_esp32_raw_ms
    prefix = "[ESP32_WIFI] "
    if not line.startswith(prefix):
        return
    raw = line[len(prefix):].strip()
    if not raw:
        return
    now_ms = int(time.monotonic() * 1000)
    # Guard against serial echo/burst loops: skip identical raw packets in short window.
    if raw == _last_esp32_raw_sig and (now_ms - _last_esp32_raw_ms) < 1200:
        return
    _last_esp32_raw_sig = raw
    _last_esp32_raw_ms = now_ms
    try:
        data = json.loads(raw)
    except Exception:
        return

    msg_type = str(data.get("type", "")).strip().lower()
    if msg_type == "wifi_credentials":
        ssid = str(data.get("ssid", "")).strip()
        password = str(data.get("pass", "")).strip()
        cred_sig = f"{ssid}|{password}"
        is_dup = (cred_sig == _last_esp32_cred_sig) and ((now_ms - _last_esp32_cred_ms) < 2500)
        if ssid and (not is_dup):
            print(f"[WIFI_SYNC] received wifi_credentials: ssid='{ssid}'")
            _last_esp32_cred_sig = cred_sig
            _last_esp32_cred_ms = now_ms
        _set_wifi_target_from_esp32(ssid, password)
        # FIX: kick lock immediately so worker wakes up without waiting poll interval.
        _kick_wifi_lock()
    elif msg_type == "wifi_connected":
        esp_ip = str(data.get("esp_ip", "")).strip()
        ssid = str(data.get("ssid", "")).strip()
        if ssid:
            _set_wifi_target_from_esp32(ssid, "")
        sig = f"{ssid}|{esp_ip}"
        is_dup = (sig == _last_esp32_conn_sig) and ((now_ms - _last_esp32_conn_ms) < 2500)
        if esp_ip and (not is_dup):
            print(f"[WIFI_SYNC] ESP32 connected: ssid='{ssid}' esp_ip={esp_ip}")
        if not is_dup:
            # Avoid broker echo loop: periodic/serial_open/pi_wifi_connected already
            # send broker hints sufficiently for ESP32 sync.
            _last_esp32_conn_sig = sig
            _last_esp32_conn_ms = now_ms
        _kick_wifi_lock()


def _configure_serial_port(serial_path):
    global _last_serial_cfg_warn_ms
    cmd = [
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
    ]
    try:
        res = _run_cmd(cmd, timeout=2)
        if res.returncode == 0:
            return
        now_ms = int(time.monotonic() * 1000)
        if (now_ms - _last_serial_cfg_warn_ms) >= 5000:
            detail = _nmcli_detail(res)
            msg = detail if detail else f"rc={res.returncode}"
            print(f"[WIFI_SYNC] stty warning: {msg}")
            _last_serial_cfg_warn_ms = now_ms
    except Exception as exc:
        now_ms = int(time.monotonic() * 1000)
        if (now_ms - _last_serial_cfg_warn_ms) >= 5000:
            print(f"[WIFI_SYNC] stty warning: {exc}")
            _last_serial_cfg_warn_ms = now_ms


def _esp32_wifi_sync_worker():
    global _esp32_serial_fd, _last_serial_open_path
    delay_s = SERIAL_REOPEN_MIN_S

    while not _stop_event.is_set():
        serial_path = _pick_serial_path()
        if not serial_path:
            _stop_event.wait(delay_s)
            delay_s = min(SERIAL_REOPEN_MAX_S, max(delay_s * 1.5, SERIAL_REOPEN_MIN_S))
            continue

        fd = -1
        try:
            if serial_path != _last_serial_open_path:
                print(f"[WIFI_SYNC] serial candidate: {serial_path}")
                _last_serial_open_path = serial_path

            _configure_serial_port(serial_path)
            fd = os.open(serial_path, os.O_RDWR | os.O_NONBLOCK)
            with _esp32_serial_lock:
                _esp32_serial_fd = fd
            print(f"[WIFI_SYNC] listening {serial_path}@{ESP32_WIFI_SERIAL_BAUD}")
            _kick_wifi_lock()
            _request_esp32_sync("serial_open", force=True)
            _send_pi_broker_hint("serial_open")
            delay_s = SERIAL_REOPEN_MIN_S
            # FIX: always start with empty buffer after (re)connect to avoid
            # parsing stale/corrupt data from previous session.
            buf = ""
            while not _stop_event.is_set():
                try:
                    ready, _, _ = select.select([fd], [], [], 0.3)
                except Exception as exc:
                    print(f"[WIFI_SYNC] serial select error: {exc}")
                    break
                if not ready:
                    continue
                try:
                    chunk = os.read(fd, 512)
                except BlockingIOError:
                    continue
                except Exception as exc:
                    print(f"[WIFI_SYNC] serial read error: {exc}")
                    break
                if not chunk:
                    print("[WIFI_SYNC] serial EOF -> reopen")
                    break
                buf += chunk.decode("utf-8", errors="ignore")
                # FIX: cap buffer size to 8KB to prevent memory bloat on
                # continuous serial data without newlines (e.g. ESP32 crash log).
                if len(buf) > 8192:
                    last_nl = buf.rfind("\n", 0, 4096)
                    if last_nl >= 0:
                        buf = buf[last_nl + 1:]
                    else:
                        buf = ""
                    print("[WIFI_SYNC] serial buf overflow - truncated")
                while "\n" in buf:
                    line, buf = buf.split("\n", 1)
                    _handle_esp32_wifi_sync_line(line.strip())
        except Exception as exc:
            print(f"[WIFI_SYNC] serial worker error: {exc}")
            _stop_event.wait(delay_s)
            delay_s = min(SERIAL_REOPEN_MAX_S, max(delay_s * 1.5, SERIAL_REOPEN_MIN_S))
        finally:
            with _esp32_serial_lock:
                if _esp32_serial_fd == fd:
                    _esp32_serial_fd = -1
            _kick_wifi_lock()
            if fd >= 0:
                try:
                    os.close(fd)
                except Exception:
                    pass


def _wifi_lock_worker():
    interval_s = max(0.4, WIFI_LOCK_CHECK_MS / 1000.0)
    while not _stop_event.is_set():
        _enforce_wifi_lock()
        _wifi_lock_kick_event.wait(interval_s)
        _wifi_lock_kick_event.clear()


def _broker_hint_worker():
    while not _stop_event.is_set():
        _send_pi_broker_hint("periodic")
        target_ssid, _ = _get_wifi_target_from_esp32()
        if not target_ssid:
            _request_esp32_sync("periodic_no_target")
        _stop_event.wait(max(1.0, BROKER_HINT_INTERVAL_S))


def _check_runtime_dependencies():
    deps = ["nmcli", "ip", "iwgetid", "stty"]
    missing = [d for d in deps if shutil.which(d) is None]
    if missing:
        print(f"[WIFI_SYNC] warning missing commands: {', '.join(missing)}")
        print("[WIFI_SYNC] install NetworkManager/net-tools equivalents before demo")


def _handle_stop(_sig_num, _frame):
    _stop_event.set()


def main():
    signal.signal(signal.SIGINT, _handle_stop)
    signal.signal(signal.SIGTERM, _handle_stop)

    _check_runtime_dependencies()

    print("[WIFI_SYNC] daemon start")
    print(f"[WIFI_SYNC] serial={ESP32_WIFI_SERIAL_PORT}@{ESP32_WIFI_SERIAL_BAUD}")
    print(f"[WIFI_SYNC] serial_auto_discovery={'ON' if AUTO_SERIAL_DISCOVERY else 'OFF'}")
    print(f"[WIFI_SYNC] iface={PI_WIFI_INTERFACE}")
    print(f"[WIFI_SYNC] lock={'ON' if WIFI_LOCK_TO_ESP32 else 'OFF'} check={WIFI_LOCK_CHECK_MS}ms")
    print(f"[WIFI_SYNC] require_esp32_target={'ON' if WIFI_REQUIRE_ESP32_TARGET else 'OFF'}")
    print(
        f"[WIFI_SYNC] hard_lock_radio={'ON' if WIFI_HARD_LOCK_RADIO else 'OFF'} "
        f"toggle_gap={WIFI_RADIO_TOGGLE_GAP_MS}ms"
    )
    print(f"[WIFI_SYNC] reconnect_gap={WIFI_ENFORCE_RECONNECT_GAP_MS}ms")
    print(
        f"[WIFI_SYNC] target_grace boot={ESP32_TARGET_WAIT_GRACE_MS}ms "
        f"loss={ESP32_TARGET_LOSS_GRACE_MS}ms serial_offline={ESP32_SERIAL_OFFLINE_GRACE_MS}ms"
    )
    print(
        f"[WIFI_SYNC] keep_last_target_when_serial_offline="
        f"{'ON' if KEEP_LAST_TARGET_WHEN_SERIAL_OFFLINE else 'OFF'}"
    )
    print(
        f"[WIFI_SYNC] connect wait={WIFI_CONNECT_WAIT_S}s timeout={WIFI_CONNECT_TIMEOUT_S}s "
        f"recover_after={WIFI_FAIL_RECOVER_AFTER}"
    )
    print(f"[WIFI_SYNC] sync_request_interval={ESP32_SYNC_REQUEST_INTERVAL_MS}ms")
    print(f"[WIFI_SYNC] no_target_force_serial_reopen={NO_TARGET_FORCE_SERIAL_REOPEN_MS}ms")
    print(f"[WIFI_SYNC] broker={MQTT_BROKER}:{MQTT_PORT}")

    threads = [
        threading.Thread(target=_esp32_wifi_sync_worker, name="wifi-sync", daemon=True),
        threading.Thread(target=_wifi_lock_worker, name="wifi-lock", daemon=True),
        threading.Thread(target=_broker_hint_worker, name="broker-hint", daemon=True),
    ]
    for t in threads:
        t.start()

    try:
        while not _stop_event.is_set():
            _stop_event.wait(0.2)
    finally:
        _stop_event.set()
        for t in threads:
            t.join(timeout=1.0)
        print("[WIFI_SYNC] daemon stop")


if __name__ == "__main__":
    main()
