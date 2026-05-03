#!/usr/bin/env python3
"""
Small public API server for drowsy demo.

Pi pushes status/alerts:
  POST /v1/ingest/status
  POST /v1/ingest/alert

App reads:
  GET  /v1/devices/<device_id>/latest
  GET  /v1/devices/<device_id>/events?limit=200
  GET  /healthz

Environment:
  EDGE_SERVER_HOST=0.0.0.0
  EDGE_SERVER_PORT=8787
  EDGE_SERVER_DB=./edge_data_server.db
  EDGE_SERVER_TOKEN=<optional shared token>
  EDGE_SERVER_CORS_ORIGIN=*
"""

from __future__ import annotations

import json
import os
import sqlite3
import threading
import time
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse


HOST = os.getenv("EDGE_SERVER_HOST", "0.0.0.0")
PORT = int(os.getenv("EDGE_SERVER_PORT", "8787"))
DB_PATH = os.getenv("EDGE_SERVER_DB", str(Path(__file__).with_name("edge_data_server.db")))
API_TOKEN = os.getenv("EDGE_SERVER_TOKEN", "").strip()
INGEST_TOKEN = os.getenv("EDGE_SERVER_INGEST_TOKEN", API_TOKEN).strip()
READ_TOKEN = os.getenv("EDGE_SERVER_READ_TOKEN", API_TOKEN).strip()
CORS_ORIGIN = os.getenv("EDGE_SERVER_CORS_ORIGIN", "*").strip() or "*"
MAX_BODY_BYTES = 256 * 1024


def _now_ms() -> int:
    return int(time.time() * 1000)


def _safe_int(v, default=0):
    try:
        return int(v)
    except Exception:
        return default


def _safe_bool(v):
    if isinstance(v, bool):
        return v
    if isinstance(v, (int, float)):
        return v != 0
    if isinstance(v, str):
        text = v.strip().lower()
        if text in ("1", "true", "yes", "on"):
            return True
        if text in ("0", "false", "no", "off"):
            return False
    return None


