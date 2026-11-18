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

# Optional custom host mount paths (comma-separated)
MOUNT_HOST_PATHS="${MOUNT_HOST_PATHS:-}"
COLLECT_OTEL_HTTP_PORT="${COLLECT_OTEL_HTTP_PORT:-}"
COLLECT_OTEL_GRPC_PORT="${COLLECT_OTEL_GRPC_PORT:-}"

# Set hostname if not provided (use empty string HOSTNAME="" to trigger runtime detection via uts:host)
if [ -z "${HOSTNAME+x}" ]; then
    HOSTNAME=$(hostname)
fi

# Set default values for environment variables
BASE_URL="${BASE_URL:-https://telemetry.betterstack.com}"
CLUSTER_COLLECTOR="${CLUSTER_COLLECTOR:-false}"
ENABLE_DOCKERPROBE="${ENABLE_DOCKERPROBE:-true}"

# Check if collector is already running via Docker Swarm
SWARM_CONTAINER=$(docker ps --filter "name=better-stack_collector" --format '{{.Names}}' 2>/dev/null || true)
if [ -n "$SWARM_CONTAINER" ]; then
    echo "Error: Better Stack collector is already running via Docker Swarm ($SWARM_CONTAINER)."
    echo "Please uninstall the Swarm deployment first, or use deploy-to-swarm.sh to manage it."
    exit 1
fi

# Warn about existing data directory
COLLECTOR_DATA_DIR="/var/lib/better-stack"
if [ -d "$COLLECTOR_DATA_DIR" ]; then
    echo "WARNING: $COLLECTOR_DATA_DIR already exists from a previous installation."
    echo "This is expected during upgrades. If you're fully reinstalling the collector, delete the directory first:"
    echo "  rm -rf $COLLECTOR_DATA_DIR"
fi

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
# - If OTel ports are set, add host mappings for them

