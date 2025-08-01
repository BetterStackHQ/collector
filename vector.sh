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

# Ensure enrichment directory exists with dummy CSV if needed
if [ ! -d "/enrichment" ]; then
    echo "Creating /enrichment directory..."
    mkdir -p /enrichment
fi

# In case dockerprobe is disabled, create a dummy CSV file to avoid errors 
# Vector would otherwise throw on loading enrichment table
if [ ! -f "/enrichment/docker-mappings.csv" ]; then
    echo "Creating dummy docker-mappings.csv..."
    echo "pid,container_name,container_id,image_name" > /enrichment/docker-mappings.csv
fi

echo "Starting Vector..."
exec /usr/local/bin/vector --config /vector-config/current/\*.yaml --config /vector-config/current/kubernetes-discovery/\*.yaml
