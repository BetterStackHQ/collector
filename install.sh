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
    COMPOSE_VERSION=$(docker compose version --short 2>/dev/null || docker compose version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
elif docker-compose version &> /dev/null; then
    COMPOSE_CMD="docker-compose"
    COMPOSE_VERSION=$(docker-compose version --short 2>/dev/null || docker-compose version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
else
    echo "Please install Docker Compose"
    exit 1
fi

# Check Docker Compose version is >= 1.25.0
MIN_COMPOSE_VERSION="1.25.0"
if version_lt "$COMPOSE_VERSION" "$MIN_COMPOSE_VERSION"; then
    echo "Error: Docker Compose version $COMPOSE_VERSION is too old. Minimum required version is $MIN_COMPOSE_VERSION"
    echo "Please upgrade Docker Compose: https://docs.docker.com/compose/install/"
    exit 1
fi
echo "Detected Docker Compose version $COMPOSE_VERSION (>= $MIN_COMPOSE_VERSION)"

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

# Set default values for environment variables
BASE_URL="${BASE_URL:-https://telemetry.betterstack.com}"
CLUSTER_COLLECTOR="${CLUSTER_COLLECTOR:-false}"
ENABLE_DOCKERPROBE="${ENABLE_DOCKERPROBE:-true}"

# Check if docker-compose.yml already exists
if [ -f "docker-compose.yml" ]; then
    echo "Error: docker-compose.yml already exists in the current directory"
    exit 1
fi

# Check if beyla.yaml already exists
if [ -f "beyla.yaml" ]; then
    echo "Error: beyla.yaml already exists in the current directory"
    exit 1
fi

# Check if collector-seccomp.json already exists (for older Docker versions)
if [ "$USE_SECCOMP" = true ] && [ -f "collector-seccomp.json" ]; then
    echo "Error: collector-seccomp.json already exists in the current directory"
    exit 1
fi

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

# Add beyla.yaml volume mount
add_beyla_volume() {
  local file="$1"
  local tmpfile
  tmpfile="$(mktemp)"
  awk '
    /^  beyla:/ {
      in_beyla=1
    }
    /^  [a-zA-Z0-9_-]+:/ && !/^  beyla:/ {
      in_beyla=0
    }
    /^[^ ]/ {
      in_beyla=0
    }
    {
      print $0
      # Add volume mount after the docker socket volume
      if (in_beyla && $0 ~ /\/var\/run\/docker\.sock:\/var\/run\/docker\.sock:ro/) {
        print "      # Custom beyla configuration"
        print "      - ./beyla.yaml:/etc/beyla/beyla.yaml:ro"
      }
    }
  ' "$file" > "$tmpfile"
  mv "$tmpfile" "$file"
}

add_beyla_volume docker-compose.yml

# Also download beyla.yaml for easier customization
echo "Downloading beyla.yaml configuration file..."
curl -sSL https://raw.githubusercontent.com/BetterStackHQ/collector/main/beyla.yaml \
    -o beyla.yaml

# Pull images first
COLLECTOR_SECRET="$COLLECTOR_SECRET" \
BASE_URL="$BASE_URL" \
CLUSTER_COLLECTOR="$CLUSTER_COLLECTOR" \
ENABLE_DOCKERPROBE="$ENABLE_DOCKERPROBE" \
HOSTNAME="$HOSTNAME" \
TLS_DOMAIN="$TLS_DOMAIN" \
PROXY_PORT="$PROXY_PORT" \
    $COMPOSE_CMD -p better-stack-collector pull

# Print success message
echo ""
echo "✅ Better Stack Collector configuration prepared successfully!"
echo ""
echo "📁 Created files:"
echo "   - docker-compose.yml"
echo "   - beyla.yaml (eBPF configuration)"
if [ "$USE_SECCOMP" = true ]; then
    echo "   - collector-seccomp.json (seccomp profile for older Docker)"
fi
echo ""
echo "📝 You can now modify these files as needed:"
echo "   - Edit beyla.yaml to customize eBPF monitoring (e.g., exclude specific ports)"
echo "   - Edit docker-compose.yml to add volume mounts or change configurations"
echo ""
echo "✨ To pull fresh pre-built images for both collector and beyla, run:"
echo "   COLLECTOR_SECRET=\"$COLLECTOR_SECRET\" BASE_URL=\"$BASE_URL\" CLUSTER_COLLECTOR=\"$CLUSTER_COLLECTOR\" \\"
echo "   ENABLE_DOCKERPROBE=\"$ENABLE_DOCKERPROBE\" HOSTNAME=\"$HOSTNAME\" TLS_DOMAIN=\"$TLS_DOMAIN\" PROXY_PORT=\"$PROXY_PORT\" \\"
echo "     $COMPOSE_CMD -p better-stack-collector pull"
echo ""
echo "🚀 To start the collector, run:"
echo "   COLLECTOR_SECRET=\"$COLLECTOR_SECRET\" BASE_URL=\"$BASE_URL\" CLUSTER_COLLECTOR=\"$CLUSTER_COLLECTOR\" \\"
echo "   ENABLE_DOCKERPROBE=\"$ENABLE_DOCKERPROBE\" HOSTNAME=\"$HOSTNAME\" TLS_DOMAIN=\"$TLS_DOMAIN\" PROXY_PORT=\"$PROXY_PORT\" \\"
echo "     $COMPOSE_CMD -p better-stack-collector up -d"
echo ""
echo "🛑 To stop the collector, run:"
echo "   COLLECTOR_SECRET=\"$COLLECTOR_SECRET\" BASE_URL=\"$BASE_URL\" CLUSTER_COLLECTOR=\"$CLUSTER_COLLECTOR\" \\"
echo "   ENABLE_DOCKERPROBE=\"$ENABLE_DOCKERPROBE\" HOSTNAME=\"$HOSTNAME\" TLS_DOMAIN=\"$TLS_DOMAIN\" PROXY_PORT=\"$PROXY_PORT\" \\"
echo "     $COMPOSE_CMD -p better-stack-collector down"
