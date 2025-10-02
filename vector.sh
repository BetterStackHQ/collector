#!/bin/bash
set -euo pipefail

# Run mdprobe to get instance metadata
echo "Getting instance metadata..."
METADATA_JSON=$(/usr/bin/ruby /mdprobe/mdprobe.rb)

# Parse JSON and extract region and availability zone using jq
export REGION=$(echo "$METADATA_JSON" | jq -r '.region // "unknown"')
export AZ=$(echo "$METADATA_JSON" | jq -r '.availability_zone // "unknown"')

echo "Extracted metadata:"
echo "  REGION=${REGION}"
echo "  AZ=${AZ}"

# Tell host_metrics source to collect from host system
export PROCFS_ROOT="/host/proc"
export SYSFS_ROOT="/host/sys"

# Ensure enrichment directory exists
if [ ! -d "/enrichment" ]; then
    echo "Creating /enrichment directory..."
    mkdir -p /enrichment
fi

# Copy default enrichment files if they don't exist
if [ ! -f "/enrichment/databases.csv" ] && [ -f "/enrichment-defaults/databases.csv" ]; then
    echo "Copying default databases.csv to /enrichment..."
    cp /enrichment-defaults/databases.csv /enrichment/databases.csv
fi

if [ ! -f "/enrichment/docker-mappings.csv" ] && [ -f "/enrichment-defaults/docker-mappings.csv" ]; then
    echo "Copying default docker-mappings.csv to /enrichment..."
    cp /enrichment-defaults/docker-mappings.csv /enrichment/docker-mappings.csv
fi

# Validate config files exist and are readable
CONFIG_DIR="/vector-config/current"
if [ ! -d "$CONFIG_DIR" ]; then
    echo "ERROR: Config directory $CONFIG_DIR does not exist!"
    echo "Attempting to restore from last known good config..."
    if [ -d "/vector-config/latest-valid-upstream" ]; then
        mkdir -p "$CONFIG_DIR"
        cp -r /vector-config/latest-valid-upstream/* "$CONFIG_DIR/"
        echo "Restored configuration from latest-valid-upstream"
    else
        echo "FATAL: No valid configuration available"
        exit 1
    fi
fi

# Check if we have actual config files
CONFIG_COUNT=$(find "$CONFIG_DIR" -name "*.yaml" -type f 2>/dev/null | wc -l)
if [ "$CONFIG_COUNT" -eq 0 ]; then
    echo "ERROR: No YAML config files found in $CONFIG_DIR"
    echo "Vector cannot start without configuration"
    # Exit with 127 - "command not found" - indicates critical config missing
    exit 127
fi

echo "Found $CONFIG_COUNT config files in $CONFIG_DIR"
echo "Starting Vector..."
exec /usr/local/bin/vector --config "$CONFIG_DIR"/*.yaml --config "$CONFIG_DIR"/kubernetes-discovery/*.yaml
