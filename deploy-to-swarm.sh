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
# - ACTION: install (default), uninstall, or force_upgrade
# - SSH_CMD: Custom SSH command (default: ssh), e.g., 'tsh ssh' for Teleport
# - IMAGE_TAG: Docker image tag (default: latest)
# - MOUNT_HOST_PATHS: Comma-separated list of host paths to mount (default: / for entire filesystem)
# - ATTACH_NETWORKS: Comma-separated overlay network names to attach collector to
# - BASE_URL: Better Stack API endpoint (default: https://telemetry.betterstack.com)
# - CLUSTER_COLLECTOR: Enable cluster collector mode (default: false)
# - ENABLE_DOCKERPROBE: Enable Docker container metadata collection (default: true)
# - PROXY_PORT: Optional proxy port for upstream proxy mode
# - COLLECT_OTEL_HTTP_PORT: Port to expose for OTel HTTP ingestion (e.g., 4318)
# - COLLECT_OTEL_GRPC_PORT: Port to expose for OTel gRPC ingestion (e.g., 4317)
#
# Node filtering:
# - To deploy only to specific nodes, label them beforehand:
#   docker node update --label-add better-stack.collector=true <node-name>
# - If any nodes have this label, deployment will be restricted to those nodes only
# - If no nodes have this label, deployment will proceed to all nodes

set -uo pipefail

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
if [[ "$ACTION" != "install" && "$ACTION" != "uninstall" && "$ACTION" != "force_upgrade" ]]; then
    print_red "Error: Invalid ACTION parameter: $ACTION"
    echo "Valid actions: install, uninstall, force_upgrade"
    exit 1
fi

# Check required environment variables
if [[ -z "${MANAGER_NODE:-}" ]]; then
    print_red "Error: MANAGER_NODE environment variable is required"
    echo "Usage: MANAGER_NODE=user@manager-node COLLECTOR_SECRET=secret [ACTION=install|uninstall|force_upgrade] [SSH_CMD='tsh ssh'] $0"
    exit 1
fi

if [[ -z "${COLLECTOR_SECRET:-}" ]]; then
    print_red "Error: COLLECTOR_SECRET environment variable is required"
    echo "Usage: MANAGER_NODE=user@manager-node COLLECTOR_SECRET=secret [ACTION=install|uninstall|force_upgrade] [SSH_CMD='tsh ssh'] $0"
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
PROXY_PORT="${PROXY_PORT:-}"
COLLECT_OTEL_HTTP_PORT="${COLLECT_OTEL_HTTP_PORT:-}"
COLLECT_OTEL_GRPC_PORT="${COLLECT_OTEL_GRPC_PORT:-}"

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
    local proxy_port="$PROXY_PORT"
    local otel_http_port="$COLLECT_OTEL_HTTP_PORT"
    local otel_grpc_port="$COLLECT_OTEL_GRPC_PORT"
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
        PROXY_PORT="$proxy_port" \\
        COLLECT_OTEL_HTTP_PORT="$otel_http_port" \\
        COLLECT_OTEL_GRPC_PORT="$otel_grpc_port" \\
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
        fi

        # Export environment variables
        export HOSTNAME=\$(hostname)
        export ENABLE_DOCKERPROBE="$enable_dockerprobe"

        # Stop old better-stack-beyla service if it exists (for upgrades from older versions)
        echo "Stopping old better-stack-beyla service if present..."
        \$COMPOSE_CMD -p better-stack-beyla down 2>/dev/null || true

        # Pull and start eBPF agent
        echo "Pulling eBPF image..."
        \$COMPOSE_CMD -f docker-compose.yml -p better-stack-ebpf pull

        echo "Starting eBPF agent..."
        \$COMPOSE_CMD -f docker-compose.yml -p better-stack-ebpf up -d

        echo "Checking eBPF agent status..."
        docker ps --filter "name=better-stack-ebpf" --format "table {{.Names}}\t{{.Status}}"
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

        # Try docker-compose first (handle both old and new project names)
        if docker compose version &> /dev/null; then
            docker compose -p better-stack-ebpf down 2>/dev/null || true
            docker compose -p better-stack-beyla down 2>/dev/null || true
        elif docker-compose version &> /dev/null; then
            docker-compose -p better-stack-ebpf down 2>/dev/null || true
            docker-compose -p better-stack-beyla down 2>/dev/null || true
        fi

        # Also try direct container removal as fallback (handle both old and new names)
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
esac