adjust_compose_ports() {
  local file="$1"
  local tmpfile
  tmpfile="$(mktemp)"

  awk -v otel_http="$COLLECT_OTEL_HTTP_PORT" -v otel_grpc="$COLLECT_OTEL_GRPC_PORT" '
    BEGIN { inserted=0; in_collector=0 }
    {
      if ($0 ~ /# install: (ports section|otel port)/) { next }
      if ($0 ~ /^[[:space:]]*ports:[[:space:]]*$/ && in_collector==1) { next }

      if ($0 ~ /^  collector:[[:space:]]*$/) {
        in_collector=1
      }
      if ($0 ~ /^  [a-z_-]+:[[:space:]]*$/ && $0 !~ /collector:/) {
        in_collector=0
      }

      if (in_collector==1 && inserted==0 && $0 ~ /^[[:space:]]*volumes:[[:space:]]*$/) {
        if (otel_http != "" || otel_grpc != "") {
          print "    ports: # install: ports section"
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

# Docker rejects the whole compose file when a container asks for more CPUs than the host has,
# so a limit above the host's CPU count is lowered to that count.
adjust_compose_cpus() {
  local file="$1"
  local host_cpus
  # The Docker daemon's own count is the one it checks the limit against.
  host_cpus="$(docker info --format '{{.NCPU}}' 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || true)"
  case "$host_cpus" in
    ''|*[!0-9]*) return 0 ;;
  esac
  local tmpfile
  tmpfile="$(mktemp)"
  awk -v max="$host_cpus" '
    /^[ \t]*cpus:[ \t]*[0-9.]+[ \t]*$/ {
      split($0, parts, "cpus:")
      if (parts[2] + 0 > max + 0) {
        print parts[1] "cpus: " max ".0"
        next
      }
    }
    { print }
  ' "$file" > "$tmpfile"
  mv "$tmpfile" "$file"
}

# A host with an IPv6 default route and no IPv4 one can reach Better Stack over IPv6 only
ipv6_only_host() {
  command -v ip > /dev/null 2>&1 || return 1
  [ -z "$(ip -4 route show default 2>/dev/null)" ] && [ -n "$(ip -6 route show default 2>/dev/null)" ]
}

# The collector container sits on the Compose default network, which Docker creates without IPv6
enable_compose_ipv6() {
  local file="$1"

  printf '\nnetworks:\n  default:\n    enable_ipv6: true\n' >> "$file"
}

# Prints the interface whose IPv6 default route the kernel keeps alive from router advertisements, if any.
# Docker turns on IPv6 forwarding for an IPv6 network, and the kernel then drops such a route unless accept_ra is 2.
kernel_ra_default_route_device() {
  local dev

  for dev in $(ip -6 route show default 2>/dev/null | awk '{
    dev = ""; ra = 0
    for (i = 1; i < NF; i++) {
      if ($i == "dev") dev = $(i + 1)
      if ($i == "proto" && $(i + 1) == "ra") ra = 1
    }
    if (ra && dev != "") print dev
  }' | sort -u); do
    if [ "$(cat "/proc/sys/net/ipv6/conf/$dev/accept_ra" 2>/dev/null)" = "1" ] &&
       [ "$(cat "/proc/sys/net/ipv6/conf/$dev/forwarding" 2>/dev/null)" = "0" ]; then
      echo "$dev"
      return 0
    fi
  done
}

# Prints the containers on the collector network that are not ours; Docker cannot remove a network they still use
other_network_containers() {
  docker network inspect better-stack-collector_default --format '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null |
    tr ' ' '\n' | grep -v -x -e '' -e 'better-stack-collector' | tr '\n' ' ' | sed 's/ $//'
}

adjust_compose_ports docker-compose.yml
adjust_compose_volumes docker-compose.yml
adjust_compose_cpus docker-compose.yml

RECREATE_NETWORK=false
NETWORK_IPV6=$(docker network inspect better-stack-collector_default --format '{{.EnableIPv6}}' 2>/dev/null || true)
if version_lt "$DOCKER_VERSION" "27.0.0"; then
    # Docker older than 27 cannot pick an IPv6 subnet for a network or route it outside without extra daemon settings
    if ipv6_only_host; then
        echo "WARNING: This host has no IPv4 default route, and Docker $DOCKER_VERSION cannot connect the collector over IPv6."
        echo "The collector will not be able to reach Better Stack. Upgrade Docker to version 27 or newer and run this script again."
    fi
elif [ "$NETWORK_IPV6" = "true" ]; then
    # Keep IPv6 on a network that already has it: taking it away again stops the collector on some Compose versions
    enable_compose_ipv6 docker-compose.yml
elif ipv6_only_host; then
    RA_DEVICE=$(kernel_ra_default_route_device)
    OTHER_CONTAINERS=""
    if [ "$NETWORK_IPV6" = "false" ]; then
        OTHER_CONTAINERS=$(other_network_containers)
    fi
    if [ -n "$RA_DEVICE" ]; then
        echo "WARNING: This host has no IPv4 default route, so the collector needs IPv6 on its Docker network."
        echo "Docker would turn on IPv6 forwarding for that, and this host would then lose its IPv6 default route,"
        echo "which it learns from router advertisements on $RA_DEVICE. IPv6 was not enabled and the collector will not"
        echo "be able to reach Better Stack. Set net.ipv6.conf.$RA_DEVICE.accept_ra=2 so that it survives a reboot"
        echo "(for example in /etc/sysctl.d/) and run this script again."
    elif [ -n "$OTHER_CONTAINERS" ]; then
        echo "WARNING: This host has no IPv4 default route, so the collector needs IPv6 on its Docker network."
        echo "The network better-stack-collector_default has to be created again for that, but other containers use it: $OTHER_CONTAINERS"
        echo "IPv6 was not enabled and the collector will not be able to reach Better Stack."
        echo "Disconnect them with 'docker network disconnect better-stack-collector_default <container>' and run this script again."
    else
        echo "Detected an IPv6-only host, enabling IPv6 on the collector network"
        enable_compose_ipv6 docker-compose.yml
        # Compose versions disagree on updating a network that already exists, so an IPv4-only one is removed first
        if [ "$NETWORK_IPV6" = "false" ]; then
            RECREATE_NETWORK=true
        fi
    fi
fi

# Replace :latest tag if IMAGE_TAG is set
if [ -n "$IMAGE_TAG" ]; then
    echo "Replacing :latest with :$IMAGE_TAG in compose file"
    adjust_image_tag docker-compose.yml "$IMAGE_TAG"
fi

if [ "$COMPOSE_CMD" = "docker-compose" ]; then
    docker_v1_compatibility docker-compose.yml
elif version_lt "$COMPOSE_VERSION" "2.15.1"; then
    echo "Docker Compose $COMPOSE_VERSION does not support 'uts' property (requires >= 2.15.1), removing it"
    sed -i.bak '/^[[:space:]]*uts:[[:space:]]/d' docker-compose.yml && rm -f docker-compose.yml.bak
fi

# Pull images first
COLLECTOR_SECRET="$COLLECTOR_SECRET" \
BASE_URL="$BASE_URL" \
CLUSTER_COLLECTOR="$CLUSTER_COLLECTOR" \
ENABLE_DOCKERPROBE="$ENABLE_DOCKERPROBE" \
HOSTNAME="$HOSTNAME" \
COLLECT_OTEL_HTTP_PORT="$COLLECT_OTEL_HTTP_PORT" \
COLLECT_OTEL_GRPC_PORT="$COLLECT_OTEL_GRPC_PORT" \
    $COMPOSE_CMD -p better-stack-collector pull

if [ "$COMPOSE_CMD" = "docker-compose" ]; then
    # On docker-compose v1, try to stop and remove the container first with a 90s grace period
    # This is a workaround for a bug in docker-compose v1 where the container stop grace period is not respected
    $COMPOSE_CMD -p better-stack-collector stop -t 90 || true
fi

# Stop old container names if they exist (for upgrades from older versions:
# the privileged sidecar was previously named better-stack-ebpf, and before that better-stack-beyla)
docker stop better-stack-ebpf 2>/dev/null || true
docker rm better-stack-ebpf 2>/dev/null || true
docker stop better-stack-beyla 2>/dev/null || true
docker rm better-stack-beyla 2>/dev/null || true

if [ "$RECREATE_NETWORK" = true ]; then
    echo "Removing the existing collector network, it will be created again with IPv6"
    $COMPOSE_CMD -p better-stack-collector down
fi

# Run containers
COLLECTOR_SECRET="$COLLECTOR_SECRET" \
BASE_URL="$BASE_URL" \
CLUSTER_COLLECTOR="$CLUSTER_COLLECTOR" \
ENABLE_DOCKERPROBE="$ENABLE_DOCKERPROBE" \
HOSTNAME="$HOSTNAME" \
COLLECT_OTEL_HTTP_PORT="$COLLECT_OTEL_HTTP_PORT" \
COLLECT_OTEL_GRPC_PORT="$COLLECT_OTEL_GRPC_PORT" \
    $COMPOSE_CMD -p better-stack-collector up -d --no-build
