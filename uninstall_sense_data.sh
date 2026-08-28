#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/opt/sense-data"
ETC_DIR="/etc/sense-data"
DATA_DIR="/var/lib/sense-data"
SERVICE_FILE="/etc/systemd/system/sense-data.service"
SERVICE_USER="sense-data"

if [[ $EUID -ne 0 ]]; then
  echo "Please run with sudo:"
  echo "  sudo bash $0"
  exit 1
fi

echo "============================================================"
echo " Sense Data Collector Uninstaller"
echo "============================================================"
echo
echo "This removes the Sense collector/API and systemd service."
echo "It does NOT change Homebridge or uninstall the Homebridge Sense plugin."
echo

PRESERVE_DB="yes"
if [[ -f "$DATA_DIR/sense.db" ]]; then
  read -r -p "Preserve the SQLite database? [Y/n]: " REPLY
  REPLY="${REPLY:-Y}"
  if [[ "$REPLY" =~ ^[Nn]$ ]]; then
    PRESERVE_DB="no"
  fi
fi

BACKUP_PATH=""
if [[ "$PRESERVE_DB" == "yes" && -f "$DATA_DIR/sense.db" ]]; then
  TS="$(date +%Y%m%d-%H%M%S)"
  BACKUP_DIR="/var/backups/sense-data"
  mkdir -p "$BACKUP_DIR"
  BACKUP_PATH="$BACKUP_DIR/sense-${TS}.db"
  cp -a "$DATA_DIR/sense.db" "$BACKUP_PATH"
  chmod 600 "$BACKUP_PATH"
  echo "Database backup created:"
  echo "  $BACKUP_PATH"
fi

if systemctl list-unit-files | grep -q '^sense-data\.service'; then
  systemctl disable --now sense-data.service || true
fi

rm -f "$SERVICE_FILE"
systemctl daemon-reload
systemctl reset-failed sense-data.service 2>/dev/null || true

rm -rf "$APP_DIR"
rm -rf "$ETC_DIR"
rm -rf "$DATA_DIR"

if id "$SERVICE_USER" >/dev/null 2>&1; then
  userdel "$SERVICE_USER" || true
fi

echo
echo "============================================================"
echo " Uninstall complete"
echo "============================================================"
if [[ -n "$BACKUP_PATH" ]]; then
  echo
  echo "Your SQLite history was preserved at:"
  echo "  $BACKUP_PATH"
fi
echo
echo "Homebridge was not modified."
