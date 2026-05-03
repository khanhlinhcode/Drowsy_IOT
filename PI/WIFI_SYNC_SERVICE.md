# ESP32 WiFi Sync Daemon (Headless Demo)

This daemon lets Raspberry Pi always follow WiFi credentials sent from ESP32, even when `drowsy_edge.py` is not running.

## Files
- `esp32_wifi_bridge.py`
- `systemd/esp32-wifi-sync.service`
- `install_esp32_wifi_sync_service.sh`

## Install (auto-start on boot)
```bash
cd /home/pi/drowsy_project
chmod +x install_esp32_wifi_sync_service.sh esp32_wifi_bridge.py
PYTHON_BIN=/usr/bin/python3 ./install_esp32_wifi_sync_service.sh
```

## Prerequisites on Pi
- `python3`
- `nmcli` (NetworkManager CLI, required for automatic WiFi switching)
- Access to ESP32 serial device (for example `/dev/ttyUSB0`)

Script auto-fills current project path into systemd service, so it works on Pi paths like `/home/pi/drowsy_project`.

Optional override while installing:
```bash
ESP32_WIFI_SERIAL_PORT=/dev/ttyUSB0 \
AUTO_SERIAL_DISCOVERY=1 \
PI_WIFI_INTERFACE=wlan0 \
WIFI_REQUIRE_ESP32_TARGET=1 \
ESP32_TARGET_WAIT_GRACE_MS=18000 \
ESP32_TARGET_LOSS_GRACE_MS=45000 \
WIFI_CONNECT_WAIT_S=12 \
WIFI_CONNECT_TIMEOUT_S=20 \
WIFI_FAIL_RECOVER_AFTER=2 \
WIFI_FAIL_RECOVER_COOLDOWN_MS=12000 \
ESP32_SYNC_REQUEST_INTERVAL_MS=1800 \
MQTT_BROKER=127.0.0.1 \
MQTT_PORT=1883 \
./install_esp32_wifi_sync_service.sh
```

## Service control
```bash
sudo systemctl restart esp32-wifi-sync.service
sudo systemctl status esp32-wifi-sync.service
sudo journalctl -u esp32-wifi-sync.service -f
```

## Notes
- `drowsy_edge.py` now defaults to external WiFi sync daemon mode.
- With `WIFI_REQUIRE_ESP32_TARGET=1` (default), Pi disconnects non-ESP32 WiFi
  until it receives target SSID from ESP32.
- New auto-recovery logic retries fast and can reset WiFi stack (no Pi reboot)
  when connection attempts fail repeatedly.
- Bridge now sends active sync requests (`[PI_SYNC_REQ]`) if target SSID is missing,
  so booting Pi + ESP32 together does not require pressing `EN` on ESP32.
- To force old in-process sync (debug only), set:
```bash
export INTERNAL_WIFI_SYNC_ENABLED=1
```
