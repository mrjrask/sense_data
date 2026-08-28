#!/usr/bin/env bash
set -euo pipefail

APP_NAME="sense-data"
APP_DIR="/opt/sense-data"
ETC_DIR="/etc/sense-data"
DATA_DIR="/var/lib/sense-data"
SERVICE_FILE="/etc/systemd/system/sense-data.service"
SERVICE_USER="sense-data"
VENV_DIR="$APP_DIR/venv"
PYTHON_APP="$APP_DIR/sense_data.py"
ENV_FILE="$ETC_DIR/sense-data.env"

if [[ $EUID -ne 0 ]]; then
  echo "Please run with sudo:"
  echo "  sudo bash $0"
  exit 1
fi

echo "============================================================"
echo " Sense Data Collector + Local REST API Installer"
echo "============================================================"
echo
echo "This installs a read-only Sense collector that:"
echo "  • takes one short realtime sample every 30 seconds"
echo "  • stores whole-home and per-device readings in SQLite"
echo "  • exposes a LOCAL-ONLY REST API on 127.0.0.1:8787"
echo "  • runs automatically via systemd"
echo
echo "It does NOT modify Homebridge or your Homebridge configuration."
echo

read -r -p "Sense account email: " SENSE_EMAIL
if [[ -z "$SENSE_EMAIL" ]]; then
  echo "Sense email is required."
  exit 1
fi

read -r -s -p "Sense account password: " SENSE_PASSWORD
echo
if [[ -z "$SENSE_PASSWORD" ]]; then
  echo "Sense password is required."
  exit 1
fi

read -r -p "Does this Sense account use MFA/2FA? [y/N]: " MFA_REPLY
MFA_REPLY="${MFA_REPLY:-N}"
SENSE_MFA_SECRET=""
if [[ "$MFA_REPLY" =~ ^[Yy]$ ]]; then
  read -r -s -p "TOTP base32 secret (not the rotating 6-digit code): " SENSE_MFA_SECRET
  echo
  if [[ -z "$SENSE_MFA_SECRET" ]]; then
    echo "MFA was selected but no TOTP secret was entered."
    exit 1
  fi
fi

read -r -p "Sampling interval in seconds [30]: " SAMPLE_INTERVAL
SAMPLE_INTERVAL="${SAMPLE_INTERVAL:-30}"
if ! [[ "$SAMPLE_INTERVAL" =~ ^[0-9]+$ ]] || (( SAMPLE_INTERVAL < 30 )); then
  echo "The sample interval must be an integer of at least 30 seconds."
  exit 1
fi

read -r -p "Local API port [8787]: " API_PORT
API_PORT="${API_PORT:-8787}"
if ! [[ "$API_PORT" =~ ^[0-9]+$ ]] || (( API_PORT < 1 || API_PORT > 65535 )); then
  echo "Invalid TCP port."
  exit 1
fi

echo
echo "Installing OS prerequisites..."
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y python3 python3-venv ca-certificates curl

if ! id "$SERVICE_USER" >/dev/null 2>&1; then
  useradd --system --home-dir "$DATA_DIR" --shell /usr/sbin/nologin "$SERVICE_USER"
fi

mkdir -p "$APP_DIR" "$ETC_DIR" "$DATA_DIR"
chown "$SERVICE_USER:$SERVICE_USER" "$DATA_DIR"
chmod 750 "$DATA_DIR"
chmod 755 "$APP_DIR"
chmod 750 "$ETC_DIR"

if systemctl list-unit-files | grep -q '^sense-data\.service'; then
  echo "Stopping existing sense-data service before reinstall..."
  systemctl stop sense-data.service || true
fi

echo "Creating Python virtual environment..."
python3 -m venv "$VENV_DIR"
"$VENV_DIR/bin/python" -m pip install --upgrade pip
"$VENV_DIR/bin/pip" install websocket-client pyotp

cat > "$PYTHON_APP" <<'PY'
#!/usr/bin/env python3

import json
import logging
import os
import signal
import sqlite3
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pyotp
import websocket

