# REPORT_INPUT - Drowsiness Detection Platform

Last verified: 2026-04-10
Repository root: /Users/tolinh/drowsy

## 1) Executive Snapshot

This project is an end-to-end driver drowsiness platform with 4 main blocks:

1. Raspberry Pi AI detection and MQTT publish (`drowsy_edge.py`).
2. Raspberry Pi WiFi sync daemon (separate process, auto-start by systemd) (`esp32_wifi_bridge.py`).
3. ESP32 alert node (buzzer + LEDs + motion + MQTT + serial bridge integration).
4. Flutter mobile app (`sleepy_app`) for live status, alerts, and history.

Main design target:
- Stable real-time demo on unstable hotspot networks.
- Fast edge pipeline at 224x168.
- Safe MQTT state sync (QoS1 + heartbeat + reconnect).
- Forced Pi WiFi follow ESP32-provided SSID/password for headless demo.
- App sync with Pi status, fatigue, signal, and armed gate.

## 2) Source Of Truth (Current Active Files)

### 2.1 Raspberry Pi AI + MQTT
- `/Users/tolinh/drowsy/drowsy_edge.py`

### 2.2 Raspberry Pi WiFi bridge daemon
- `/Users/tolinh/drowsy/esp32_wifi_bridge.py`
- `/Users/tolinh/drowsy/systemd/esp32-wifi-sync.service`
- `/Users/tolinh/drowsy/install_esp32_wifi_sync_service.sh`
- `/Users/tolinh/drowsy/WIFI_SYNC_SERVICE.md`

### 2.3 Mobile app
- `/Users/tolinh/drowsy/sleepy_app`

### 2.4 ESP32 firmware (active PlatformIO project)
- `/Users/tolinh/Documents/PlatformIO/Projects/drowsy_esp32/platformio.ini`
- `/Users/tolinh/Documents/PlatformIO/Projects/drowsy_esp32/src/main.cpp`
- `/Users/tolinh/Documents/PlatformIO/Projects/drowsy_esp32/src/wifi_manager.cpp`
- `/Users/tolinh/Documents/PlatformIO/Projects/drowsy_esp32/src/wifi_manager.h`

Note: `esp32_drowsy_alert.ino` exists in Pi repo but active firmware work is in the PlatformIO project above.

## 3) High-Level Data Flow

1. ESP32 gets WiFi credentials (portal / saved creds / reconnect).
2. ESP32 sends serial to Pi:
   - `[ESP32_WIFI] {"type":"wifi_credentials",...}`
   - `[ESP32_WIFI] {"type":"wifi_connected",...}`
3. Pi daemon (`esp32_wifi_bridge.py`) receives serial, runs `nmcli` to connect Pi WiFi, and enforces lock to ESP32 SSID.
4. Pi daemon sends back to ESP32:
   - `[PI_BROKER] {"type":"broker","host":"...","port":1883}`
   - `[PI_SYNC_REQ] {"type":"pi_sync_request",...}` when needed.
5. `drowsy_edge.py` publishes detection states to MQTT:
   - `driver/status`
   - `driver/status_meta`
   - `driver/alert_event`
6. ESP32 subscribes to MQTT topics, maps status to alert mode (buzzer/LED).
7. Mobile app subscribes to `driver/#`, parses `status`, `status_meta`, `alert_event`, and shows realtime UI + notifications + history.

## 4) Raspberry Pi AI Module (`drowsy_edge.py`)

### 4.1 Core runtime
- OpenCV + MediaPipe FaceLandmarker.
- Frame size: `224x168`.
- Adaptive inference interval based on risk and measured infer time.
- Processing thread + camera thread + MQTT reconnect thread.

### 4.2 MQTT output contract
- `MQTT_TOPIC = "driver/status"` (numeric signal as string)
- `MQTT_META_TOPIC = "driver/status_meta"` (JSON with detail)
- `MQTT_ALERT_TOPIC = "driver/alert_event"` (JSON alert lifecycle)
- QoS: status/meta at least once, will-set safe `0` on disconnect.

### 4.3 Arm gate / safety logic
- `PI_ARM_GATE_ENABLED` default ON.
- `ATTENTIVE_ARM_MS = 30000` (must look forward continuously for 30s before arming).
- Before armed:
  - status is forced to ATTENTIVE path,
  - `armed=0` in meta,
  - buzzer expected OFF.
