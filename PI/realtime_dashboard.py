from __future__ import annotations

import json
import logging
import threading
import time
from collections import deque
from typing import Any

from flask import Flask, jsonify, Response
import paho.mqtt.client as mqtt

STATUS_TOPIC = "driver/status"
META_TOPIC = "driver/status_meta"
ESP_TOPIC = "driver/esp32_telemetry"


def _mono_ms() -> int:
    return int(time.monotonic_ns() // 1_000_000)


class _DashboardStore:
    def __init__(self, metrics_file: str) -> None:
        self.metrics_file = metrics_file
        self.lock = threading.Lock()
        self.state = "ATTENTIVE"
        self.fatigue = 0
        self.latency_total = 0
        self.capture_fps = 0.0
        self.infer_fps = 0.0
        self.mqtt_status = "DOWN"
        self.driving = False
        self.last_update_ms = 0
        self.timeline: deque[dict[str, Any]] = deque(maxlen=240)
        self.fatigue_hist: deque[dict[str, Any]] = deque(maxlen=240)
        self.latency_hist: deque[dict[str, Any]] = deque(maxlen=240)

    def _append_hist(self, ts_ms: int) -> None:
        self.timeline.append({"t": ts_ms, "state": self.state})
        self.fatigue_hist.append({"t": ts_ms, "v": int(self.fatigue)})
        self.latency_hist.append({"t": ts_ms, "v": int(self.latency_total)})

    def update_from_meta(self, payload: dict[str, Any]) -> None:
        now_ms = _mono_ms()
        with self.lock:
            self.state = str(payload.get("status", self.state))
            self.fatigue = int(payload.get("fatigue", self.fatigue))
            lat = payload.get("latency", {}) if isinstance(payload.get("latency"), dict) else {}
            self.latency_total = int(lat.get("total", self.latency_total))
            bench = payload.get("bench", {}) if isinstance(payload.get("bench"), dict) else {}
            self.capture_fps = float(bench.get("capture_fps", self.capture_fps))
            self.infer_fps = float(bench.get("infer_fps", self.infer_fps))
            self.mqtt_status = "UP"
            self.last_update_ms = now_ms
            self._append_hist(now_ms)

    def update_from_esp(self, payload: dict[str, Any]) -> None:
        with self.lock:
            self.driving = bool(payload.get("driving", self.driving))
            self.latency_total = int(payload.get("latency_total", self.latency_total))

    def update_from_metrics_file(self) -> None:
        try:
            with open(self.metrics_file, "r", encoding="utf-8") as f:
                data = json.load(f)
        except Exception:
            return
        now_ms = _mono_ms()
        with self.lock:
            self.state = str(data.get("status", self.state))
            self.fatigue = int(data.get("fatigue", self.fatigue))
            self.capture_fps = float(data.get("capture_fps", self.capture_fps))
            self.infer_fps = float(data.get("infer_fps", self.infer_fps))
            self.mqtt_status = "UP" if bool(data.get("mqtt_connected", False)) else self.mqtt_status
            self.last_update_ms = now_ms

    def snapshot(self) -> dict[str, Any]:
        now_ms = _mono_ms()
        with self.lock:
            if (now_ms - self.last_update_ms) > 2500:
                self.mqtt_status = "DOWN"
            return {
                "state": self.state,
                "fatigue": int(self.fatigue),
                "latency_ms": int(self.latency_total),
                "capture_fps": round(self.capture_fps, 2),
                "infer_fps": round(self.infer_fps, 2),
                "mqtt_status": self.mqtt_status,
                "driving": bool(self.driving),
                "timeline": list(self.timeline),
                "fatigue_hist": list(self.fatigue_hist),
                "latency_hist": list(self.latency_hist),
                "ts_ms": now_ms,
            }


def _build_app(store: _DashboardStore) -> Flask:
    app = Flask(__name__)

    html = """
<!doctype html>
<html>
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>Drowsy Realtime Dashboard</title>
<style>
body { font-family: -apple-system, BlinkMacSystemFont, Segoe UI, sans-serif; margin:0; background:#091426; color:#e8f2ff; }
.grid { display:grid; gap:12px; padding:14px; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); }
.card { background: rgba(18,32,56,.75); border:1px solid rgba(130,170,220,.28); border-radius:14px; padding:12px; }
.kv { font-size:24px; font-weight:700; }
small { opacity:.7 }
canvas { width:100%; height:160px; background:#0e203a; border-radius:10px; }
</style>
</head>
<body>
  <div class="grid">
    <div class="card"><small>State</small><div id="state" class="kv">-</div></div>
    <div class="card"><small>Fatigue</small><div id="fatigue" class="kv">0%</div></div>
    <div class="card"><small>Latency</small><div id="latency" class="kv">0 ms</div></div>
    <div class="card"><small>Capture FPS</small><div id="capfps" class="kv">0</div></div>
    <div class="card"><small>Infer FPS</small><div id="infps" class="kv">0</div></div>
    <div class="card"><small>MQTT / Driving</small><div id="mqtt" class="kv">DOWN / false</div></div>
  </div>
  <div class="grid">
    <div class="card"><small>State Timeline</small><canvas id="timeline" width="900" height="180"></canvas></div>
    <div class="card"><small>Fatigue Graph</small><canvas id="fatigueGraph" width="900" height="180"></canvas></div>
    <div class="card"><small>Latency Graph</small><canvas id="latencyGraph" width="900" height="180"></canvas></div>
  </div>
<script>
function drawLine(canvasId, pts, maxY, color){
  const c = document.getElementById(canvasId); const ctx = c.getContext('2d');
  ctx.clearRect(0,0,c.width,c.height); ctx.strokeStyle=color; ctx.lineWidth=2; ctx.beginPath();
  if(!pts || pts.length===0){ctx.stroke(); return;}
  const n = pts.length; const h = c.height-20; const w = c.width-20;
  for(let i=0;i<n;i++){
    const x = 10 + (i/(Math.max(1,n-1)))*w;
    const y = 10 + h - (Math.max(0, Math.min(maxY, pts[i]))/maxY)*h;
    if(i===0) ctx.moveTo(x,y); else ctx.lineTo(x,y);
  }
  ctx.stroke();
}
function stateToNum(s){ if(s==='MICROSLEEP')return 3; if(s==='SLEEPY')return 2; if(s==='TIRED')return 1; return 0; }
async function tick(){
  const res = await fetch('/api/metrics', {cache:'no-store'}); const d = await res.json();
  document.getElementById('state').textContent = d.state;
  document.getElementById('fatigue').textContent = d.fatigue + '%';
  document.getElementById('latency').textContent = d.latency_ms + ' ms';
  document.getElementById('capfps').textContent = d.capture_fps;
  document.getElementById('infps').textContent = d.infer_fps;
  document.getElementById('mqtt').textContent = d.mqtt_status + ' / ' + d.driving;
  drawLine('timeline', (d.timeline||[]).map(x=>stateToNum(x.state)), 3, '#7ad3ff');
  drawLine('fatigueGraph', (d.fatigue_hist||[]).map(x=>x.v), 100, '#ffb357');
  drawLine('latencyGraph', (d.latency_hist||[]).map(x=>x.v), 600, '#6ef0a6');
}
setInterval(tick, 200); tick();
</script>
</body>
</html>
"""

    @app.get("/")
    def root() -> Response:
        return Response(html, mimetype="text/html")

    @app.get("/api/metrics")
    def api_metrics() -> Response:
        store.update_from_metrics_file()
        return jsonify(store.snapshot())

    return app


def start_dashboard_server(metrics_file: str, mqtt_host: str, mqtt_port: int, dashboard_port: int, log: logging.Logger) -> None:
    store = _DashboardStore(metrics_file=metrics_file)

    client = mqtt.Client(client_id="drowsy-dashboard")

    def on_connect(_c: mqtt.Client, _u: object, _f: dict, rc: int) -> None:
        if rc == 0:
            _c.subscribe(META_TOPIC, qos=0)
            _c.subscribe(ESP_TOPIC, qos=0)
            log.info("[MQTT] dashboard connected")

    def on_message(_c: mqtt.Client, _u: object, msg: mqtt.MQTTMessage) -> None:
        try:
            payload = json.loads(msg.payload.decode("utf-8", errors="ignore"))
        except Exception:
            return
        if msg.topic == META_TOPIC:
            store.update_from_meta(payload)
        elif msg.topic == ESP_TOPIC:
            store.update_from_esp(payload)

    client.on_connect = on_connect
    client.on_message = on_message
    try:
        client.connect_async(mqtt_host, mqtt_port, 10)
        client.loop_start()
    except Exception as exc:
        log.warning("Dashboard MQTT disabled: %s", exc)

    app = _build_app(store)

    def _run() -> None:
        log.info("[PIPELINE] dashboard=http://0.0.0.0:%d", dashboard_port)
        app.run(host="0.0.0.0", port=dashboard_port, debug=False, use_reloader=False, threaded=True)

    th = threading.Thread(target=_run, name="dashboard-server", daemon=True)
    th.start()
