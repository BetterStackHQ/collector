#!/bin/bash
set -e

# Check Docker
if ! docker version &> /dev/null; then
    echo "Please install Docker"
    exit 1
fi

# Get Docker version
DOCKER_VERSION=$(docker version --format '{{.Server.Version}}' 2>/dev/null || docker version | grep -E 'Version:' | head -n1 | awk '{print $2}')

# Function to compare versions
version_lt() {
    # Returns 0 if $1 < $2, 1 otherwise
    # Handles versions like 20.10.9, 19.03.13, etc.
    local v1=$1
    local v2=$2
    
    # Convert to comparable format (e.g., 20.10.9 -> 200109)
    local v1_comparable=$(echo "$v1" | awk -F. '{printf "%d%02d%02d", $1, $2, $3}')
    local v2_comparable=$(echo "$v2" | awk -F. '{printf "%d%02d%02d", $1, $2, $3}')
    
    if [ "$v1_comparable" -lt "$v2_comparable" ]; then
        return 0
    else
        return 1
    fi
}

# Check if Docker version is less than 20.10.10
USE_SECCOMP=false
if version_lt "$DOCKER_VERSION" "20.10.10"; then
    USE_SECCOMP=true
    echo "Detected Docker version $DOCKER_VERSION (< 20.10.10), will use seccomp profile"
else
    echo "Detected Docker version $DOCKER_VERSION (>= 20.10.10)"
fi

# Check Docker Compose
if docker compose version &> /dev/null; then
    COMPOSE_CMD="docker compose"
elif docker-compose version &> /dev/null; then
    COMPOSE_CMD="docker-compose"
else
    echo "Please install Docker Compose"
    exit 1
fi

# Check COLLECTOR_SECRET
if [ -z "$COLLECTOR_SECRET" ]; then
    echo "Please set COLLECTOR_SECRET environment variable"
    exit 1
fi

# Set hostname if not provided
HOSTNAME="${HOSTNAME:-$(hostname)}"

# Create temporary directory and cd into it
TEMP_DIR=$(mktemp -d)
cd "$TEMP_DIR"

# Clean up on exit
trap "rm -rf $TEMP_DIR" EXIT

# Download appropriate compose file based on Docker version
if [ "$USE_SECCOMP" = true ]; then
    # For older Docker versions, use the seccomp-enabled compose file
    curl -sSL https://raw.githubusercontent.com/BetterStackHQ/collector/bfa84101dcba13f6835bc33cd443d1a6f76029e0/docker-compose.seccomp.yml \
        -o docker-compose.yml
    
    # Also download the seccomp profile
    curl -sSL https://raw.githubusercontent.com/BetterStackHQ/collector/bfa84101dcba13f6835bc33cd443d1a6f76029e0/collector-seccomp.json \
        -o collector-seccomp.json
else
    # For newer Docker versions, use the standard compose file
    curl -sSL https://raw.githubusercontent.com/BetterStackHQ/collector/bfa84101dcba13f6835bc33cd443d1a6f76029e0/docker-compose.yml \
        -o docker-compose.yml
fi

# Pull images first
COLLECTOR_SECRET="$COLLECTOR_SECRET" HOSTNAME="$HOSTNAME" \
    $COMPOSE_CMD -p better-stack-collector pull

# Run containers
COLLECTOR_SECRET="$COLLECTOR_SECRET" HOSTNAME="$HOSTNAME" \
    $COMPOSE_CMD -p better-stack-collector up -d