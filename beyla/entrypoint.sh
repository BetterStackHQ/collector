#!/bin/sh

# Enable dockerprobe if ENABLE_DOCKERPROBE is set to true or 1
if [ "${ENABLE_DOCKERPROBE}" = "true" ] || [ "${ENABLE_DOCKERPROBE}" = "1" ]; then
    echo "Enabling dockerprobe (ENABLE_DOCKERPROBE=${ENABLE_DOCKERPROBE})"
    # Replace autostart=false with autostart=true for dockerprobe
    sed -i '/\[program:dockerprobe\]/,/^\[/ s/autostart=false/autostart=true/' /etc/supervisor/supervisord.conf
else
    echo "Dockerprobe disabled (ENABLE_DOCKERPROBE=${ENABLE_DOCKERPROBE})"
fi

# Start supervisord
exec /usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf