#!/bin/bash
set -euo pipefail

# Run mdprobe to get instance metadata
echo "Getting instance metadata..."
METADATA_JSON=$(/usr/local/bin/mdprobe)

# Parse JSON and extract region and availability zone using jq
export REGION=$(echo "$METADATA_JSON" | jq -r '.Region // "unknown"')
export AZ=$(echo "$METADATA_JSON" | jq -r '.AvailabilityZone // "unknown"')

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

echo "Starting Vector..."
exec /usr/local/bin/vector --config /vector-config/current/\*.yaml --config /vector-config/current/kubernetes-discovery/\*.yaml