- NO FACE rearm reset:
  - `NO_FACE_REARM_MS = 60000`.
  - If NO FACE >= 60s while armed, system disarms and requires another 30s attentive window.

### 4.4 No-face and anti-flicker protections
- Danger hold windows prevent unsafe -> safe flicker.
- Fast recovery path exists for clear attentive recovery.
- NO FACE is explicitly mapped to ESP text `NO_FACE`.

### 4.5 WiFi sync mode in Pi AI
- Default mode: external daemon (`INTERNAL_WIFI_SYNC_ENABLED=0`).
- Internal in-process WiFi sync is kept only as debug fallback if explicitly enabled.

## 5) Raspberry Pi WiFi Bridge Daemon (`esp32_wifi_bridge.py`)

### 5.1 Mission
- Run independently from AI process.
- Handle serial WiFi sync and Pi WiFi locking for headless demo.

### 5.2 Key behaviors
- Serial listener with auto reopen and backoff.
- Serial auto-discovery support (`AUTO_SERIAL_DISCOVERY=1` default).
- Dedup and lock for WiFi connect calls to avoid races.
- Active sync requests to ESP32 if target missing:
  - `[PI_SYNC_REQ]` periodic and on serial open.
- Broker hint back to ESP32:
  - `[PI_BROKER]` on events + periodic heartbeat.
- If broker is localhost and Pi has no IP yet, fallback host can be `raspberrypi.local`.

### 5.3 Forced WiFi policy
- `WIFI_LOCK_TO_ESP32=1` -> Pi must stay on ESP32 target SSID.
- `WIFI_REQUIRE_ESP32_TARGET=1` -> if no ESP32 target yet, bridge can disconnect current non-target SSID.
- This is the headless-demo-safe mode.

## 6) ESP32 Firmware (PlatformIO Project)

### 6.1 Network and sync
- `WifiManager` emits serial credentials/connected packets to Pi.
- Handles Pi serial control:
  - `[PI_BROKER]`
  - `[PI_SYNC_REQ]`
  - JSON `pi_sync_request` / `wifi_sync_request`
- `requestPiSync()` throttled and robust.

### 6.2 MQTT
- Default broker host in firmware: `raspberrypi.local`.
- Topics:
  - `driver/status`
  - `driver/status_meta`
  - `driver/cmd`
- Parses `status_meta` including `armed` flag.

### 6.3 Arm gate coordination
- `ENABLE_DRIVING_ARM_GATE = true`
- `FOLLOW_PI_ARM_GATE = true`
- ESP32 follows Pi `armed` from metadata to avoid false local arming.
- When Pi armed rises, ESP32 can play confirm-beep pattern (3 beeps behavior path).

### 6.4 Status mapping
- `ATTENTIVE`, `NORMAL`, `NO FACE`, `NO_FACE` map to SAFE path.
- Danger states map to fast/continuous alert patterns as configured.

## 7) Mobile App (`sleepy_app`) - Current Contract

### 7.1 MQTT config defaults
- Broker default: `raspberrypi.local`
- Topic pattern default: `driver/#`

### 7.2 Parsed metadata
- `rawStatus`, `signal`, `fatigue`, `armed`, `eventId`, `topic`
- App uses metadata-aware dedup logic and accepts detail updates even if coarse state unchanged.

### 7.3 Alert policy
- Sleep popup/notification triggers on transition into sleep state.
- Alert is suppressed when `armed == false`.

### 7.4 Storage and cloud
- Local SQLite (`sqflite`) history with row cap.
- Optional Firebase sync path exists.

## 8) MQTT Message Contract (Current)

### 8.1 Topic: `driver/status`
Payload:
- String integer signal: `"0" | "1" | "2" | "3"`

### 8.2 Topic: `driver/status_meta`
Example:
```json
{
  "seq": 1234,
  "ts_ms": 4567890,
  "publish_ts_ms": 1712620000000,
  "status": "ATTENTIVE",
  "signal": 0,
  "fatigue": 12,
  "armed": 1,
  "ttl_ms": 1400
}
```

