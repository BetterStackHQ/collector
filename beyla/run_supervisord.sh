#!/bin/bash

set -e

# Ensure the supervisord.conf exists in the expected location
SUPERVISORD_CONF="/var/lib/better-stack/beyla/supervisord.conf"
BOOTSTRAP_CONF="/bootstrap/supervisord.conf"
HOSTNAME_FILE="/var/lib/better-stack/hostname.txt"

if [ ! -f "$SUPERVISORD_CONF" ]; then
  echo "Supervisord config not found at $SUPERVISORD_CONF, copying from bootstrap..."
  mkdir -p "$(dirname "$SUPERVISORD_CONF")"
  cp "$BOOTSTRAP_CONF" "$SUPERVISORD_CONF"
  echo "Copied bootstrap supervisord config to $SUPERVISORD_CONF"
fi

if [ -f "$HOSTNAME_FILE" ]; then
  HOSTNAME_VALUE=$(tr -d '[:space:]' < "$HOSTNAME_FILE")
  if [ -n "$HOSTNAME_VALUE" ]; then
    export HOSTNAME="$HOSTNAME_VALUE"
  fi
fi

# Start supervisord
exec /usr/bin/supervisord -c "$SUPERVISORD_CONF"
