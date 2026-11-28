#!/bin/bash

# This script deploys Better Stack Collector across a Docker Swarm cluster.
#
# Architecture:
# - Collector is deployed as a Docker Swarm global service (one instance per node)
# - eBPF agent is deployed separately on each node via docker-compose (requires network_mode: host)
# - Communication between collector and eBPF agent happens via Unix sockets on shared /var/lib/better-stack volume
#
# What it does:
# 1. Connects to swarm manager node via SSH
# 2. Creates /var/lib/better-stack directory on all nodes
# 3. Deploys collector as a global swarm service
# 4. Installs eBPF agent on each node via docker-compose
# 5. Optionally attaches collector to overlay networks for service discovery
#
# Required environment variables:
# - MANAGER_NODE: SSH target for swarm manager (format: user@host or host)
# - COLLECTOR_SECRET: Better Stack authentication token
#
# Optional environment variables:
# - ACTION: install (default), uninstall, force_upgrade, or collector_host_only
#   collector_host_only deploys the better-stack-collector-host container on each node again and leaves the
#   collector service alone.
#   It does not need COLLECTOR_SECRET. Use it after you change a node's sizing file.
# - SSH_CMD: Custom SSH command (default: ssh), e.g., 'tsh ssh' for Teleport
# - IMAGE_TAG: Docker image tag (default: latest)
# - MOUNT_HOST_PATHS: Comma-separated list of host paths to mount (default: / for entire filesystem)
# - ATTACH_NETWORKS: Comma-separated overlay network names to attach collector to
# - BASE_URL: Better Stack API endpoint (default: https://telemetry.betterstack.com)
# - CLUSTER_COLLECTOR: Enable cluster collector mode (default: false)
# - ENABLE_DOCKERPROBE: Enable Docker container metadata collection (default: true)
# - COLLECT_OTEL_HTTP_PORT: Port to expose for OTel HTTP ingestion (e.g., 4318)
# - COLLECT_OTEL_GRPC_PORT: Port to expose for OTel gRPC ingestion (e.g., 4317)
# - COLLECT_OTEL_BIND_ADDRESS: Listen address of the OTel receiver (e.g., [::]); unset lets the collector pick it
#
# Size of the better-stack-collector-host container per node:
# - Each node reads its own /var/lib/better-stack/sizing.env, for example:
#     COLLECTOR_HOST_CPUS=2
#     COLLECTOR_HOST_MEM_LIMIT=4096m
# - Keys: COLLECTOR_HOST_CPUS, COLLECTOR_HOST_MEM_LIMIT, COLLECTOR_HOST_MEM_RESERVATION, COLLECTOR_HOST_GOMEMLIMIT, COLLECTOR_HOST_OBI_RESTART_MIB
# - A key that is not in the file keeps its default. The memory values that are not set follow COLLECTOR_HOST_MEM_LIMIT.
# - The collector is one swarm service with one size for all nodes, so COLLECTOR_CPUS, COLLECTOR_MEM_LIMIT and
#   COLLECTOR_MEM_RESERVATION do nothing here.
# - SWARM_SIZING_FILE: A file on this machine with the sizes of many nodes. Each section starts with the
#   node names in brackets, as "docker node ls" prints them, and holds the keys for those nodes:
#     [db-1 db-2]
#     COLLECTOR_HOST_CPUS=2
#     COLLECTOR_HOST_MEM_LIMIT=4096m
#
#     [worker-1]
#     COLLECTOR_HOST_CPUS=3
#   With this file, install, force_upgrade and collector_host_only replace the sizing.env of every node:
#   a node in the file gets its section, and a node that is not in the file gets the defaults.
#
# Node filtering:
# - To deploy only to specific nodes, label them beforehand:
#   docker node update --label-add better-stack.collector=true <node-name>
# - If any nodes have this label, deployment will be restricted to those nodes only
# - If no nodes have this label, deployment will proceed to all nodes

set -uo pipefail

# The whole script is the body of main, which the last line calls. Bash reads a function to its end
# before it runs it, so a download that is cut off, or a file that changes during a run, runs nothing.
# The body is not indented, because the here-documents in it must end at the start of a line.
main() {

# Color support functions
if [[ -t 1 ]] && [[ "${TERM:-}" != "dumb" ]] && command -v tput >/dev/null 2>&1; then
    BOLD=$(tput bold)
    RED=$(tput setaf 1)
    GREEN=$(tput setaf 2)
    BLUE=$(tput setaf 4)
    RESET=$(tput sgr0)
else
    BOLD=""
    RED=""
    GREEN=""
    BLUE=""
    RESET=""
fi

print_red() {
    echo "${BOLD}${RED}$*${RESET}"
}

print_green() {
    echo "${BOLD}${GREEN}$*${RESET}"
}

print_blue() {
    echo "${BOLD}${BLUE}$*${RESET}"
}

# Default action is install
ACTION="${ACTION:-install}"

# Validate ACTION parameter
if [[ "$ACTION" != "install" && "$ACTION" != "uninstall" && "$ACTION" != "force_upgrade" && "$ACTION" != "collector_host_only" ]]; then
    print_red "Error: Invalid ACTION parameter: $ACTION"
    echo "Valid actions: install, uninstall, force_upgrade, collector_host_only"
    exit 1
fi

# Check required environment variables
if [[ -z "${MANAGER_NODE:-}" ]]; then
    print_red "Error: MANAGER_NODE environment variable is required"
    echo "Usage: MANAGER_NODE=user@manager-node COLLECTOR_SECRET=secret [ACTION=install|uninstall|force_upgrade|collector_host_only] [SSH_CMD='tsh ssh'] $0"
    exit 1
fi

# collector_host_only does not touch the collector service, which is the only part that uses the secret
if [[ "$ACTION" != "collector_host_only" && -z "${COLLECTOR_SECRET:-}" ]]; then
    print_red "Error: COLLECTOR_SECRET environment variable is required"
    echo "Usage: MANAGER_NODE=user@manager-node COLLECTOR_SECRET=secret [ACTION=install|uninstall|force_upgrade|collector_host_only] [SSH_CMD='tsh ssh'] $0"
    exit 1
fi

# Optional environment variables with defaults
SSH_CMD="${SSH_CMD:-ssh}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
MOUNT_HOST_PATHS="${MOUNT_HOST_PATHS:-}"
ATTACH_NETWORKS="${ATTACH_NETWORKS:-}"
BASE_URL="${BASE_URL:-https://telemetry.betterstack.com}"
CLUSTER_COLLECTOR="${CLUSTER_COLLECTOR:-false}"
ENABLE_DOCKERPROBE="${ENABLE_DOCKERPROBE:-true}"
COLLECT_OTEL_HTTP_PORT="${COLLECT_OTEL_HTTP_PORT:-}"
COLLECT_OTEL_GRPC_PORT="${COLLECT_OTEL_GRPC_PORT:-}"
COLLECT_OTEL_BIND_ADDRESS="${COLLECT_OTEL_BIND_ADDRESS:-}"
SWARM_SIZING_FILE="${SWARM_SIZING_FILE:-}"

# Shell code that runs on each node before the eBPF agent starts there
IFS= read -r -d '' SIZING_FUNCTIONS <<'SIZING_FUNCTIONS_EOF' || true
# >>> sizing functions (the same text is in install.sh and deploy-to-swarm.sh; keep both copies identical)
# Container sizes. A size comes from the environment, then from the sizing file, then from the default.
# A size from the environment is saved to the sizing file, so the next run keeps it.
SIZING_FILE="${SIZING_FILE:-/var/lib/better-stack/sizing.env}"
SIZING_KEYS="COLLECTOR_CPUS COLLECTOR_MEM_LIMIT COLLECTOR_MEM_RESERVATION COLLECTOR_HOST_CPUS COLLECTOR_HOST_MEM_LIMIT COLLECTOR_HOST_MEM_RESERVATION COLLECTOR_HOST_GOMEMLIMIT COLLECTOR_HOST_OBI_RESTART_MIB"

sizing_fail() {
  echo "Error: $*" >&2
  exit 1
}

sizing_value_valid() {
  local key="$1" value="$2"
  case "$key" in
    *_CPUS) [[ "$value" =~ ^[0-9]+(\.[0-9]+)?$ ]] ;;
    *_MEM_LIMIT|*_MEM_RESERVATION) [[ "$value" =~ ^[0-9]+[mMgG]$ ]] ;;
    COLLECTOR_HOST_GOMEMLIMIT) [[ "$value" =~ ^[0-9]+(MiB|GiB)$ ]] ;;
    COLLECTOR_HOST_OBI_RESTART_MIB) [[ "$value" =~ ^[0-9]+$ ]] ;;
    *) return 1 ;;
  esac
}

sizing_format_hint() {
  case "$1" in
    *_CPUS) echo "a number of CPUs, for example 2 or 1.5" ;;
    *_MEM_LIMIT|*_MEM_RESERVATION) echo "a size in m or g, for example 3072m or 4g" ;;
    COLLECTOR_HOST_GOMEMLIMIT) echo "a size in MiB or GiB, for example 2800MiB" ;;
    COLLECTOR_HOST_OBI_RESTART_MIB) echo "a whole number of MiB, for example 2900" ;;
  esac
}

# Prints a memory size such as 2048m or 4g as a number of MiB
sizing_mib() {
  local number="${1%[mMgG]}"
  case "$1" in
    *[gG]) echo $((number * 1024)) ;;
    *) echo "$number" ;;
  esac
}

# The Docker daemon's own counts are the ones it checks a limit against
sizing_host_cpus() {
  docker info --format '{{.NCPU}}' 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || true
}

sizing_host_mem_mib() {
  local bytes
  bytes="$(docker info --format '{{.MemTotal}}' 2>/dev/null || true)"
  if [[ "$bytes" =~ ^[0-9]+$ ]] && [ "$bytes" -gt 0 ]; then
    echo $((bytes / 1048576))
  else
    awk '/^MemTotal:/ { print int($2 / 1024) }' /proc/meminfo 2>/dev/null || true
  fi
}

# Sets each key in SIZING_KEYS to its value from the environment or the sizing file, or to an empty string.
# The file is read as data and never run as a script.
load_sizing() {
  local key value line from_file from_env=false

  if [ -f "$SIZING_FILE" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      if [[ "$line" =~ ^[[:space:]]*(#.*)?$ ]]; then
        continue
      fi
      if ! [[ "$line" =~ ^[[:space:]]*([A-Z_]+)=([A-Za-z0-9.]*)[[:space:]]*(#.*)?$ ]]; then
        sizing_fail "$SIZING_FILE has a line that is not KEY=value: $line"
      fi
      key="${BASH_REMATCH[1]}"
      value="${BASH_REMATCH[2]}"
      case " $SIZING_KEYS " in
        *" $key "*) ;;
        *) sizing_fail "$SIZING_FILE has an unknown key: $key (known keys: $SIZING_KEYS)" ;;
      esac
      if [ -n "$value" ] && ! sizing_value_valid "$key" "$value"; then
        sizing_fail "$key=$value in $SIZING_FILE is not valid, use $(sizing_format_hint "$key")"
      fi
      printf -v "SIZING_FROM_FILE_$key" '%s' "$value"
    done < "$SIZING_FILE"
  fi

  for key in $SIZING_KEYS; do
    value="${!key:-}"
    from_file="SIZING_FROM_FILE_$key"
    if [ -n "$value" ]; then
      if ! sizing_value_valid "$key" "$value"; then
        sizing_fail "$key=$value is not valid, use $(sizing_format_hint "$key")"
      fi
      if [ "$value" != "${!from_file:-}" ]; then
        from_env=true
      fi
    else
      value="${!from_file:-}"
    fi
    printf -v "$key" '%s' "$value"
  done

  if [ "$from_env" = true ]; then
    save_sizing
  fi
}

# Writes the sizes that were set by hand; a size left out keeps its default on later versions too
save_sizing() {
  local key tmpfile
  tmpfile="$SIZING_FILE.tmp"

  if ! mkdir -p "$(dirname "$SIZING_FILE")" 2>/dev/null || ! : 2>/dev/null > "$tmpfile"; then
    echo "WARNING: Could not write $SIZING_FILE, so the sizes from the environment apply to this run only."
    return 0
  fi
  {
    echo "# Better Stack collector container sizes on this host."
    echo "# The install scripts read this file on every run. Delete a line to get the default again."
    for key in $SIZING_KEYS; do
      if [ -n "${!key}" ]; then
        echo "$key=${!key}"
      fi
    done
  } > "$tmpfile"
  mv "$tmpfile" "$SIZING_FILE"
  echo "Saved container sizes to $SIZING_FILE"
}

# Lowers a CPU limit that is above the host's CPU count: Docker rejects the whole compose file otherwise
sizing_fit_cpus() {
  local key="$1" host_cpus="$2"
  if [[ "$host_cpus" =~ ^[0-9]+$ ]] && awk -v want="${!key}" -v max="$host_cpus" 'BEGIN { exit !(want + 0 > max + 0) }'; then
    echo "The CPU count of this host is $host_cpus, lowering $key from ${!key} to $host_cpus"
    printf -v "$key" '%s' "$host_cpus"
  fi
}

# Sets a default memory limit, lowered to the host's memory when the host has less
sizing_default_mem_limit() {
  local key="$1" default_mib="$2" host_mem_mib="$3"
  if [ -n "${!key}" ]; then
    return 0
  fi
  if [[ "$host_mem_mib" =~ ^[0-9]+$ ]] && [ "$host_mem_mib" -gt 0 ] && [ "$host_mem_mib" -lt "$default_mib" ]; then
    echo "This host has $host_mem_mib MiB of memory, lowering $key from ${default_mib}m to ${host_mem_mib}m"
    default_mib="$host_mem_mib"
  fi
  printf -v "$key" '%s' "${default_mib}m"
}

sizing_check_reservation() {
  local reservation_key="$1" limit_key="$2"
  if [ "$(sizing_mib "${!reservation_key}")" -gt "$(sizing_mib "${!limit_key}")" ]; then
    sizing_fail "$reservation_key=${!reservation_key} is above $limit_key=${!limit_key}, and Docker rejects that"
  fi
}

# Fills in every size that load_sizing left empty and exports all of them for Docker Compose.
# The other memory values of a container follow its memory limit, in the proportions of the defaults.
resolve_sizing() {
  local key host_cpus host_mem_mib limit_mib
  host_cpus="$(sizing_host_cpus)"
  host_mem_mib="$(sizing_host_mem_mib)"

  COLLECTOR_CPUS="${COLLECTOR_CPUS:-1.2}"
  COLLECTOR_HOST_CPUS="${COLLECTOR_HOST_CPUS:-1.0}"
  sizing_fit_cpus COLLECTOR_CPUS "$host_cpus"
  sizing_fit_cpus COLLECTOR_HOST_CPUS "$host_cpus"

  sizing_default_mem_limit COLLECTOR_MEM_LIMIT 1024 "$host_mem_mib"
  limit_mib="$(sizing_mib "$COLLECTOR_MEM_LIMIT")"
  COLLECTOR_MEM_RESERVATION="${COLLECTOR_MEM_RESERVATION:-$((limit_mib / 2))m}"
  sizing_check_reservation COLLECTOR_MEM_RESERVATION COLLECTOR_MEM_LIMIT

  sizing_default_mem_limit COLLECTOR_HOST_MEM_LIMIT 2048 "$host_mem_mib"
  limit_mib="$(sizing_mib "$COLLECTOR_HOST_MEM_LIMIT")"
  COLLECTOR_HOST_MEM_RESERVATION="${COLLECTOR_HOST_MEM_RESERVATION:-$((limit_mib * 3 / 4))m}"
  COLLECTOR_HOST_GOMEMLIMIT="${COLLECTOR_HOST_GOMEMLIMIT:-$((limit_mib * 1400 / 2048))MiB}"
  COLLECTOR_HOST_OBI_RESTART_MIB="${COLLECTOR_HOST_OBI_RESTART_MIB:-$((limit_mib * 1450 / 2048))}"
  sizing_check_reservation COLLECTOR_HOST_MEM_RESERVATION COLLECTOR_HOST_MEM_LIMIT

  for key in $SIZING_KEYS; do
    export "${key?}"
  done
}
# <<< sizing functions
SIZING_FUNCTIONS_EOF

# GitHub raw URL base for downloading compose files
GITHUB_RAW_BASE="https://raw.githubusercontent.com/BetterStackHQ/collector/main"

print_blue "Connecting to swarm manager: $MANAGER_NODE"
[[ "$ACTION" != "install" ]] && print_blue "Action: $ACTION"
if [[ "$SSH_CMD" != "ssh" ]]; then
    echo "Using SSH command: $SSH_CMD"
fi

# Get list of all swarm nodes
print_blue "Getting list of swarm nodes..."
echo "Running: $SSH_CMD $MANAGER_NODE 'docker node ls'"
echo

# Capture both stdout and stderr, redirect stdin from /dev/null to prevent SSH from reading the script
NODES=$(${SSH_CMD} "$MANAGER_NODE" "docker node ls --format '{{.Hostname}}'" </dev/null 2>&1)
EXIT_CODE=$?

# Check for labeled nodes (better-stack.collector=true)
# Note: docker node ls --filter label= doesn't work reliably, so we use docker node inspect
USE_LABELED_NODES=false
if [[ $EXIT_CODE -eq 0 ]]; then
    LABELED_NODES=$(${SSH_CMD} "$MANAGER_NODE" "docker node ls -q | xargs -I{} docker node inspect {} --format '{{if index .Spec.Labels \"better-stack.collector\"}}{{.Description.Hostname}}{{end}}' | grep -v '^\$'" </dev/null 2>&1 || true)
    if [[ -n "$LABELED_NODES" ]]; then
        NODES="$LABELED_NODES"
        USE_LABELED_NODES=true
        print_blue "Found nodes labeled with better-stack.collector=true, restricting deployment to these nodes"
    fi
fi

if [[ $EXIT_CODE -ne 0 ]]; then
    echo "${BOLD}${RED}✗ Failed to connect to $MANAGER_NODE:${RESET}"
    echo "$NODES"
    echo
    print_blue "Please make sure '$SSH_CMD $MANAGER_NODE' works on this machine and $MANAGER_NODE is a swarm manager."
    echo
    print_blue "Need to use different SSH user or command?"
    echo "Customize SSH user and command:"
    echo "  curl -sSL ... | MANAGER_NODE=\"root@host\" SSH_CMD=\"tsh ssh\" COLLECTOR_SECRET=\"...\" bash"
    echo
    exit 1
fi

if [[ -z "$NODES" ]]; then
    print_red "✗ No nodes found in swarm"
    exit 1
fi

# Count non-empty lines only
NODE_COUNT=$(echo "$NODES" | grep -c .)

print_green "✓ Found $NODE_COUNT nodes:"
echo "$NODES"
echo

# Function to get SSH target for a node
get_node_target() {
    local node="$1"
    if [[ "$MANAGER_NODE" == *"@"* ]]; then
        local ssh_user="${MANAGER_NODE%%@*}"
        echo "${ssh_user}@${node}"
    else
        echo "$node"
    fi
}

# Sizes from SWARM_SIZING_FILE: SWARM_SIZING holds one "node KEY=value" line per size,
# and SWARM_SIZING_NODES the nodes that the file names
SWARM_SIZING=""
SWARM_SIZING_NODES=""
SWARM_SIZING_LOADED=false

swarm_sizing_fail() {
    print_red "Error in $SWARM_SIZING_FILE, line $1: $2"
    exit 1
}

# Reads SWARM_SIZING_FILE and stops at the first line that is wrong, before anything is deployed
load_swarm_sizing() {
    local line key value node section_nodes="" in_section=false number=0
    local blank_re='^[[:space:]]*(#.*)?$'
    local section_re='^[[:space:]]*\[([^]]*)\][[:space:]]*(#.*)?$'
    local size_re='^[[:space:]]*([A-Z_]+)=([^[:space:]#]*)[[:space:]]*(#.*)?$'

    if [[ ! -f "$SWARM_SIZING_FILE" ]]; then
        print_red "Error: SWARM_SIZING_FILE is $SWARM_SIZING_FILE, and there is no such file"
        exit 1
    fi
    # The nodes check the same values again with the same functions
    eval "$SIZING_FUNCTIONS"

    while IFS= read -r line || [[ -n "$line" ]]; do
        ((number++))
        if [[ "$line" =~ $blank_re ]]; then
            continue
        fi
        if [[ "$line" =~ $section_re ]]; then
            section_nodes="${BASH_REMATCH[1]}"
            in_section=true
            if [[ -z "${section_nodes// /}" ]]; then
                swarm_sizing_fail "$number" "a section needs at least one node name in the brackets"
            fi
            for node in $section_nodes; do
                if ! echo "$NODES" | grep -q -x -F -- "$node"; then
                    swarm_sizing_fail "$number" "$node is not a node of this deployment (nodes: $(echo $NODES))"
                fi
                if echo "$SWARM_SIZING_NODES" | grep -q -x -F -- "$node"; then
                    swarm_sizing_fail "$number" "$node is already in an earlier section"
                fi
                SWARM_SIZING_NODES="${SWARM_SIZING_NODES}${node}"$'\n'
            done
            continue
        fi
        if ! [[ "$line" =~ $size_re ]]; then
            swarm_sizing_fail "$number" "expected [node names] or KEY=value, found: $line"
        fi
        key="${BASH_REMATCH[1]}"
        value="${BASH_REMATCH[2]}"
        if [[ "$in_section" != true ]]; then
            swarm_sizing_fail "$number" "$key comes before the first [node names] line"
        fi
        case "$key" in
            COLLECTOR_CPUS|COLLECTOR_MEM_LIMIT|COLLECTOR_MEM_RESERVATION)
                swarm_sizing_fail "$number" "$key does nothing on Swarm: the collector is one service with one size for all nodes"
                ;;
        esac
        case " $SIZING_KEYS " in
            *" $key "*) ;;
            *) swarm_sizing_fail "$number" "unknown key $key (keys: $(echo "$SIZING_KEYS" | tr ' ' '\n' | grep '^COLLECTOR_HOST_' | tr '\n' ' '))" ;;
        esac
        if ! sizing_value_valid "$key" "$value"; then
            swarm_sizing_fail "$number" "$key=$value is not valid, use $(sizing_format_hint "$key")"
        fi
        for node in $section_nodes; do
            if echo "$SWARM_SIZING" | grep -q -- "^$node $key="; then
                swarm_sizing_fail "$number" "$key is set twice for $node"
            fi
            SWARM_SIZING="${SWARM_SIZING}${node} ${key}=${value}"$'\n'
        done
    done < "$SWARM_SIZING_FILE"

    SWARM_SIZING_LOADED=true
    print_green "✓ Read sizes for $(echo "$SWARM_SIZING_NODES" | grep -c .) nodes from $SWARM_SIZING_FILE, the other nodes get the defaults"
    echo
}

# Function to deploy collector stack to swarm
deploy_collector_stack() {
    print_blue "Deploying collector stack to swarm..."

    # Build the heredoc with proper escaping
    local image_tag="$IMAGE_TAG"
    local mount_host_paths="$MOUNT_HOST_PATHS"
    local attach_networks="$ATTACH_NETWORKS"
    local collector_secret="$COLLECTOR_SECRET"
    local base_url="$BASE_URL"
    local cluster_collector="$CLUSTER_COLLECTOR"
    local otel_http_port="$COLLECT_OTEL_HTTP_PORT"
    local otel_grpc_port="$COLLECT_OTEL_GRPC_PORT"
    local otel_bind_address="$COLLECT_OTEL_BIND_ADDRESS"
    local use_labeled_nodes="$USE_LABELED_NODES"

    $SSH_CMD "$MANAGER_NODE" /bin/bash <<EOF
        set -e

        # Create temporary directory
        TEMP_DIR=\$(mktemp -d)
        cd "\$TEMP_DIR"
        trap "rm -rf \$TEMP_DIR" EXIT

        # Download collector compose file
        echo "Downloading collector compose file..."
        curl -sSL "${GITHUB_RAW_BASE}/swarm/docker-compose.swarm-collector.yml" -o docker-compose.yml

        # Replace image tag if not latest
        if [ "$image_tag" != "latest" ]; then
            echo "Setting image tag to: $image_tag"
            sed -i "s/:latest/:${image_tag}/g" docker-compose.yml
        fi

        # Add placement constraint if using labeled nodes
        if [ "$use_labeled_nodes" = "true" ]; then
            echo "Adding placement constraint for labeled nodes..."
            # Insert placement constraint after 'mode: global' line using awk for reliable multi-line insertion
            awk '/mode: global/ {
                print
                print "      placement:"
                print "        constraints:"
                print "          - node.labels.better-stack.collector == true"
                next
            } {print}' docker-compose.yml > docker-compose.yml.tmp && mv docker-compose.yml.tmp docker-compose.yml
        fi

        # Handle custom mount paths
        if [ -n "$mount_host_paths" ]; then
            echo "Configuring custom mount paths: $mount_host_paths"
            # Create a temporary file with new mounts
            MOUNT_FILE=\$(mktemp)
            IFS=',' read -ra PATHS <<< "$mount_host_paths"
            for path in "\${PATHS[@]}"; do
                path=\$(echo "\$path" | sed 's/^[[:space:]]*//;s/[[:space:]]*\$//')
                if [ -n "\$path" ]; then
                    path="\${path%/}"
                    cat >> "\$MOUNT_FILE" << MOUNT_ENTRY
      - type: bind
        source: \$path
        target: /host\$path
        read_only: true
MOUNT_ENTRY
                fi
            done

            # Replace the default /:/host mount with custom mounts
            awk -v mounts_file="\$MOUNT_FILE" '
                /source: \// && /target: \/host/ && /read_only: true/ {
                    if (prev ~ /type: bind/) {
                        # Skip the previous "- type: bind" line that was already printed
                        # and the current line, then insert custom mounts
                        while ((getline line < mounts_file) > 0) {
                            print line
                        }
                        close(mounts_file)
                        skip_next = 1
                        next
                    }
                }
                {
                    if (skip_next) {
                        skip_next = 0
                        next
                    }
                    prev = \$0
                    print
                }
            ' docker-compose.yml > docker-compose.yml.tmp
            mv docker-compose.yml.tmp docker-compose.yml
            rm -f "\$MOUNT_FILE"
        fi

        # Handle OTel port exposure
        PORTS_YAML=""
        if [ -n "$otel_http_port" ]; then
            PORTS_YAML="\${PORTS_YAML}
      - $otel_http_port:$otel_http_port"
        fi
        if [ -n "$otel_grpc_port" ]; then
            PORTS_YAML="\${PORTS_YAML}
      - $otel_grpc_port:$otel_grpc_port"
        fi
        if [ -n "\$PORTS_YAML" ]; then
            awk -v ports="\$PORTS_YAML" '
                /^[[:space:]]*volumes:/ && !inserted {
                    print "    ports:" ports
                    inserted=1
                }
                {print}
            ' docker-compose.yml > docker-compose.yml.tmp && mv docker-compose.yml.tmp docker-compose.yml
        fi

        # Auto-detect overlay networks if ATTACH_NETWORKS not specified
        NETWORKS_TO_ATTACH="$attach_networks"
        if [ -z "\$NETWORKS_TO_ATTACH" ]; then
            echo "Auto-detecting overlay networks..."
            NETWORKS_TO_ATTACH=\$(docker network ls --filter driver=overlay --format '{{.Name}}' | grep -v '^ingress\$' | head -5 | tr '\n' ',' | sed 's/,\$//')
            if [ -n "\$NETWORKS_TO_ATTACH" ]; then
                echo "Detected overlay networks: \$NETWORKS_TO_ATTACH"
            else
                echo "No overlay networks detected (besides ingress)"
            fi
        fi

        # Append networks section if we have networks to attach
        if [ -n "\$NETWORKS_TO_ATTACH" ]; then
            echo "" >> docker-compose.yml
            echo "networks:" >> docker-compose.yml

            IFS=',' read -ra NETWORK_ARRAY <<< "\$NETWORKS_TO_ATTACH"
            for network in "\${NETWORK_ARRAY[@]}"; do
                network=\$(echo "\$network" | sed 's/^[[:space:]]*//;s/[[:space:]]*\$//')
                if [ -n "\$network" ]; then
                    echo "  \$network:" >> docker-compose.yml
                    echo "    external: true" >> docker-compose.yml
                fi
            done

            # Add networks to collector service
            sed -i '/^    # Networks are added dynamically/d' docker-compose.yml

            # Build networks section with proper YAML indentation
            NETWORKS_YAML="    networks:"
            for network in "\${NETWORK_ARRAY[@]}"; do
                network=\$(echo "\$network" | sed 's/^[[:space:]]*//;s/[[:space:]]*\$//')
                if [ -n "\$network" ]; then
                    NETWORKS_YAML="\${NETWORKS_YAML}
      - \$network"
                fi
            done

            # Insert networks section after the /var/lib/better-stack volume using awk
            awk -v networks="\$NETWORKS_YAML" '
                /^        target: \/var\/lib\/better-stack\$/ {
                    print
                    print networks
                    next
                }
                {print}
            ' docker-compose.yml > docker-compose.yml.tmp && mv docker-compose.yml.tmp docker-compose.yml
        fi

        echo "Compose file prepared. Deploying stack..."

        # Deploy the stack
        COLLECTOR_SECRET="$collector_secret" \\
        BASE_URL="$base_url" \\
        CLUSTER_COLLECTOR="$cluster_collector" \\
        COLLECT_OTEL_HTTP_PORT="$otel_http_port" \\
        COLLECT_OTEL_GRPC_PORT="$otel_grpc_port" \\
        COLLECT_OTEL_BIND_ADDRESS="$otel_bind_address" \\
            docker stack deploy -c docker-compose.yml better-stack

        # Trigger service reconciliation to schedule tasks on newly labeled nodes
        echo "Reconciling service to pick up node label changes..."
        docker service update better-stack_collector

        echo "Stack deployment initiated."
EOF

    if [[ $? -eq 0 ]]; then
        print_green "✓ Collector stack deployed to swarm"
    else
        print_red "✗ Failed to deploy collector stack"
        exit 1
    fi

    # Wait for services to start
    print_blue "Waiting for collector service to start..."
    sleep 10

    # Check service status
    $SSH_CMD "$MANAGER_NODE" "docker service ls --filter name=better-stack" </dev/null
    echo
}

