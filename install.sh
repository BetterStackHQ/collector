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

# Optional domain/TLS and proxy port
TLS_DOMAIN="${TLS_DOMAIN:-}"
PROXY_PORT="${PROXY_PORT:-}"

# Validate TLS_DOMAIN/PROXY_PORT semantics
if [ -n "$TLS_DOMAIN" ]; then
    if [ -z "$PROXY_PORT" ]; then
        echo "Error: TLS_DOMAIN is set but PROXY_PORT is missing. Set PROXY_PORT to the upstream/proxy port (and it must not be 80)."
        exit 1
    fi
    if ! [[ "$PROXY_PORT" =~ ^[0-9]+$ ]]; then
        echo "Error: PROXY_PORT must be an integer."
        exit 1
    fi
    if [ "$PROXY_PORT" -eq 80 ]; then
        echo "Error: PROXY_PORT must not equal 80 when TLS_DOMAIN is set (port 80 is reserved for ACME HTTP-01)."
        exit 1
    fi
    # Check for conflicts with internal ports
    if [ "$PROXY_PORT" -eq 33000 ] || [ "$PROXY_PORT" -eq 34320 ] || [ "$PROXY_PORT" -eq 39090 ]; then
        echo "Error: PROXY_PORT cannot be 33000, 34320, or 39090 as these are internal collector ports."
        exit 1
    fi
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
    curl -sSL https://raw.githubusercontent.com/BetterStackHQ/collector/main/docker-compose.seccomp.yml \
        -o docker-compose.yml
    
    # Also download the seccomp profile
    curl -sSL https://raw.githubusercontent.com/BetterStackHQ/collector/main/collector-seccomp.json \
        -o collector-seccomp.json
else
    # For newer Docker versions, use the standard compose file
    curl -sSL https://raw.githubusercontent.com/BetterStackHQ/collector/main/docker-compose.yml \
        -o docker-compose.yml
fi

# Adjust Compose port exposure rules
# - Keep existing localhost bindings: 34320 and 33000
# - If PROXY_PORT present, add host mapping: ${PROXY_PORT}:${PROXY_PORT} (for upstream proxy in Vector)
# - If TLS_DOMAIN present, add port 80 for ACME HTTP-01

adjust_compose_ports() {
  local file="$1"
  local tmpfile
  tmpfile="$(mktemp)"
  awk -v add80="$TLS_DOMAIN" -v addport="$PROXY_PORT" '
    BEGIN { inserted=0 }
    {
      # Remove previously inserted install lines for idempotence
      if ($0 ~ /# install: (proxy port|acme http-01)/) { next }
      print $0
      # Append new mappings right after the 33000 mapping
      if ($0 ~ /127\.0\.0\.1:33000:33000/ && inserted==0) {
        if (addport != "") {
          print "      - \"" addport ":" addport "\" # install: proxy port"
        }
        if (add80 != "") {
          print "      - \"80:80\" # install: acme http-01"
        }
        inserted=1
      }
    }
  ' "$file" > "$tmpfile"
  mv "$tmpfile" "$file"
}

adjust_compose_ports docker-compose.yml

# Pull images first
COLLECTOR_SECRET="$COLLECTOR_SECRET" HOSTNAME="$HOSTNAME" TLS_DOMAIN="$TLS_DOMAIN" PROXY_PORT="$PROXY_PORT" \
    $COMPOSE_CMD -p better-stack-collector pull

# Run containers
COLLECTOR_SECRET="$COLLECTOR_SECRET" HOSTNAME="$HOSTNAME" TLS_DOMAIN="$TLS_DOMAIN" PROXY_PORT="$PROXY_PORT" \
    $COMPOSE_CMD -p better-stack-collector up -d
