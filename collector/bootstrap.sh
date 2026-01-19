#!/bin/bash

set -euo pipefail

# Color output for better readability
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Validate required commands
log_info "Checking required commands..."
if ! command_exists curl; then
    log_error "curl is not installed"
    exit 1
fi

if ! command_exists jq; then
    log_error "jq is not installed"
    exit 1
fi

# Validate environment variables
log_info "Validating environment variables..."
if [ -z "$BASE_URL" ]; then
    log_error "BASE_URL environment variable is not set"
    exit 1
fi

if [ -z "$COLLECTOR_SECRET" ]; then
    log_error "COLLECTOR_SECRET environment variable is not set"
    exit 1
fi

log_info "BASE_URL: $BASE_URL"

# Check if already bootstrapped
MANIFEST_DIR="/var/lib/better-stack"
BOOTSTRAPPED_FILE="$MANIFEST_DIR/bootstrapped.txt"
BEYLA_UNPROVISIONED_FILE="$MANIFEST_DIR/beyla-unprovisioned.txt"
BEYLA_SOCKET="$MANIFEST_DIR/beyla-supervisor.sock"
BEYLA_SUPERVISOR_CONF="$MANIFEST_DIR/beyla/supervisord.conf"
COLLECTOR_SUPERVISOR_CONF="$MANIFEST_DIR/collector/supervisord.conf"

# sanity check: if bootstrap is restarted and bootstrap marker is found, it's likely supervisor restart failed
# perhaps a bad supervisord.conf file was sent - in any case, re-attempt bootstrapping on latest manifest
if [ -f "$BOOTSTRAPPED_FILE" ]; then
    log_info "Bootstrap marker found (bootstrapped on: $(cat "$BOOTSTRAPPED_FILE"))"

    # Verify bootstrap actually succeeded by checking if updater process exists
    log_info "Verifying bootstrap integrity..."
    if supervisorctl status | grep -q "updater"; then
        log_info "Bootstrap verified successfully (updater process found)"
        log_info "Exiting without changes."
        exit 0
    else
        log_warn "Bootstrap marker exists but updater process not found!"
        log_warn "Bootstrap may have failed previously. Re-bootstrapping..."

        # Remove markers to allow re-bootstrap
        rm -f "$BOOTSTRAPPED_FILE"
        rm -f "$BEYLA_UNPROVISIONED_FILE"

        log_info "Removed bootstrap markers, proceeding with bootstrap..."
    fi
fi

# Function to make API request with error handling
make_api_request() {
    local url="$1"
    local output_file="$2"
    local max_retries=3
    local retry_count=0
    local http_code

    while [ $retry_count -lt $max_retries ]; do
      echo "$url"
        if [ -n "$output_file" ]; then
            http_code=$(curl -s -w "%{http_code}" -o "$output_file" "$url")
        else
            http_code=$(curl -s -w "%{http_code}" "$url")
        fi

        if [ "$http_code" = "200" ]; then
            return 0
        elif [ "$http_code" = "401" ] || [ "$http_code" = "403" ]; then
            log_error "Authentication failed (HTTP $http_code). Check COLLECTOR_SECRET."
            exit 2
        elif [ "$http_code" = "404" ]; then
            log_error "Endpoint not found (HTTP $http_code). URL: $url"
            exit 3
        else
            retry_count=$((retry_count + 1))
            if [ $retry_count -lt $max_retries ]; then
                log_warn "Request failed (HTTP $http_code). Retrying ($retry_count/$max_retries)..."
                sleep 2
            else
                log_error "Request failed after $max_retries attempts (HTTP $http_code)"
                return 1
            fi
        fi
    done

    return 1
}

# Step 1: Get latest manifest version
log_info "Fetching latest manifest version..."
LATEST_MANIFEST_URL="$BASE_URL/api/collector/latest-manifest?collector_secret=$(printf %s "$COLLECTOR_SECRET" | jq -sRr @uri)"

TEMP_VERSION_FILE=$(mktemp)

# shellcheck disable=SC2064
trap "rm -f $TEMP_VERSION_FILE" EXIT

