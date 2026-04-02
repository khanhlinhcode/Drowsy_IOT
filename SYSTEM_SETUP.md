# Driver Drowsiness Detection Platform (Production Setup)

This repository now contains a complete end-to-end pipeline:

`Raspberry Pi AI -> MQTT Broker -> ESP32 alert node + Flutter iOS app`

- MQTT topic: `drowsy/status`
- Payload:

```json
{
  "state": "sleep | sleepy | normal",
  "confidence": 0.0,
  "time": 1711459200123
}
```

## 1) Raspberry Pi AI Publisher

File: `/Users/tolinh/drowsy/rpi_mqtt_publisher.py`

### Features implemented
- `paho-mqtt`
- QoS 1 and retained publish support
- State deduplication (publish only on state change)
- Debounce (`min_publish_interval_ms`, default 1000 ms)
- Exponential reconnect with capped backoff
- Thread-safe publish path
- Offline buffering (latest unsent state is flushed after reconnect)
- Structured logging
- Supports username/password + TLS

### Install dependency

```bash
python3 -m pip install --upgrade paho-mqtt
```

### Integration into existing AI loop

```python
import time
from rpi_mqtt_publisher import DrowsyMqttPublisher, MqttConfig, map_detector_label_to_state

publisher = DrowsyMqttPublisher(
    MqttConfig(
        broker="192.168.1.50",
        port=1883,
        topic="drowsy/status",
        client_id="rpi-drowsy-edge",
        qos=1,
        retain=True,
        min_publish_interval_ms=1000,
        enable_debug_logs=True,
    )
)
publisher.start()

try:
    while True:
        # detector_label from your model: e.g. "NORMAL", "SLEEPY", "DROWSY"
        detector_label = get_model_label()
        confidence_score = get_model_confidence()  # float 0..1

        state = map_detector_label_to_state(detector_label)
        publisher.publish_state(state=state, confidence=confidence_score)

        # your camera loop cadence
        time.sleep(0.03)
finally:
    publisher.stop()
```

## 2) MQTT Broker Setup

## A. Mosquitto on Raspberry Pi (LAN, port 1883)

### Install

```bash
sudo apt update
sudo apt install -y mosquitto mosquitto-clients
sudo systemctl enable --now mosquitto
sudo systemctl status mosquitto
```

### Configure LAN listener

```bash
sudo tee /etc/mosquitto/conf.d/drowsy_lan.conf >/dev/null <<'CONF'
listener 1883 0.0.0.0
allow_anonymous true
persistence true
persistence_location /var/lib/mosquitto/
CONF

sudo systemctl restart mosquitto
```

### Firewall

```bash
sudo ufw allow 1883/tcp
```

### Test publish/subscribe

```bash
# Terminal 1
mosquitto_sub -h 127.0.0.1 -p 1883 -t drowsy/status -v

# Terminal 2
mosquitto_pub -h 127.0.0.1 -p 1883 -t drowsy/status -q 1 -r \
  -m '{"state":"sleepy","confidence":0.78,"time":1711459200123}'
```

## B. Secure Mosquitto (username/password + TLS on 8883)

### 1) Create MQTT user

```bash
sudo mosquitto_passwd -c /etc/mosquitto/passwd drowsy_user
```

### 2) Create certificates (self-signed demo)

```bash
sudo mkdir -p /etc/mosquitto/certs
cd /etc/mosquitto/certs

# CA key/cert
sudo openssl genrsa -out ca.key 2048
sudo openssl req -x509 -new -nodes -key ca.key -sha256 -days 3650 \
  -out ca.crt -subj "/CN=drowsy-ca"

# Server key/csr/cert
sudo openssl genrsa -out server.key 2048
sudo openssl req -new -key server.key -out server.csr -subj "/CN=raspberrypi.local"
sudo openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out server.crt -days 3650 -sha256

sudo chown mosquitto:mosquitto /etc/mosquitto/certs/server.key
sudo chmod 600 /etc/mosquitto/certs/server.key
```

### 3) Secure config

```bash
sudo tee /etc/mosquitto/conf.d/drowsy_secure.conf >/dev/null <<'CONF'
listener 8883 0.0.0.0
allow_anonymous false
password_file /etc/mosquitto/passwd
cafile /etc/mosquitto/certs/ca.crt
certfile /etc/mosquitto/certs/server.crt
keyfile /etc/mosquitto/certs/server.key
persistence true
persistence_location /var/lib/mosquitto/
CONF

sudo systemctl restart mosquitto
```

### 4) Firewall for TLS

```bash
sudo ufw allow 8883/tcp
```

### 5) Secure test