class Store:
    def __init__(self, db_path: str):
        self._db_path = db_path
        self._lock = threading.Lock()
        self._init_db()

    def _conn(self):
        conn = sqlite3.connect(self._db_path, timeout=10)
        conn.row_factory = sqlite3.Row
        return conn

    def _init_db(self):
        with self._conn() as conn:
            conn.executescript(
                """
                PRAGMA journal_mode=WAL;

                CREATE TABLE IF NOT EXISTS status_updates (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    device_id TEXT NOT NULL,
                    event_id TEXT,
                    ts_ms INTEGER NOT NULL,
                    received_ms INTEGER NOT NULL,
                    status TEXT NOT NULL,
                    status_raw TEXT,
                    signal INTEGER,
                    fatigue INTEGER,
                    armed INTEGER,
                    payload_json TEXT NOT NULL
                );

                CREATE TABLE IF NOT EXISTS alert_events (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    device_id TEXT NOT NULL,
                    event_id TEXT,
                    ts_ms INTEGER NOT NULL,
                    received_ms INTEGER NOT NULL,
                    event_type TEXT,
                    status_raw TEXT,
                    signal INTEGER,
                    fatigue INTEGER,
                    armed INTEGER,
                    payload_json TEXT NOT NULL
                );

                CREATE INDEX IF NOT EXISTS idx_status_device_ts
                ON status_updates(device_id, ts_ms DESC, id DESC);

                CREATE INDEX IF NOT EXISTS idx_alert_device_ts
                ON alert_events(device_id, ts_ms DESC, id DESC);
                """
            )

    def add_status(self, payload: dict):
        device_id = str(payload.get("device_id", "")).strip() or "unknown-device"
        ts_ms = _safe_int(payload.get("timestamp_ms") or payload.get("ts_ms") or payload.get("epoch_ms"), _now_ms())
        received_ms = _now_ms()
        status = str(payload.get("status", "")).strip() or "ATTENTIVE"
        status_raw = str(payload.get("status_raw", "")).strip() or status
        signal = payload.get("signal")
        fatigue = payload.get("fatigue")
        armed = payload.get("armed")
        event_id = str(payload.get("event_id", "")).strip() or f"status-{device_id}-{ts_ms}"

        row = {
            "device_id": device_id,
            "event_id": event_id,
            "timestamp_ms": ts_ms,
            "received_ms": received_ms,
            "status": status,
            "status_raw": status_raw,
            "signal": _safe_int(signal, 0) if signal is not None else None,
            "fatigue": _safe_int(fatigue, 0) if fatigue is not None else None,
            "armed": 1 if bool(armed) else 0 if armed is not None else None,
        }

        with self._lock, self._conn() as conn:
            conn.execute(
                """
                INSERT INTO status_updates (
                    device_id, event_id, ts_ms, received_ms,
                    status, status_raw, signal, fatigue, armed, payload_json
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    row["device_id"],
                    row["event_id"],
                    row["timestamp_ms"],
                    row["received_ms"],
                    row["status"],
                    row["status_raw"],
                    row["signal"],
                    row["fatigue"],
                    row["armed"],
                    json.dumps(payload, separators=(",", ":")),
                ),
            )
        return row

    def add_alert(self, payload: dict):
        device_id = str(payload.get("device_id", "")).strip() or "unknown-device"
        ts_ms = _safe_int(payload.get("timestamp_ms") or payload.get("ts_ms") or payload.get("epoch_ms"), _now_ms())
        received_ms = _now_ms()
        event_type = str(payload.get("event_type", "")).strip() or "DROWSY_ALERT"
        status_raw = str(payload.get("status_raw", "")).strip() or str(payload.get("status", "")).strip()
        signal = payload.get("signal")
        fatigue = payload.get("fatigue_score", payload.get("fatigue"))
        armed = payload.get("armed")
        event_id = str(payload.get("event_id", "")).strip() or f"alert-{device_id}-{ts_ms}"

        row = {
            "device_id": device_id,
            "event_id": event_id,
            "timestamp_ms": ts_ms,
            "received_ms": received_ms,
            "event_type": event_type,
            "status_raw": status_raw,
            "signal": _safe_int(signal, 0) if signal is not None else None,
            "fatigue": _safe_int(fatigue, 0) if fatigue is not None else None,
            "armed": 1 if bool(armed) else 0 if armed is not None else None,
        }

        with self._lock, self._conn() as conn:
            conn.execute(
                """
                INSERT INTO alert_events (
                    device_id, event_id, ts_ms, received_ms, event_type,
                    status_raw, signal, fatigue, armed, payload_json
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    row["device_id"],
                    row["event_id"],
                    row["timestamp_ms"],
                    row["received_ms"],
                    row["event_type"],
                    row["status_raw"],
                    row["signal"],
                    row["fatigue"],
                    row["armed"],
                    json.dumps(payload, separators=(",", ":")),
                ),
            )
        return row

    def latest_status(self, device_id: str):
        with self._lock, self._conn() as conn:
            row = conn.execute(
                """
                SELECT device_id, event_id, ts_ms, received_ms, status, status_raw,
                       signal, fatigue, armed, payload_json
                FROM status_updates
                WHERE device_id = ?
                ORDER BY ts_ms DESC, id DESC
                LIMIT 1
                """,
                (device_id,),
            ).fetchone()
        if row is None:
            return None
        payload = {}
        try:
            payload = json.loads(row["payload_json"] or "{}")
        except Exception:
            payload = {}
        status_raw_upper = str(row["status_raw"] or "").strip().upper()
        face_lock = _safe_bool(payload.get("face_lock"))
        face_in_frame = _safe_bool(payload.get("face_in_frame"))
        if face_in_frame is None:
            face_in_frame = status_raw_upper not in ("NO FACE", "NO_FACE")
        return {
            "device_id": row["device_id"],
            "event_id": row["event_id"],
            "timestamp_ms": row["ts_ms"],
            "received_ms": row["received_ms"],
            "runtime_ms": _safe_int(payload.get("runtime_ms") or payload.get("ts_ms"), 0),
            "status": row["status"],
            "status_raw": row["status_raw"],
            "signal": row["signal"],
            "fatigue": row["fatigue"],
            "armed": bool(row["armed"]) if row["armed"] is not None else None,
            "face_lock": face_lock,
            "face_in_frame": face_in_frame,
        }

    def latest_events(self, device_id: str, limit: int):
        limit = max(1, min(1000, _safe_int(limit, 200)))
        with self._lock, self._conn() as conn:
            rows = conn.execute(
                """
                SELECT ts_ms, kind, payload_json FROM (
                    SELECT ts_ms, 'status' AS kind, payload_json
                    FROM status_updates
                    WHERE device_id = ?
                    UNION ALL
                    SELECT ts_ms, 'alert' AS kind, payload_json
                    FROM alert_events
                    WHERE device_id = ?
                )
                ORDER BY ts_ms DESC
                LIMIT ?
                """,
                (device_id, device_id, limit),
            ).fetchall()
        out = []
        for r in rows:
            try:
                payload = json.loads(r["payload_json"])
            except Exception:
                payload = {}
            payload["kind"] = r["kind"]
            payload["timestamp_ms"] = _safe_int(payload.get("timestamp_ms") or payload.get("ts_ms"), r["ts_ms"])
            out.append(payload)
        return out