if ! make_api_request "$LATEST_MANIFEST_URL" "$TEMP_VERSION_FILE"; then
    log_error "Failed to fetch latest manifest version"
    exit 4
fi

MANIFEST_VERSION=$(jq -r '.version' "$TEMP_VERSION_FILE" 2>/dev/null)
if [ -z "$MANIFEST_VERSION" ] || [ "$MANIFEST_VERSION" = "null" ]; then
    log_error "Invalid response from latest-manifest endpoint"
    cat "$TEMP_VERSION_FILE"
    exit 5
fi

log_info "Latest manifest version: $MANIFEST_VERSION"

# Step 2: Download full manifest
log_info "Downloading manifest version $MANIFEST_VERSION..."
MANIFEST_URL="$BASE_URL/api/collector/manifest?collector_secret=$(printf %s "$COLLECTOR_SECRET" | jq -sRr @uri)&manifest_version=$MANIFEST_VERSION"

MANIFEST_FILE="$MANIFEST_DIR/manifest.json"

# Create directory if it doesn't exist
mkdir -p "$MANIFEST_DIR"

TEMP_MANIFEST=$(mktemp)
if ! make_api_request "$MANIFEST_URL" "$TEMP_MANIFEST"; then
    log_error "Failed to download manifest"
    rm -f "$TEMP_MANIFEST"
    exit 6
fi

# Validate manifest structure
MANIFEST_VERSION_CHECK=$(jq -r '.manifest_version' "$TEMP_MANIFEST" 2>/dev/null)
FILES_COUNT=$(jq -r '.files | length' "$TEMP_MANIFEST" 2>/dev/null)

if [ -z "$MANIFEST_VERSION_CHECK" ] || [ "$MANIFEST_VERSION_CHECK" = "null" ]; then
    log_error "Invalid manifest structure: missing manifest_version"
    rm -f "$TEMP_MANIFEST"
    exit 7
fi

if [ -z "$FILES_COUNT" ] || [ "$FILES_COUNT" = "null" ]; then
    log_error "Invalid manifest structure: missing or invalid files array"
    rm -f "$TEMP_MANIFEST"
    exit 8
fi

# Move to final location
mv "$TEMP_MANIFEST" "$MANIFEST_FILE"
log_info "Manifest saved to $MANIFEST_FILE (version: $MANIFEST_VERSION_CHECK, files: $FILES_COUNT)"

# Step 3: Process each file in manifest
log_info "Processing $FILES_COUNT files from manifest..."

for i in $(seq 0 $((FILES_COUNT - 1))); do
    FILE_PATH=$(jq -r ".files[$i].path" "$MANIFEST_FILE")
    CONTAINER=$(jq -r ".files[$i].container" "$MANIFEST_FILE")
    ACTIONS=$(jq -r ".files[$i].actions // [] | join(\",\")" "$MANIFEST_FILE")

    if [ "$FILE_PATH" = "null" ] || [ "$CONTAINER" = "null" ]; then
        log_warn "Skipping file $i: missing path or container"
        continue
    fi

    log_info "[$((i + 1))/$FILES_COUNT] Downloading: $CONTAINER/$FILE_PATH"

    # Construct destination path
    DEST_DIR="$MANIFEST_DIR/$CONTAINER/$(dirname "$FILE_PATH")"
    DEST_FILE="$MANIFEST_DIR/$CONTAINER/$FILE_PATH"

    # Create directory structure
    mkdir -p "$DEST_DIR"

    # Download file
    FILE_URL="$BASE_URL/api/collector/manifest-file?collector_secret=$(printf %s "$COLLECTOR_SECRET" | jq -sRr @uri)&manifest_version=$MANIFEST_VERSION&path=$(printf %s "$FILE_PATH" | jq -sRr @uri)&container=$(printf %s "$CONTAINER" | jq -sRr @uri)"

    TEMP_FILE=$(mktemp)
    if ! make_api_request "$FILE_URL" "$TEMP_FILE"; then
        log_error "Failed to download file: $CONTAINER/$FILE_PATH"
        rm -f "$TEMP_FILE"
        exit 9
    fi

    # Move to final location
    mv "$TEMP_FILE" "$DEST_FILE"

    # Apply actions
    if echo "$ACTIONS" | grep -q "make_executable"; then
        chmod +x "$DEST_FILE"
        log_info "  Made executable: $DEST_FILE"
    fi

    log_info "  Saved to: $DEST_FILE"
