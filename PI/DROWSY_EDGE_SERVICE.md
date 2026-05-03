# Drowsy Edge Auto-Start Service (Raspberry Pi)

This service starts `drowsy_edge.py` automatically at boot after:
- `esp32-wifi-sync.service` is running
- WiFi interface has both SSID and IPv4 address

## Files
- `systemd/drowsy-edge.service`
- `install_drowsy_edge_service.sh`

## Install on Pi
Run inside project folder (`/home/pi/drowsy_project`):

```bash
cd /home/pi/drowsy_project
chmod +x install_drowsy_edge_service.sh

# Headless (no camera window)
PYTHON_BIN=/home/pi/drowsy_project/.venv/bin/python \
DROWSY_EDGE_ARGS="--no-preview --camera 0 --width 224 --height 168 --fps 30" \
PI_WIFI_INTERFACE=wlan0 \
WIFI_READY_TIMEOUT_S=90 \
MQTT_BROKER=127.0.0.1 \
MQTT_PORT=1883 \
./install_drowsy_edge_service.sh
```

## Auto open camera window on Pi desktop
Use the service as user `pi` with X11 display:

```bash
cd /home/pi/drowsy_project

PYTHON_BIN=/home/pi/drowsy_project/.venv/bin/python \
PREVIEW_ON_BOOT=1 \
SERVICE_USER=pi \
SERVICE_GROUP=pi \
DISPLAY_VAL=:0 \
XAUTHORITY_VAL=/home/pi/.Xauthority \
DISPLAY_WAIT_TIMEOUT_S=120 \
CAMERA_SOURCE=0 \
CAMERA_READY_TIMEOUT_S=20 \
PI_WIFI_INTERFACE=wlan0 \
WIFI_READY_TIMEOUT_S=90 \
MQTT_BROKER=127.0.0.1 \
MQTT_PORT=1883 \
MQTT_READY_TIMEOUT_S=120 \
./install_drowsy_edge_service.sh
```

## Status / Logs
```bash
systemctl is-enabled drowsy-edge.service
systemctl is-active drowsy-edge.service
sudo systemctl status drowsy-edge.service --no-pager
sudo journalctl -u drowsy-edge.service -f
```

## Stop/Disable
```bash
sudo systemctl stop drowsy-edge.service
sudo systemctl disable drowsy-edge.service
```

## Notes
- Internal Pi WiFi sync in `drowsy_edge.py` is forced OFF by service env:
  - `INTERNAL_WIFI_SYNC_ENABLED=0`
- WiFi sync remains handled by `esp32-wifi-sync.service`.
- If preview window does not show, check:
  - `sudo systemctl status drowsy-edge.service --no-pager`
  - `sudo journalctl -u drowsy-edge.service -n 120 --no-pager`
- If camera often times out:
  - find stable camera id: `ls -l /dev/v4l/by-id/`
  - reinstall with `CAMERA_SOURCE=/dev/v4l/by-id/<your-camera>`
- Service now waits in order:
  - X display ready (`DISPLAY` + `XAUTHORITY`)
  - WiFi ready (SSID + IP)
  - Camera device exists
  - MQTT broker socket reachable (`MQTT_BROKER:MQTT_PORT`)