STORE = Store(DB_PATH)


class Handler(BaseHTTPRequestHandler):
    server_version = "edge-data-server/1.0"

    def _write_json(self, status_code: int, payload: dict):
        raw = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Access-Control-Allow-Origin", CORS_ORIGIN)
        self.send_header("Access-Control-Allow-Headers", "Content-Type, Authorization, X-API-Key")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.end_headers()
        self.wfile.write(raw)

    def _unauthorized(self):
        self._write_json(HTTPStatus.UNAUTHORIZED, {"ok": False, "error": "unauthorized"})

    def _check_auth(self, mode: str) -> bool:
        if mode == "ingest":
            required = INGEST_TOKEN
        else:
            required = READ_TOKEN
        if not required:
            return True
        auth = self.headers.get("Authorization", "").strip()
        x_key = self.headers.get("X-API-Key", "").strip()
        if x_key and x_key == required:
            return True
        if auth.lower().startswith("bearer "):
            token = auth[7:].strip()
            return token == required
        return False

    def _read_json_body(self):
        length = _safe_int(self.headers.get("Content-Length", "0"), 0)
        if length <= 0:
            return None, "empty_body"
        if length > MAX_BODY_BYTES:
            return None, "body_too_large"
        raw = self.rfile.read(length)
        try:
            data = json.loads(raw.decode("utf-8"))
        except Exception:
            return None, "invalid_json"
        if not isinstance(data, dict):
            return None, "json_object_required"
        return data, None

    def do_OPTIONS(self):
        self._write_json(HTTPStatus.OK, {"ok": True})

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path or ""
        parts = [p for p in path.split("/") if p]

        if path == "/healthz":
            self._write_json(
                HTTPStatus.OK,
                {"ok": True, "time_ms": _now_ms(), "service": "edge-data-server"},
            )
            return

        if len(parts) == 4 and parts[0] == "v1" and parts[1] == "devices" and parts[3] == "latest":
            if not self._check_auth("read"):
                self._unauthorized()
                return
            device_id = parts[2]
            latest = STORE.latest_status(device_id)
            self._write_json(HTTPStatus.OK, {"ok": True, "device_id": device_id, "data": latest})
            return

        if len(parts) == 4 and parts[0] == "v1" and parts[1] == "devices" and parts[3] == "events":
            if not self._check_auth("read"):
                self._unauthorized()
                return
            device_id = parts[2]
            q = parse_qs(parsed.query or "")
            limit = _safe_int((q.get("limit") or ["200"])[0], 200)
            events = STORE.latest_events(device_id, limit)
            self._write_json(HTTPStatus.OK, {"ok": True, "device_id": device_id, "events": events})
            return

        self._write_json(HTTPStatus.NOT_FOUND, {"ok": False, "error": "not_found"})

    def do_POST(self):
        parsed = urlparse(self.path)
        path = parsed.path or ""

        if not self._check_auth("ingest"):
            self._unauthorized()
            return

        payload, err = self._read_json_body()
        if err is not None:
            self._write_json(HTTPStatus.BAD_REQUEST, {"ok": False, "error": err})
            return

        if path == "/v1/ingest/status":
            row = STORE.add_status(payload)
            self._write_json(HTTPStatus.OK, {"ok": True, "data": row})
            return

        if path == "/v1/ingest/alert":
            row = STORE.add_alert(payload)
            self._write_json(HTTPStatus.OK, {"ok": True, "data": row})
            return

        self._write_json(HTTPStatus.NOT_FOUND, {"ok": False, "error": "not_found"})

    def log_message(self, fmt, *args):
        print(f"[HTTP] {self.address_string()} - {fmt % args}")


def main():
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"[EDGE_SERVER] listening on {HOST}:{PORT}")
    print(f"[EDGE_SERVER] db={DB_PATH}")
    print(f"[EDGE_SERVER] ingest_token={'ON' if bool(INGEST_TOKEN) else 'OFF'}")
    print(f"[EDGE_SERVER] read_token={'ON' if bool(READ_TOKEN) else 'OFF'}")
    try:
        server.serve_forever(poll_interval=0.3)
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        print("[EDGE_SERVER] stopped")


if __name__ == "__main__":
    main()