done

# Step 4: Download topology configuration (optional, with retries)
log_info "Downloading topology configuration..."
TOPOLOGY_URL="$BASE_URL/api/collector/configuration-file?collector_secret=$(printf %s "$COLLECTOR_SECRET" | jq -sRr @uri)&configuration_version=latest&file=topology.json"
TOPOLOGY_FILE="$MANIFEST_DIR/topology.json"
TOPOLOGY_MAX_ATTEMPTS=3
TOPOLOGY_ATTEMPT=1
TOPOLOGY_SUCCESS=false

while [ "$TOPOLOGY_ATTEMPT" -le "$TOPOLOGY_MAX_ATTEMPTS" ]; do
    TEMP_TOPOLOGY=$(mktemp)
    if make_api_request "$TOPOLOGY_URL" "$TEMP_TOPOLOGY"; then
        mv "$TEMP_TOPOLOGY" "$TOPOLOGY_FILE"
        log_info "Topology configuration saved to: $TOPOLOGY_FILE"
        TOPOLOGY_SUCCESS=true
        break
    else
        rm -f "$TEMP_TOPOLOGY"
        if [ "$TOPOLOGY_ATTEMPT" -lt "$TOPOLOGY_MAX_ATTEMPTS" ]; then
            log_warn "Failed to download topology configuration (attempt $TOPOLOGY_ATTEMPT/$TOPOLOGY_MAX_ATTEMPTS, retrying...)"
            sleep 2
        fi
        TOPOLOGY_ATTEMPT=$((TOPOLOGY_ATTEMPT + 1))
    fi
done

if [ "$TOPOLOGY_SUCCESS" = false ]; then
    log_warn "Failed to download topology configuration after $TOPOLOGY_MAX_ATTEMPTS attempts (continuing anyway)"
fi

log_info "Bootstrap completed successfully!"
log_info "Manifest version: $MANIFEST_VERSION"
log_info "Files downloaded: $FILES_COUNT"
log_info "Location: $MANIFEST_DIR"

# Wait for Beyla supervisor socket (up to 30 seconds)
WAIT_SECONDS=30
BEYLA_SOCKET_EXISTS=false

log_info "Waiting up to ${WAIT_SECONDS}s for Beyla supervisor socket..."
for i in $(seq 1 $WAIT_SECONDS); do
    if [ -S "$BEYLA_SOCKET" ]; then
        log_info "Beyla supervisor socket found after ${i}s"
        BEYLA_SOCKET_EXISTS=true
        break
    fi
    sleep 1
done

if [ "$BEYLA_SOCKET_EXISTS" = true ]; then
    # Socket exists - reload Beyla supervisor
    log_info "Reloading Beyla supervisor configuration..."
    supervisorctl -c "$BEYLA_SUPERVISOR_CONF" reread
    supervisorctl -c "$BEYLA_SUPERVISOR_CONF" update
else
    # Socket not found - mark as unprovisioned
    log_warn "Beyla supervisor socket not found after ${WAIT_SECONDS}s"
    log_warn "Marking Beyla as unprovisioned"
    date > "$BEYLA_UNPROVISIONED_FILE"
    log_info "Beyla unprovisioned marker written to: $BEYLA_UNPROVISIONED_FILE"
fi

# Mark bootstrap as completed
# XXX: it may still fail on supervisorctl commands, but if it does, the integrity check will re-bootstrap
date > "$BOOTSTRAPPED_FILE"
log_info "Bootstrap marker written to: $BOOTSTRAPPED_FILE"

# reload supervisord config and start processes as indicated by new config (overwriting bootstrap config)
log_info "Reloading local supervisor configuration..."
supervisorctl -c "$COLLECTOR_SUPERVISOR_CONF" reread
supervisorctl -c "$COLLECTOR_SUPERVISOR_CONF" update

exit 0