API_BASE = "https://api.sense.com/apiservice/api/v1/"
WS_BASE = "wss://clientrt.sense.com/monitors/"
DB_PATH = Path(os.environ.get("SENSE_DB_PATH", "/var/lib/sense-data/sense.db"))
EMAIL = os.environ["SENSE_EMAIL"]
PASSWORD = os.environ["SENSE_PASSWORD"]
MFA_ENABLED = os.environ.get("SENSE_MFA_ENABLED", "false").lower() == "true"
MFA_SECRET = os.environ.get("SENSE_MFA_SECRET", "").strip()
SAMPLE_INTERVAL = max(30, int(os.environ.get("SENSE_SAMPLE_INTERVAL", "30")))
API_HOST = os.environ.get("SENSE_API_HOST", "127.0.0.1")
API_PORT = int(os.environ.get("SENSE_API_PORT", "8787"))
DEVICE_MIN_WATTS = float(os.environ.get("SENSE_DEVICE_MIN_WATTS", "5"))

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)
log = logging.getLogger("sense-data")

stop_event = threading.Event()
db_lock = threading.Lock()


def utc_now_iso():
    return datetime.now(timezone.utc).isoformat()


def parse_timestamp(value):
    if not value:
        return None
    value = value.strip()
    if value.endswith("Z"):
        value = value[:-1] + "+00:00"
    dt = datetime.fromisoformat(value)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


class SenseClient:
    def __init__(self):
        self.access_token = None
        self.monitor_id = None
        self.auth_lock = threading.Lock()

    def _request(self, endpoint, method="GET", form=None, authenticated=True):
        headers = {
            "User-Agent": "sense-data-collector/1.0",
            "X-Sense-Protocol": "3",
            "cache-control": "no-cache",
        }
        data = None
        if form is not None:
            data = urllib.parse.urlencode(form).encode("utf-8")
            headers["Content-Type"] = "application/x-www-form-urlencoded"
            if method == "GET":
                method = "POST"
        if authenticated and self.access_token:
            headers["Authorization"] = f"Bearer {self.access_token}"

        req = urllib.request.Request(
            API_BASE + endpoint,
            data=data,
            headers=headers,
            method=method,
        )
        try:
            with urllib.request.urlopen(req, timeout=30) as response:
                raw = response.read().decode("utf-8")
                body = json.loads(raw) if raw else {}
                return response.status, body
        except urllib.error.HTTPError as exc:
            raw = exc.read().decode("utf-8", errors="replace")
            try:
                body = json.loads(raw) if raw else {}
            except json.JSONDecodeError:
                body = {"raw": raw}
            return exc.code, body

    def authenticate(self):
        with self.auth_lock:
            status, body = self._request(
                "authenticate",
                method="POST",
                form={"email": EMAIL, "password": PASSWORD},
                authenticated=False,
            )

            if 200 <= status < 300 and body.get("authorized"):
                self._apply_auth(body)
                return

            mfa_required = (
                body.get("status") == "mfa_required"
                or "Multi-factor" in str(body.get("error_reason", ""))
            )
            mfa_token = body.get("mfa_token")

            if mfa_required:
                if not MFA_ENABLED or not MFA_SECRET:
                    raise RuntimeError(
                        "Sense requires MFA. Re-run the installer and provide the TOTP base32 secret."
                    )
                if not mfa_token:
                    raise RuntimeError("Sense requested MFA but did not provide an MFA token.")

                totp = pyotp.TOTP(MFA_SECRET).now()
                status, body = self._request(
                    "authenticate/mfa",
                    method="POST",
                    form={"mfa_token": mfa_token, "totp": totp},
                    authenticated=False,
                )
                if 200 <= status < 300 and body.get("authorized"):
                    self._apply_auth(body)
                    return

            reason = body.get("error_reason") or body.get("status") or "invalid credentials"
            raise RuntimeError(f"Sense authentication failed (HTTP {status}): {reason}")

    def _apply_auth(self, body):
        token = body.get("access_token")
        monitors = body.get("monitors") or []
        if not token:
            raise RuntimeError("Sense authentication succeeded but no access token was returned.")
        if not monitors:
            raise RuntimeError("Sense authentication succeeded but no monitor was returned.")
        self.access_token = token
        self.monitor_id = str(monitors[0]["id"])
        log.info("Authenticated to Sense; monitor id %s", self.monitor_id)

    def ensure_auth(self):
        if not self.access_token or not self.monitor_id:
            self.authenticate()

    def validate_session(self):
        self.ensure_auth()
        status, body = self._request(f"app/monitors/{self.monitor_id}/status")
        if status == 401:
            log.info("Sense session expired; re-authenticating")
            self.access_token = None
            self.authenticate()
            status, body = self._request(f"app/monitors/{self.monitor_id}/status")
        if not 200 <= status < 300:
            reason = body.get("error_reason") or "request failed"
            raise RuntimeError(f"Sense session validation failed (HTTP {status}): {reason}")

    def realtime_sample(self):
        self.validate_session()

        url = f"{WS_BASE}{self.monitor_id}/realtimefeed?access_token={urllib.parse.quote(self.access_token)}"
        ws = None
        try:
            ws = websocket.create_connection(
                url,
                timeout=15,
                origin="https://home.sense.com",
            )
            deadline = time.time() + 15
            while time.time() < deadline:
                raw = ws.recv()
                if not raw:
                    continue
                if isinstance(raw, bytes):
                    raw = raw.decode("utf-8", errors="replace")
                try:
                    message = json.loads(raw)
                except json.JSONDecodeError:
                    continue
                if message.get("type") != "realtime_update":
                    continue

                payload = message.get("payload") or {}
                devices = []
                for device in payload.get("devices") or []:
                    name = device.get("name")
                    watts = device.get("w")
                    if isinstance(name, str) and isinstance(watts, (int, float)) and watts > DEVICE_MIN_WATTS:
                        devices.append({"name": name, "watts": round(float(watts), 2)})

                voltage = payload.get("voltage") or []
                return {
                    "timestamp": utc_now_iso(),
                    "total_watts": round(float(payload.get("w", payload.get("d_w", 0)) or 0), 2),
                    "solar_watts": round(float(payload.get("solar_w", 0) or 0), 2),
                    "voltage": voltage,
                    "frequency_hz": float(payload.get("hz", 0) or 0),
                    "devices": devices,
                }
            raise RuntimeError("Timed out waiting for a Sense realtime_update frame.")
        finally:
            if ws is not None:
                try:
                    ws.close()
                except Exception:
                    pass


