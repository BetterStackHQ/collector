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

# Optional proxy port and TLS indicator
PROXY_PORT="${PROXY_PORT:-}"
USE_TLS="${USE_TLS:-}"

# Optional custom host mount paths (comma-separated)
MOUNT_HOST_PATHS="${MOUNT_HOST_PATHS:-}"
COLLECT_OTEL_HTTP_PORT="${COLLECT_OTEL_HTTP_PORT:-}"
COLLECT_OTEL_GRPC_PORT="${COLLECT_OTEL_GRPC_PORT:-}"

# Validate PROXY_PORT if set
if [ -n "$PROXY_PORT" ]; then
    if ! [[ "$PROXY_PORT" =~ ^[0-9]+$ ]]; then
        echo "Error: PROXY_PORT must be an integer."
        exit 1
    fi
    # Check for conflicts with internal ports
    if [ "$PROXY_PORT" -eq 33000 ] || [ "$PROXY_PORT" -eq 34320 ] || [ "$PROXY_PORT" -eq 39090 ]; then
        echo "Error: PROXY_PORT cannot be 33000, 34320, or 39090 as these are internal collector ports."
        exit 1
    fi
    # If USE_TLS is set and PROXY_PORT is 80, that's a conflict
    if [ -n "$USE_TLS" ] && [ "$PROXY_PORT" -eq 80 ]; then
        echo "Error: PROXY_PORT cannot be 80 when USE_TLS is set (port 80 is reserved for ACME HTTP-01)."
        exit 1
    fi
fi

# Set hostname if not provided (use empty string HOSTNAME="" to trigger runtime detection via uts:host)
if [ -z "${HOSTNAME+x}" ]; then
    HOSTNAME=$(hostname)
fi

# Set default values for environment variables
BASE_URL="${BASE_URL:-https://telemetry.betterstack.com}"
CLUSTER_COLLECTOR="${CLUSTER_COLLECTOR:-false}"
ENABLE_DOCKERPROBE="${ENABLE_DOCKERPROBE:-true}"

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
# - Adds ports section to collector service (inserted before volumes section)
# - If PROXY_PORT present, add host mapping: ${PROXY_PORT}:${PROXY_PORT} (for upstream proxy in Vector)
# - Add port 80 for ACME validation when PROXY_PORT==443 or USE_TLS is set (and PROXY_PORT!=80)