### 8.3 Topic: `driver/alert_event`
Start event example:
```json
{
  "event_id": "evt-sess-...-0001",
  "event_type": "DROWSY_ALERT",
  "trigger_status": "DROWSY",
  "fatigue_score": 86,
  "timestamp_ms": 1712620005000,
  "duration_ms": 0,
  "resolved": false
}
```

Resolved event example:
```json
{
  "event_id": "evt-sess-...-0001",
  "event_type": "DROWSY_ALERT_RESOLVED",
  "trigger_status": "DROWSY",
  "fatigue_score": 41,
  "timestamp_ms": 1712620012000,
  "duration_ms": 7000,
  "resolved": true
}
```

## 9) Deployment Procedure (Reproducible)

### 9.1 On Raspberry Pi - install WiFi bridge service
```bash
cd /home/pi/drowsy_project
chmod +x esp32_wifi_bridge.py install_esp32_wifi_sync_service.sh
ESP32_WIFI_SERIAL_PORT=/dev/serial/by-id/usb-Silicon_Labs_CP2102_USB_to_UART_Bridge_Controller_0001-if00-port0 \
AUTO_SERIAL_DISCOVERY=1 \
WIFI_REQUIRE_ESP32_TARGET=1 \
ESP32_SYNC_REQUEST_INTERVAL_MS=1800 \
PYTHON_BIN=/usr/bin/python3 \
./install_esp32_wifi_sync_service.sh
```

### 9.2 Verify service
```bash
systemctl is-enabled esp32-wifi-sync.service
systemctl is-active esp32-wifi-sync.service
systemctl show esp32-wifi-sync.service -p NRestarts -p ExecMainStatus -p Result
sudo journalctl -u esp32-wifi-sync.service -f
```

### 9.3 Run Pi detection
```bash
cd /home/pi/drowsy_project
source .venv/bin/activate
python3 drowsy_edge.py --mqtt-host 127.0.0.1 --mqtt-port 1883
# headless:
python3 drowsy_edge.py --mqtt-host 127.0.0.1 --mqtt-port 1883 --no-preview
```

### 9.4 Flash ESP32 (PlatformIO)
```bash
cd /Users/tolinh/Documents/PlatformIO/Projects/drowsy_esp32
pio run -t upload
pio device monitor -b 115200
```

### 9.5 Run mobile app
```bash
cd /Users/tolinh/drowsy/sleepy_app
flutter pub get
flutter run -d ios \
  --dart-define=MQTT_BROKER=raspberrypi.local \
  --dart-define=MQTT_PORT=1883 \
  --dart-define=MQTT_TOPIC=driver/#
```

## 10) Demo SOP (No Monitor Scenario)

1. Power Pi and ESP32.
2. ESP32 obtains/keeps WiFi creds and sends them to Pi over serial.
3. Pi bridge daemon connects Pi to ESP32-selected WiFi automatically.
4. SSH to `pi@raspberrypi.local` (or IP if known).
5. Start `drowsy_edge.py`.
6. Driver must look straight for 30s to arm detection.
7. If driver leaves seat and NO FACE > 60s, system disarms and requires 30s arm again.
8. App listens to MQTT and shows synchronized status/alerts/history.

## 11) Validation Checklist

1. Boot Pi + ESP32 together without manual ESP32 reset -> Pi still receives sync and connects WiFi.
2. Bridge service remains active with stable restart counters.
3. Pi publishes `driver/status_meta` with `armed` field.
4. Before arm complete, ESP32 does not produce false sleep alarms.
5. NO FACE > 60s causes disarm and requires new 30s attentive arm.
6. App reflects Pi status (`rawStatus`) and does not trigger sleep alerts when `armed=false`.
7. Moving to a new WiFi location still works via ESP32 credentials flow.

## 12) Known Limits / Risks

1. Legacy docs may still reference old topic names (`drowsy/status`). Current production contract is `driver/*`.
2. Pi bridge service runs as root in systemd for serial + network control.
3. `nmcli` / NetworkManager must be installed and active on Pi.
4. Serial path must be stable (recommended `/dev/serial/by-id/...`).
5. If Pi DNS/mDNS is weak in a site, `raspberrypi.local` may fail and direct IP may be needed.

