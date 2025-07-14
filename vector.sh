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

echo "Starting Vector..."
exec /usr/local/bin/vector --config /vector.yaml
