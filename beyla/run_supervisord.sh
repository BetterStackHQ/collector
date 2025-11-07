#!/bin/bash

set -e

# Ensure the supervisord.conf exists in the expected location
SUPERVISORD_CONF="/var/lib/better-stack/beyla/supervisord.conf"
BOOTSTRAP_CONF="/bootstrap/supervisord.conf"

if [ ! -f "$SUPERVISORD_CONF" ]; then
  echo "Supervisord config not found at $SUPERVISORD_CONF, copying from bootstrap..."
  mkdir -p "$(dirname "$SUPERVISORD_CONF")"
  cp "$BOOTSTRAP_CONF" "$SUPERVISORD_CONF"
  echo "Copied bootstrap supervisord config to $SUPERVISORD_CONF"
fi

# Start supervisord
exec /usr/bin/supervisord -c "$SUPERVISORD_CONF"