def db_connect():
    conn = sqlite3.connect(DB_PATH, timeout=30)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA synchronous=NORMAL")
    conn.execute("PRAGMA foreign_keys=ON")
    return conn


def init_db():
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    with db_lock, db_connect() as conn:
        conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS power_samples (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp TEXT NOT NULL,
                total_watts REAL NOT NULL,
                solar_watts REAL NOT NULL DEFAULT 0,
                voltage_1 REAL,
                voltage_2 REAL,
                frequency_hz REAL
            );

            CREATE INDEX IF NOT EXISTS idx_power_samples_timestamp
                ON power_samples(timestamp);

            CREATE TABLE IF NOT EXISTS device_samples (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp TEXT NOT NULL,
                device_name TEXT NOT NULL,
                watts REAL NOT NULL
            );

            CREATE INDEX IF NOT EXISTS idx_device_samples_timestamp
                ON device_samples(timestamp);

            CREATE INDEX IF NOT EXISTS idx_device_samples_name_timestamp
                ON device_samples(device_name, timestamp);
            """
        )


def store_sample(sample):
    voltage = sample.get("voltage") or []
    v1 = voltage[0] if len(voltage) > 0 else None
    v2 = voltage[1] if len(voltage) > 1 else None

    with db_lock, db_connect() as conn:
        conn.execute(
            """
            INSERT INTO power_samples
                (timestamp, total_watts, solar_watts, voltage_1, voltage_2, frequency_hz)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            (
                sample["timestamp"],
                sample["total_watts"],
                sample["solar_watts"],
                v1,
                v2,
                sample["frequency_hz"],
            ),
        )
        conn.executemany(
            """
            INSERT INTO device_samples (timestamp, device_name, watts)
            VALUES (?, ?, ?)
            """,
            [
                (sample["timestamp"], device["name"], device["watts"])
                for device in sample["devices"]
            ],
        )