## 13) Recommended Report Chapter Structure

1. Problem statement and motivation.
2. System architecture and dataflow.
3. Edge AI algorithm and state machine design.
4. Communication layer (MQTT + serial sync).
5. WiFi resilience and headless deployment strategy.
6. Embedded alert logic on ESP32.
7. Mobile app integration and UX alert strategy.
8. Experimental setup and evaluation scenarios.
9. Results, limitations, and future work.

## 14) Quick Prompt To Feed Into ChatGPT For Full Thesis Draft

Use the following instruction:

"Based on REPORT_INPUT.md, write a full Vietnamese scientific report draft for a driver drowsiness detection system using Raspberry Pi 4, ESP32, MQTT, and Flutter app. Keep all technical values and contracts exactly as specified. Include architecture diagrams in text form, algorithm explanation, deployment workflow, experimental scenarios, result discussion, limitations, and future improvements."

## 15) Latest Update Log (2026-04-10)

### 15.1 ESP32 WiFi Portal UX (Premium + EN/VI)
- Updated active file:
  - `/Users/tolinh/Documents/PlatformIO/Projects/drowsy_esp32/src/wifi_manager.cpp`
- Upgraded `handleRoot()` and `handleSave()` captive pages with:
  - Bilingual labels (English/Vietnamese) for SSID, password, and states.
  - Premium visual style (card, gradient background, clearer hierarchy).
  - Show/hide password checkbox for setup reliability.
  - Better error messages:
    - missing SSID
    - SSID too long
    - password too long
  - Improved connecting page:
    - clearer progress text
    - bilingual status updates from `/status` polling
    - existing auto-redirect and auto-close behavior preserved.

### 15.2 ESP32 Alert Safety: Auto-Cutoff Buzzer After 5s Sleep Alarm
- Updated active file:
  - `/Users/tolinh/Documents/PlatformIO/Projects/drowsy_esp32/src/main.cpp`
- Added/confirmed:
  - `SLEEP_ALARM_MAX_MS = 5000`
  - `gAlarmModeStartMs`
  - `gSleepAlarmCutoffActive`
- Runtime behavior:
  - On entering `AlertMode::SLEEP_CONTINUOUS`, timer starts.
  - If this mode lasts >= 5 seconds, buzzer is forced OFF.
  - Cutoff resets automatically when alert mode changes.
- Objective:
  - avoid overly long continuous alarm in real driving demo,
  - keep alert noticeable but safer and less intrusive.

### 15.3 Mobile App UI Stabilization (Premium + EN/VI + Responsive)
- Updated files:
  - `/Users/tolinh/drowsy/sleepy_app/lib/widgets/status_card.dart`
  - `/Users/tolinh/drowsy/sleepy_app/lib/widgets/connection_badge.dart`
  - `/Users/tolinh/drowsy/sleepy_app/lib/screens/home_screen.dart`
  - `/Users/tolinh/drowsy/sleepy_app/lib/screens/stats_screen.dart`
  - `/Users/tolinh/drowsy/sleepy_app/lib/screens/analytics_screen.dart`
  - `/Users/tolinh/drowsy/sleepy_app/lib/services/local_notification_service.dart`
- Changes:
  - Bilingual UI text for key operational elements:
    - driver state
    - connection state
    - alert popup
    - statistics and analytics labels
    - local push notification content
  - Fixed layout overflow on small screens:
    - constrained connection badge width + ellipsis
    - shortened chip labels
    - fitted state title
    - multi-line safe labels in analytics cells/distribution rows.

### 15.4 Validation Results After Update
- App validation:
  - `flutter analyze` -> No issues found.
  - `flutter test` -> All tests passed.
- ESP32 firmware validation:
  - `pio run` in active PlatformIO project -> SUCCESS.
- Pi Python syntax validation:
  - `python3 -m py_compile drowsy_edge.py esp32_wifi_bridge.py` -> pass.

### 15.5 Impact Summary
- Headless setup flow is now easier to operate at demo sites (better captive UX).
- Alert sound behavior is safer and more controlled (5s cutoff in sleep alarm mode).
- App display is more production-like and stable across device sizes.
- Data contract across Pi <-> ESP32 <-> App remains consistent (`driver/#` + metadata-aware parsing).
