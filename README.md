# sense_data

Sense Data Collector is a small Linux service that samples realtime whole-home and detected-device power data from a Sense account, stores it in SQLite, and exposes a local-only REST API.

The installer creates a dedicated `sense-data` system user, installs the application under `/opt/sense-data`, stores configuration under `/etc/sense-data`, stores data under `/var/lib/sense-data`, and runs the collector with systemd.

## What It Does

- Authenticates to the Sense API with email/password and optional TOTP MFA.
- Takes one short realtime sample at a configurable interval.
- Stores whole-home power, solar, voltage, frequency, and active device readings in SQLite.
- Exposes a read-only HTTP API bound to `127.0.0.1`.
- Runs automatically as `sense-data.service`.
- Leaves Homebridge and Homebridge configuration untouched.

## Requirements

- Debian or Ubuntu-style Linux host with `apt-get`.
- `sudo` or root access.
- `systemd`.
- A Sense account with access to at least one monitor.
- Network access from the host to Sense API and realtime websocket endpoints.

The installer installs these OS packages:

- `python3`
- `python3-venv`
- `ca-certificates`
- `curl`

The Python virtual environment installs:

- `websocket-client`
- `pyotp`

## Install

Run the installer on the target Linux host:

```bash
sudo bash install_sense_data.sh
```

The installer prompts for:

- Sense account email.
- Sense account password.
- Whether the account uses MFA/2FA.
- TOTP base32 secret, if MFA is enabled.
- Sampling interval in seconds, minimum `30`.
- Local API port, default `8787`.

After installation, the service starts automatically.

## Installed Paths

| Path | Purpose |
| --- | --- |
| `/opt/sense-data` | Application and Python virtual environment |
| `/etc/sense-data/sense-data.env` | Service configuration and Sense credentials |
| `/var/lib/sense-data/sense.db` | SQLite database |
| `/etc/systemd/system/sense-data.service` | systemd unit |

The environment file is owned by `root:sense-data` and is installed with mode `640`.

## Service Commands

Check service status:

```bash
sudo systemctl status sense-data
```

Follow logs:

```bash
sudo journalctl -u sense-data -f
```

Restart the service:

```bash
sudo systemctl restart sense-data
```

Stop the service:

```bash
sudo systemctl stop sense-data
```

## API

The API listens on `127.0.0.1` only. By default it uses port `8787`.

Health:

```bash
curl -s http://127.0.0.1:8787/health | python3 -m json.tool
```

Current sample:

```bash
curl -s http://127.0.0.1:8787/api/current | python3 -m json.tool
```

Known devices:

```bash
curl -s 'http://127.0.0.1:8787/api/devices?days=30' | python3 -m json.tool
```

Power history:

```bash
curl -s 'http://127.0.0.1:8787/api/history?limit=1000' | python3 -m json.tool
```

Device history:

```bash
curl -s 'http://127.0.0.1:8787/api/device/Central%20AC?days=30' | python3 -m json.tool
```

Top detected devices:

```bash
curl -s 'http://127.0.0.1:8787/api/top-devices?days=30' | python3 -m json.tool
```

Whole-home summary:

```bash
curl -s 'http://127.0.0.1:8787/api/summary?days=1' | python3 -m json.tool
```

## Data Model

The SQLite database contains two tables:

- `power_samples`: timestamped whole-home readings.
- `device_samples`: timestamped detected-device readings.

Energy estimates are calculated from the configured sampling interval. They are useful for trend comparisons inside this local dataset, but they are not a replacement for billing-grade meter data.

## Security Notes

- The service stores Sense credentials locally in `/etc/sense-data/sense-data.env`.
- The REST API intentionally binds to `127.0.0.1`; do not expose it directly to the internet.
- If remote access is needed, put an authenticated layer in front of it, such as an SSH tunnel, reverse proxy with authentication, or a separate trusted integration.
- The service is installed with a dedicated non-login user and systemd hardening options.

## Reinstall

Re-run the installer to update configuration or reinstall the service:

```bash
sudo bash install_sense_data.sh
```

If an existing `sense-data.service` is present, the installer stops it before replacing application files and restarting the service.

## Uninstall

Run:

```bash
sudo bash uninstall_sense_data.sh
```

If `/var/lib/sense-data/sense.db` exists, the uninstaller asks whether to preserve a backup. Backups are written to:

```text
/var/backups/sense-data/
```

The uninstaller removes:

- `/opt/sense-data`
- `/etc/sense-data`
- `/var/lib/sense-data`
- `/etc/systemd/system/sense-data.service`
- the `sense-data` system user, when possible

Homebridge is not modified.

## Limitations

- The installer targets Debian/Ubuntu-style systems that use `apt-get` and systemd.
- Python dependencies are installed from PyPI during installation.
- The collector uses Sense API behavior that may change outside this project.
- Only the first monitor returned by the Sense account is used.