# Function to deploy eBPF agent to a single node
deploy_ebpf_to_node() {
    local node="$1"
    local node_target
    node_target=$(get_node_target "$node")

    local image_tag="$IMAGE_TAG"
    local enable_dockerprobe="$ENABLE_DOCKERPROBE"

    # Shell code that replaces the node's sizing file with its section of SWARM_SIZING_FILE.
    # A node that the file does not name gets a file with no sizes, so it runs on the defaults.
    # The values passed load_swarm_sizing, so they hold letters, digits and dots only.
    local write_node_sizing="" node_sizes
    if [[ "$SWARM_SIZING_LOADED" == true ]]; then
        node_sizes=$(echo "$SWARM_SIZING" | awk -v node="$node" '$1 == node { print $2 }')
        write_node_sizing="cat > \"\$SIZING_FILE.tmp\" <<'NODE_SIZING_EOF'
# Better Stack collector container sizes on this host.
# Written by deploy-to-swarm.sh from a SWARM_SIZING_FILE. A deploy with such a file replaces this file.
${node_sizes:-# The file has no sizes for this node, so it uses the defaults.}
NODE_SIZING_EOF
mv \"\$SIZING_FILE.tmp\" \"\$SIZING_FILE\"
echo \"Wrote this node's sizes to \$SIZING_FILE\""
    fi

    if $SSH_CMD "$node_target" /bin/bash <<EOF
        set -e

        # Create shared directory for collector/eBPF agent communication (must exist before swarm service starts)
        mkdir -p /var/lib/better-stack
        chmod 755 /var/lib/better-stack

        # Create temporary directory
        TEMP_DIR=\$(mktemp -d)
        cd "\$TEMP_DIR"
        trap "rm -rf \$TEMP_DIR" EXIT

        # Download eBPF compose file
        echo "Downloading eBPF compose file..."
        curl -sSL "${GITHUB_RAW_BASE}/swarm/docker-compose.swarm-ebpf.yml" -o docker-compose.yml

        # Replace image tag if not latest
        if [ "$image_tag" != "latest" ]; then
            echo "Setting image tag to: $image_tag"
            sed -i "s/:latest/:${image_tag}/g" docker-compose.yml
        fi

        # Detect Docker Compose command
        if docker compose version &> /dev/null; then
            COMPOSE_CMD="docker compose"
        elif docker-compose version &> /dev/null; then
            COMPOSE_CMD="docker-compose"
        else
            echo "Error: Docker Compose not found"
            exit 1
        fi

        # Apply v1 compatibility fixes if using docker-compose
        if [ "\$COMPOSE_CMD" = "docker-compose" ]; then
            echo "Applying docker-compose v1 compatibility fixes..."
            # Remove uts: lines (not supported in compose v1)
            sed -i '/^[[:space:]]*uts:[[:space:]]/d' docker-compose.yml
            # Add version header if missing
            if ! grep -q '^version:' docker-compose.yml; then
                sed -i '1i version: "2.4"' docker-compose.yml
            fi
        else
            # Strip uts: for Docker Compose v2 < 2.15.1
            COMPOSE_VERSION=\$(docker compose version --short 2>/dev/null || docker compose version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
            COMPOSE_V_NUM=\$(echo "\$COMPOSE_VERSION" | awk -F. '{printf "%d%02d%02d", \$1, \$2, \$3}')
            if [ "\$COMPOSE_V_NUM" -lt 21501 ]; then
                echo "Docker Compose \$COMPOSE_VERSION does not support 'uts' property (requires >= 2.15.1), removing it"
                sed -i '/^[[:space:]]*uts:[[:space:]]/d' docker-compose.yml
            fi
        fi

        # Export environment variables
        export HOSTNAME=\$(hostname)
        export ENABLE_DOCKERPROBE="$enable_dockerprobe"

        # Container size from this node's sizing file
$SIZING_FUNCTIONS
$write_node_sizing
        load_sizing
        resolve_sizing
        echo "Size of better-stack-collector-host (change it in \$SIZING_FILE on this node and run ACTION=collector_host_only):"
        echo "  CPU limit \$COLLECTOR_HOST_CPUS, memory limit \$COLLECTOR_HOST_MEM_LIMIT, GOMEMLIMIT \$COLLECTOR_HOST_GOMEMLIMIT, OBI restarts above \$COLLECTOR_HOST_OBI_RESTART_MIB MiB"

        # Stop old project names if present (for upgrades from older versions:
        # the agent was previously deployed as better-stack-ebpf, and before that better-stack-beyla)
        echo "Stopping old better-stack-ebpf/better-stack-beyla services if present..."
        \$COMPOSE_CMD -p better-stack-ebpf down 2>/dev/null || true
        \$COMPOSE_CMD -p better-stack-beyla down 2>/dev/null || true

        # Pull and start eBPF agent
        echo "Pulling eBPF image..."
        \$COMPOSE_CMD -f docker-compose.yml -p better-stack-collector-host pull

        echo "Starting eBPF agent..."
        \$COMPOSE_CMD -f docker-compose.yml -p better-stack-collector-host up -d

        echo "Checking eBPF agent status..."
        docker ps --filter "name=better-stack-collector-host" --format "table {{.Names}}\t{{.Status}}"
EOF
    then
        print_green "✓ eBPF agent installed on $node"
    else
        print_red "✗ Failed to install eBPF agent on $node"
        return 1
    fi
}

# Function to uninstall from a single node
uninstall_ebpf_from_node() {
    local node="$1"
    local node_target
    node_target=$(get_node_target "$node")

    if $SSH_CMD "$node_target" /bin/bash <<'EOF'
        set -e

        echo "Stopping and removing eBPF agent container..."

        # Try docker-compose first (handle current and old project names)
        if docker compose version &> /dev/null; then
            docker compose -p better-stack-collector-host down 2>/dev/null || true
            docker compose -p better-stack-ebpf down 2>/dev/null || true
            docker compose -p better-stack-beyla down 2>/dev/null || true
        elif docker-compose version &> /dev/null; then
            docker-compose -p better-stack-collector-host down 2>/dev/null || true
            docker-compose -p better-stack-ebpf down 2>/dev/null || true
            docker-compose -p better-stack-beyla down 2>/dev/null || true
        fi

        # Also try direct container removal as fallback (handle current and old names)
        docker stop better-stack-collector-host 2>/dev/null || true
        docker rm better-stack-collector-host 2>/dev/null || true
        docker stop better-stack-ebpf 2>/dev/null || true
        docker rm better-stack-ebpf 2>/dev/null || true
        docker stop better-stack-beyla 2>/dev/null || true
        docker rm better-stack-beyla 2>/dev/null || true

        echo "eBPF agent removed."
EOF
    then
        print_green "✓ eBPF agent uninstalled from $node"
    else
        print_red "✗ Failed to uninstall eBPF agent from $node"
        return 1
    fi
}

# Function to uninstall collector stack
uninstall_collector_stack() {
    print_blue "Removing collector stack from swarm..."

    if $SSH_CMD "$MANAGER_NODE" "docker stack rm better-stack" </dev/null; then
        print_green "✓ Collector stack removed"
    else
        print_red "✗ Failed to remove collector stack"
        return 1
    fi

    # Wait for services to be removed
    sleep 5
}

if [[ -n "$SWARM_SIZING_FILE" && ( "$ACTION" == "install" || "$ACTION" == "force_upgrade" || "$ACTION" == "collector_host_only" ) ]]; then
    load_swarm_sizing
fi

# Check for existing compose-mode installations on target nodes
if [[ "$ACTION" == "install" || "$ACTION" == "force_upgrade" || "$ACTION" == "collector_host_only" ]]; then
    print_blue "Checking for existing compose-mode installations..."
    COMPOSE_NODES=""
    for NODE in $NODES; do
        node_target=$(get_node_target "$NODE")
        # Match the container name exactly: the docker ps name filter is a substring match,
        # and swarm nodes run the better-stack-collector-host container which would trip it.
        COMPOSE_CONTAINER=$(${SSH_CMD} "$node_target" "docker ps --format '{{.Names}}' | grep -x better-stack-collector" </dev/null 2>/dev/null || true)
        if [[ -n "$COMPOSE_CONTAINER" ]]; then
            COMPOSE_NODES="${COMPOSE_NODES:+$COMPOSE_NODES, }$NODE"
        fi
    done
    if [[ -n "$COMPOSE_NODES" ]]; then
        print_red "Error: Better Stack collector is already installed via docker-compose on: $COMPOSE_NODES"
        echo "Please uninstall the compose deployment first (docker compose -p better-stack-collector down) before deploying via Swarm."
        exit 1
    fi
    print_green "✓ No existing compose-mode installations found"
    echo
fi

# Main execution
case "$ACTION" in
    "install")
        # Deploy eBPF agent to each node first (this also creates /var/lib/better-stack directory)
        CURRENT=0
        for NODE in $NODES; do
            ((CURRENT++))
            print_blue "Installing eBPF agent on node: $NODE ($CURRENT/$NODE_COUNT)"
            if ! deploy_ebpf_to_node "$NODE"; then
                print_red "Aborting deployment due to eBPF agent installation failure on $NODE"
                exit 1
            fi
            echo
        done

        # Deploy collector stack (requires /var/lib/better-stack to exist on all nodes)
        deploy_collector_stack

        print_green "✓ Better Stack collector successfully installed on all swarm nodes!"
        echo
        print_blue "Collector is running as a Docker Swarm global service."
        print_blue "eBPF agent is running as docker-compose on each node."
        ;;

    "uninstall")
        # Uninstall eBPF agent from each node first
        CURRENT=0
        for NODE in $NODES; do
            ((CURRENT++))
            print_blue "Uninstalling eBPF agent from node: $NODE ($CURRENT/$NODE_COUNT)"
            uninstall_ebpf_from_node "$NODE"
            echo
        done

        # Remove collector stack
        uninstall_collector_stack

        print_green "✓ Better Stack collector successfully uninstalled from all swarm nodes!"
        ;;

    "force_upgrade")
        print_blue "Force upgrading Better Stack collector..."
        echo

        # Remove collector stack first
        uninstall_collector_stack

        # Uninstall eBPF agent from each node
        CURRENT=0
        for NODE in $NODES; do
            ((CURRENT++))
            print_blue "Removing eBPF agent from node: $NODE ($CURRENT/$NODE_COUNT)"
            uninstall_ebpf_from_node "$NODE"
            echo
        done

        print_blue "Waiting for cleanup..."
        sleep 5

        # Deploy eBPF agent to each node first (this also creates /var/lib/better-stack directory)
        CURRENT=0
        for NODE in $NODES; do
            ((CURRENT++))
            print_blue "Installing eBPF agent on node: $NODE ($CURRENT/$NODE_COUNT)"
            if ! deploy_ebpf_to_node "$NODE"; then
                print_red "Aborting force upgrade due to eBPF agent installation failure on $NODE"
                exit 1
            fi
            echo
        done

        # Deploy collector stack
        deploy_collector_stack

        print_green "✓ Better Stack collector successfully force upgraded on all swarm nodes!"
        ;;

    "collector_host_only")
        CURRENT=0
        for NODE in $NODES; do
            ((CURRENT++))
            print_blue "Deploying eBPF agent on node: $NODE ($CURRENT/$NODE_COUNT)"
            if ! deploy_ebpf_to_node "$NODE"; then
                print_red "Aborting due to eBPF agent deployment failure on $NODE"
                exit 1
            fi
            echo
        done

        print_green "✓ eBPF agent deployed on all swarm nodes. The collector service was not changed."
        ;;
esac

}

main "$@"
