#!/bin/bash

set -e

# Ensure the supervisord.conf exists in the expected location
SUPERVISORD_CONF="/var/lib/better-stack/collector/supervisord.conf"
BOOTSTRAP_CONF="/bootstrap/supervisord.conf"

if [ ! -f "$SUPERVISORD_CONF" ]; then
  echo "Supervisord config not found at $SUPERVISORD_CONF, copying from bootstrap..."
  mkdir -p "$(dirname "$SUPERVISORD_CONF")"
  cp "$BOOTSTRAP_CONF" "$SUPERVISORD_CONF"
  echo "Copied bootstrap supervisord config to $SUPERVISORD_CONF"
fi

# Ensure HOSTNAME is set (use hostname command as fallback)
if [ -z "$HOSTNAME" ]; then
  HOSTNAME=$(hostname)
  export HOSTNAME
fi

# Ensure logs directories exist in volume at runtime
mkdir -p /var/lib/better-stack/logs/collector
mkdir -p /var/lib/better-stack/logs/ebpf

# Start supervisord
exec /usr/bin/supervisord -c "$SUPERVISORD_CONF"