adjust_compose_ports() {
  local file="$1"
  local tmpfile
  tmpfile="$(mktemp)"

  local bind80=""
  if [ "$PROXY_PORT" = "443" ] || ([ -n "$USE_TLS" ] && [ "$PROXY_PORT" != "80" ]); then
    bind80="yes"
  fi

  awk -v addport="$PROXY_PORT" -v add80="$bind80" -v otel_http="$COLLECT_OTEL_HTTP_PORT" -v otel_grpc="$COLLECT_OTEL_GRPC_PORT" '
    BEGIN { inserted=0; in_collector=0 }
    {
      if ($0 ~ /# install: (proxy port|acme http-01|ports section|otel port)/) { next }
      if ($0 ~ /^[[:space:]]*ports:[[:space:]]*$/ && in_collector==1) { next }

      if ($0 ~ /^  collector:[[:space:]]*$/) {
        in_collector=1
      }
      if ($0 ~ /^  [a-z_-]+:[[:space:]]*$/ && $0 !~ /collector:/) {
        in_collector=0
      }

      if (in_collector==1 && inserted==0 && $0 ~ /^[[:space:]]*volumes:[[:space:]]*$/) {
        if (addport != "" || add80 != "" || otel_http != "" || otel_grpc != "") {
          print "    ports: # install: ports section"
          if (addport != "") {
            print "      - \"" addport ":" addport "\" # install: proxy port"
          }
          if (add80 != "") {
            print "      - \"80:80\" # install: acme http-01"
          }
          if (otel_http != "") {
            print "      - \"" otel_http ":" otel_http "\" # install: otel port"
          }
          if (otel_grpc != "") {
            print "      - \"" otel_grpc ":" otel_grpc "\" # install: otel port"
          }
        }
        inserted=1
      }

      print $0
    }
  ' "$file" > "$tmpfile"
  mv "$tmpfile" "$file"
}

adjust_image_tag() {
  local file="$1"
  local tag="$2"
  local tmpfile
  tmpfile="$(mktemp)"

  sed "s/:latest/:${tag}/g" "$file" > "$tmpfile"
  mv "$tmpfile" "$file"
}

# Adjust volume mounts based on MOUNT_HOST_PATHS environment variable
# If MOUNT_HOST_PATHS is set, replace the default /:/host:ro mount with specific paths
adjust_compose_volumes() {
  local file="$1"
  local tmpfile
  tmpfile="$(mktemp)"
  local mount_tmpfile
  mount_tmpfile="$(mktemp)"

  if [ -n "$MOUNT_HOST_PATHS" ]; then
    # Parse comma-separated paths and write to temporary file
    IFS=',' read -ra PATHS <<< "$MOUNT_HOST_PATHS"
    for path in "${PATHS[@]}"; do
      # Trim whitespace
      path=$(echo "$path" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      # Skip empty paths
      if [ -n "$path" ]; then
        # Remove trailing slash if present
        path="${path%/}"
        echo "      - ${path}:/host${path}:ro" >> "$mount_tmpfile"
      fi
    done

    # Replace the /:/host:ro line with custom mount lines from file
    awk -v mounts_file="$mount_tmpfile" '
      {
        # Replace the /:/host:ro mount with custom paths
        if ($0 ~ /^[[:space:]]*- \/:\/host:ro[[:space:]]*$/) {
          while ((getline line < mounts_file) > 0) {
            print line
          }
          close(mounts_file)
        } else {
          print $0
        }
      }
    ' "$file" > "$tmpfile"
    mv "$tmpfile" "$file"
    rm -f "$mount_tmpfile"
  fi
}

docker_v1_compatibility() {
  local file="$1"
  local tmpfile cleaned
  tmpfile="$(mktemp)"
  cleaned="$(mktemp)"

  awk '
    BEGIN { in_build = 0; build_indent = 0 }
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*uts:[[:space:]]/ { next }
    {
      if ($0 ~ /^[[:space:]]*build:[[:space:]]*$/) {
        match($0, /^[[:space:]]*/)
        build_indent = RLENGTH
        in_build = 1
        next
      }

      if (in_build) {
        match($0, /^[[:space:]]*/)
        current_indent = RLENGTH

        if (current_indent > build_indent) {
          next
        } else {
          in_build = 0
        }
      }

      sub(/ #[[:space:]].*$/, "")
      sub(/[[:space:]]+$/, "")
      print
    }
  ' "$file" > "$cleaned"

  if [ "$(sed -n '1p' "$cleaned")" != 'version: "2.4"' ]; then
    {
      echo 'version: "2.4"'
      cat "$cleaned"
    } > "$tmpfile"
  else
    cat "$cleaned" > "$tmpfile"
  fi

  mv "$tmpfile" "$file"
  rm -f "$cleaned"
}

adjust_compose_ports docker-compose.yml
adjust_compose_volumes docker-compose.yml

# Replace :latest tag if IMAGE_TAG is set
if [ -n "$IMAGE_TAG" ]; then
    echo "Replacing :latest with :$IMAGE_TAG in compose file"
    adjust_image_tag docker-compose.yml "$IMAGE_TAG"
fi

if [ "$COMPOSE_CMD" = "docker-compose" ]; then
    docker_v1_compatibility docker-compose.yml
fi

# Pull images first
COLLECTOR_SECRET="$COLLECTOR_SECRET" \
BASE_URL="$BASE_URL" \
CLUSTER_COLLECTOR="$CLUSTER_COLLECTOR" \
ENABLE_DOCKERPROBE="$ENABLE_DOCKERPROBE" \
HOSTNAME="$HOSTNAME" \
PROXY_PORT="$PROXY_PORT" \
COLLECT_OTEL_HTTP_PORT="$COLLECT_OTEL_HTTP_PORT" \
COLLECT_OTEL_GRPC_PORT="$COLLECT_OTEL_GRPC_PORT" \
    $COMPOSE_CMD -p better-stack-collector pull

if [ "$COMPOSE_CMD" = "docker-compose" ]; then
    # On docker-compose v1, try to stop and remove the container first with a 90s grace period
    # This is a workaround for a bug in docker-compose v1 where the container stop grace period is not respected
    $COMPOSE_CMD -p better-stack-collector stop -t 90 || true
fi

# Run containers
COLLECTOR_SECRET="$COLLECTOR_SECRET" \
BASE_URL="$BASE_URL" \
CLUSTER_COLLECTOR="$CLUSTER_COLLECTOR" \
ENABLE_DOCKERPROBE="$ENABLE_DOCKERPROBE" \
HOSTNAME="$HOSTNAME" \
PROXY_PORT="$PROXY_PORT" \
COLLECT_OTEL_HTTP_PORT="$COLLECT_OTEL_HTTP_PORT" \
COLLECT_OTEL_GRPC_PORT="$COLLECT_OTEL_GRPC_PORT" \
    $COMPOSE_CMD -p better-stack-collector up -d --no-build