def rows_to_dicts(rows):
    return [dict(row) for row in rows]


def query_current():
    with db_lock, db_connect() as conn:
        power = conn.execute(
            "SELECT * FROM power_samples ORDER BY timestamp DESC LIMIT 1"
        ).fetchone()
        if not power:
            return None
        devices = conn.execute(
            """
            SELECT device_name, watts
            FROM device_samples
            WHERE timestamp = ?
            ORDER BY watts DESC
            """,
            (power["timestamp"],),
        ).fetchall()
    result = dict(power)
    result["devices"] = rows_to_dicts(devices)
    return result


def query_devices(days=30):
    cutoff = (datetime.now(timezone.utc) - timedelta(days=days)).isoformat()
    with db_lock, db_connect() as conn:
        rows = conn.execute(
            """
            SELECT
                device_name,
                COUNT(*) AS samples,
                ROUND(AVG(watts), 2) AS avg_active_watts,
                ROUND(MAX(watts), 2) AS max_watts,
                MIN(timestamp) AS first_seen,
                MAX(timestamp) AS last_seen
            FROM device_samples
            WHERE timestamp >= ?
            GROUP BY device_name
            ORDER BY avg_active_watts DESC
            """,
            (cutoff,),
        ).fetchall()
    return rows_to_dicts(rows)


def query_history(start=None, end=None, limit=10000):
    clauses = []
    params = []
    if start:
        clauses.append("timestamp >= ?")
        params.append(start.isoformat())
    if end:
        clauses.append("timestamp <= ?")
        params.append(end.isoformat())
    where = (" WHERE " + " AND ".join(clauses)) if clauses else ""
    sql = (
        "SELECT timestamp, total_watts, solar_watts, voltage_1, voltage_2, frequency_hz "
        f"FROM power_samples{where} ORDER BY timestamp ASC LIMIT ?"
    )
    params.append(limit)
    with db_lock, db_connect() as conn:
        rows = conn.execute(sql, params).fetchall()
    return rows_to_dicts(rows)


def query_device_history(name, days=30, limit=10000):
    cutoff = (datetime.now(timezone.utc) - timedelta(days=days)).isoformat()
    with db_lock, db_connect() as conn:
        rows = conn.execute(
            """
            SELECT timestamp, watts
            FROM device_samples
            WHERE device_name = ? AND timestamp >= ?
            ORDER BY timestamp ASC
            LIMIT ?
            """,
            (name, cutoff, limit),
        ).fetchall()
    return rows_to_dicts(rows)


def query_top_devices(days=30):
    cutoff = (datetime.now(timezone.utc) - timedelta(days=days)).isoformat()
    # This estimates kWh using the configured sampling interval. It is most useful
    # for comparing detected-device energy within this locally sampled dataset.
    hours_per_sample = SAMPLE_INTERVAL / 3600.0
    with db_lock, db_connect() as conn:
        rows = conn.execute(
            """
            SELECT
                device_name,
                COUNT(*) AS samples,
                ROUND(AVG(watts), 2) AS avg_active_watts,
                ROUND(MAX(watts), 2) AS max_watts,
                ROUND(SUM(watts) * ? / 1000.0, 4) AS estimated_kwh
            FROM device_samples
            WHERE timestamp >= ?
            GROUP BY device_name
            ORDER BY estimated_kwh DESC
            """,
            (hours_per_sample, cutoff),
        ).fetchall()
    return rows_to_dicts(rows)