```bash
# Terminal 1
mosquitto_sub -h 127.0.0.1 -p 8883 -t drowsy/status \
  --cafile /etc/mosquitto/certs/ca.crt -u drowsy_user -P 'YOUR_PASSWORD' -v

# Terminal 2
mosquitto_pub -h 127.0.0.1 -p 8883 -t drowsy/status -q 1 -r \
  --cafile /etc/mosquitto/certs/ca.crt -u drowsy_user -P 'YOUR_PASSWORD' \
  -m '{"state":"sleep","confidence":0.92,"time":1711459200123}'
```

## C. Public broker fallback (HiveMQ)

- Host: `broker.hivemq.com`
- Port: `1883`

```bash
# Terminal 1
mosquitto_sub -h broker.hivemq.com -p 1883 -t drowsy/status -v

# Terminal 2
mosquitto_pub -h broker.hivemq.com -p 1883 -t drowsy/status -q 1 -r \
  -m '{"state":"normal","confidence":0.81,"time":1711459200123}'
```

## 3) ESP32 Firmware

File: `/Users/tolinh/drowsy/esp32_drowsy_alert.ino`

### Implemented updates
- Subscribes to `drowsy/status`
- Parses JSON with `ArduinoJson`
- Mapping:
  - `sleep` -> danger mode, buzzer active
  - `sleepy` -> warning mode/LED
  - `normal` -> idle/green
- MQTT reconnect with backoff already in firmware
- Backward compatibility:
  - still accepts legacy integer payloads on status topic
  - still supports legacy topics already present in `subscribeCoreTopics()`

### Arduino libraries required
- `PubSubClient`
- `ArduinoJson`

## 4) Flutter iOS App

Project: `/Users/tolinh/drowsy/sleepy_app`

Architecture used:
- `lib/models/`
- `lib/services/`
- `lib/database/`
- `lib/providers/`
- `lib/screens/`
- `lib/widgets/`

### Key production features implemented
- Provider MVVM-like state management
- MQTT real-time service with reconnect/backoff and QoS support
- JSON validation (`state`, `confidence`, `time`)
- SQLite persistence with auto cleanup (max 2000 rows)
- UI updates in real time
- Sleep transition alert logic (`previous != sleep && current == sleep`)
- Haptic + iOS local notifications
- High-end UI: glassmorphism, gradient background, glow/pulse, smooth transitions
- Stats chart with state trend + confidence trend

### Install and run

```bash
cd /Users/tolinh/drowsy/sleepy_app
flutter pub get
flutter analyze
flutter test
```

### Run (LAN broker)

```bash
flutter run -d ios \
  --dart-define=MQTT_BROKER=192.168.1.50 \
  --dart-define=MQTT_PORT=1883 \
  --dart-define=MQTT_TOPIC=drowsy/status
```

### Run (secure TLS broker)

```bash
flutter run -d ios \
  --dart-define=MQTT_BROKER=192.168.1.50 \
  --dart-define=MQTT_PORT=8883 \
  --dart-define=MQTT_TOPIC=drowsy/status \
  --dart-define=MQTT_USERNAME=drowsy_user \
  --dart-define=MQTT_PASSWORD=YOUR_PASSWORD \
  --dart-define=MQTT_TLS=true \
  --dart-define=MQTT_TLS_ALLOW_INSECURE=true
```

`MQTT_TLS_ALLOW_INSECURE=true` is suitable for self-signed demo certs.
For production certificates, use trusted CA and keep this flag false.

### Run (public broker fallback)

```bash
flutter run -d ios \
  --dart-define=MQTT_BROKER=broker.hivemq.com \
  --dart-define=MQTT_PORT=1883 \
  --dart-define=MQTT_TOPIC=drowsy/status
```

## 5) End-to-End Smoke Test

1. Start broker (Mosquitto).
2. Flash ESP32 firmware and confirm serial logs show MQTT connected/subscribed.
3. Start Flutter app on iPhone.
4. Publish a sequence:

```bash
mosquitto_pub -h 127.0.0.1 -p 1883 -t drowsy/status -q 1 -r \
  -m '{"state":"normal","confidence":0.84,"time":1711459200123}'
mosquitto_pub -h 127.0.0.1 -p 1883 -t drowsy/status -q 1 -r \
  -m '{"state":"sleepy","confidence":0.88,"time":1711459202123}'
mosquitto_pub -h 127.0.0.1 -p 1883 -t drowsy/status -q 1 -r \
  -m '{"state":"sleep","confidence":0.95,"time":1711459204123}'
```

Expected:
- ESP32 warning/buzzer behavior updates by state.
- Flutter Home status updates instantly.
- Sleep transition triggers alert dialog + haptic + local notification.
- Stats chart and counters update.
- Data persists across app restart.

## 6) Hardening Checklist (Production)

- Disable anonymous MQTT access.
- Use TLS on 8883 and strong credentials.
- Restrict firewall source IPs if possible.
- Rotate credentials and certificates.
- Keep time synced with NTP on all devices.
- Monitor broker logs (`journalctl -u mosquitto -f`).