def query_summary(days=1):
    cutoff = (datetime.now(timezone.utc) - timedelta(days=days)).isoformat()
    hours_per_sample = SAMPLE_INTERVAL / 3600.0
    with db_lock, db_connect() as conn:
        row = conn.execute(
            """
            SELECT
                COUNT(*) AS samples,
                MIN(timestamp) AS first_sample,
                MAX(timestamp) AS last_sample,
                ROUND(AVG(total_watts), 2) AS avg_watts,
                ROUND(MIN(total_watts), 2) AS min_watts,
                ROUND(MAX(total_watts), 2) AS max_watts,
                ROUND(SUM(total_watts) * ? / 1000.0, 4) AS estimated_kwh
            FROM power_samples
            WHERE timestamp >= ?
            """,
            (hours_per_sample, cutoff),
        ).fetchone()
    return dict(row)


class ApiHandler(BaseHTTPRequestHandler):
    server_version = "SenseData/1.0"

    def log_message(self, fmt, *args):
        log.info("API %s - %s", self.address_string(), fmt % args)

    def send_json(self, payload, status=200):
        body = json.dumps(payload, indent=2).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path.rstrip("/") or "/"
        qs = urllib.parse.parse_qs(parsed.query)

        try:
            if path == "/health":
                current = query_current()
                self.send_json({
                    "ok": current is not None,
                    "database": str(DB_PATH),
                    "sample_interval_seconds": SAMPLE_INTERVAL,
                    "latest_sample": current["timestamp"] if current else None,
                })
                return

            if path == "/api/current":
                current = query_current()
                if current is None:
                    self.send_json({"error": "No samples have been collected yet."}, 503)
                else:
                    self.send_json(current)
                return

            if path == "/api/devices":
                days = max(1, min(3650, int(qs.get("days", ["30"])[0])))
                self.send_json({"days": days, "devices": query_devices(days)})
                return

            if path == "/api/history":
                start = parse_timestamp(qs.get("start", [None])[0])
                end = parse_timestamp(qs.get("end", [None])[0])
                limit = max(1, min(50000, int(qs.get("limit", ["10000"])[0])))
                self.send_json({
                    "start": start.isoformat() if start else None,
                    "end": end.isoformat() if end else None,
                    "samples": query_history(start, end, limit),
                })
                return

            if path.startswith("/api/device/"):
                name = urllib.parse.unquote(path[len("/api/device/"):])
                days = max(1, min(3650, int(qs.get("days", ["30"])[0])))
                self.send_json({
                    "device": name,
                    "days": days,
                    "samples": query_device_history(name, days),
                })
                return

            if path == "/api/top-devices":
                days = max(1, min(3650, int(qs.get("days", ["30"])[0])))
                self.send_json({"days": days, "devices": query_top_devices(days)})
                return

            if path == "/api/summary":
                days = max(1, min(3650, int(qs.get("days", ["1"])[0])))
                self.send_json({"days": days, "summary": query_summary(days)})
                return

            self.send_json({
                "service": "sense-data",
                "endpoints": [
                    "/health",
                    "/api/current",
                    "/api/devices?days=30",
                    "/api/history?start=2026-08-01T00:00:00Z&end=2026-08-31T23:59:59Z",
                    "/api/device/Central%20AC?days=30",
                    "/api/top-devices?days=30",
                    "/api/summary?days=1",
                ],
            })
        except (ValueError, TypeError) as exc:
            self.send_json({"error": f"Invalid request: {exc}"}, 400)
        except Exception as exc:
            log.exception("API request failed")
            self.send_json({"error": str(exc)}, 500)


def collector_loop():
    client = SenseClient()
    consecutive_errors = 0

    while not stop_event.is_set():
        started = time.monotonic()
        try:
            sample = client.realtime_sample()
            store_sample(sample)
            consecutive_errors = 0
            log.info(
                "Stored sample: %.0f W, %d active device(s)",
                sample["total_watts"],
                len(sample["devices"]),
            )
        except Exception as exc:
            consecutive_errors += 1
            log.warning("Sense collection failed (%d): %s", consecutive_errors, exc)
            if consecutive_errors >= 3:
                client.access_token = None
                client.monitor_id = None

        elapsed = time.monotonic() - started
        wait_for = max(1, SAMPLE_INTERVAL - elapsed)
        stop_event.wait(wait_for)


def handle_signal(signum, frame):
    log.info("Received signal %s; shutting down", signum)
    stop_event.set()


def main():
    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)

    init_db()

    collector = threading.Thread(target=collector_loop, name="collector", daemon=True)
    collector.start()

    server = ThreadingHTTPServer((API_HOST, API_PORT), ApiHandler)
    server.timeout = 1
    log.info("Local API listening on http://%s:%d", API_HOST, API_PORT)

    try:
        while not stop_event.is_set():
            server.handle_request()
    finally:
        server.server_close()
        stop_event.set()
        collector.join(timeout=10)
        log.info("Sense Data stopped")


if __name__ == "__main__":
    main()
PY

chmod 755 "$PYTHON_APP"
chown root:root "$PYTHON_APP"

# Escape values for systemd EnvironmentFile double-quoted assignments.
escape_env() {
  printf "%s" "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

MFA_BOOL="false"
if [[ "$MFA_REPLY" =~ ^[Yy]$ ]]; then
  MFA_BOOL="true"
fi

cat > "$ENV_FILE" <<EOF
SENSE_EMAIL="$(escape_env "$SENSE_EMAIL")"
SENSE_PASSWORD="$(escape_env "$SENSE_PASSWORD")"
SENSE_MFA_ENABLED="$MFA_BOOL"
SENSE_MFA_SECRET="$(escape_env "$SENSE_MFA_SECRET")"
SENSE_SAMPLE_INTERVAL="$SAMPLE_INTERVAL"
SENSE_API_HOST="127.0.0.1"
SENSE_API_PORT="$API_PORT"
SENSE_DEVICE_MIN_WATTS="5"
SENSE_DB_PATH="$DATA_DIR/sense.db"
EOF

chown root:"$SERVICE_USER" "$ENV_FILE"
chmod 640 "$ENV_FILE"

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Sense Energy Data Collector and Local API
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_USER
EnvironmentFile=$ENV_FILE
WorkingDirectory=$DATA_DIR
ExecStart=$VENV_DIR/bin/python $PYTHON_APP
Restart=on-failure
RestartSec=15
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$DATA_DIR

[Install]
WantedBy=multi-user.target
EOF

chmod 644 "$SERVICE_FILE"

systemctl daemon-reload
systemctl enable --now sense-data.service

echo
echo "Waiting for the first sample..."
for _ in $(seq 1 35); do
  if curl -fsS "http://127.0.0.1:${API_PORT}/health" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

echo
echo "============================================================"
echo " Installation complete"
echo "============================================================"
echo
systemctl --no-pager --full status sense-data.service || true
echo
echo "Useful commands:"
echo
echo "  Service status:"
echo "    sudo systemctl status sense-data"
echo
echo "  Follow logs:"
echo "    sudo journalctl -u sense-data -f"
echo
echo "  Current power:"
echo "    curl -s http://127.0.0.1:${API_PORT}/api/current | python3 -m json.tool"
echo
echo "  Known devices:"
echo "    curl -s 'http://127.0.0.1:${API_PORT}/api/devices?days=30' | python3 -m json.tool"
echo
echo "  Top devices:"
echo "    curl -s 'http://127.0.0.1:${API_PORT}/api/top-devices?days=30' | python3 -m json.tool"
echo
echo "  Daily summary:"
echo "    curl -s 'http://127.0.0.1:${API_PORT}/api/summary?days=1' | python3 -m json.tool"
echo
echo "Database:"
echo "  $DATA_DIR/sense.db"
echo
echo "Credentials:"
echo "  $ENV_FILE"
echo "  (root + sense-data group only)"
echo
echo "IMPORTANT: The API intentionally listens only on 127.0.0.1."
echo "Do not expose port ${API_PORT} directly to the internet."
echo
echo "Next: verify /api/current, then we can add the secure ChatGPT-facing layer."
