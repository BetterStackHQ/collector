#!/bin/bash

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
RETRY_FROM="${RETRY_FROM:-0}"

# Validate ACTION parameter
if [[ "$ACTION" != "install" && "$ACTION" != "uninstall" && "$ACTION" != "force_upgrade" ]]; then
    print_red "Error: Invalid ACTION parameter: $ACTION"
    echo "Valid actions: install, uninstall, force_upgrade"
    exit 1
fi

# Validate RETRY_FROM parameter
if ! [[ "$RETRY_FROM" =~ ^[0-9]+$ ]]; then
    print_red "Error: RETRY_FROM must be a number"
    exit 1
fi

# Check required environment variables
if [[ -z "${MANAGER_NODE:-}" ]]; then
    print_red "Error: MANAGER_NODE environment variable is required"
    echo "Usage: MANAGER_NODE=user@manager-node COLLECTOR_SECRET=secret [ACTION=install|uninstall|force_upgrade] [RETRY_FROM=N] [SSH_CMD='tsh ssh'] $0"
    exit 1
fi

if [[ -z "${COLLECTOR_SECRET:-}" ]]; then
    print_red "Error: COLLECTOR_SECRET environment variable is required"
    echo "Usage: MANAGER_NODE=user@manager-node COLLECTOR_SECRET=secret [ACTION=install|uninstall|force_upgrade] [RETRY_FROM=N] [SSH_CMD='tsh ssh'] $0"
    exit 1
fi

# Use SSH_CMD from environment or default to ssh
SSH_CMD="${SSH_CMD:-ssh}"
IMAGE_TAG="${IMAGE_TAG:-latest}"

print_blue "Connecting to swarm manager: $MANAGER_NODE"
[[ "$ACTION" != "install" ]] && print_blue "Action: $ACTION"
[[ "$RETRY_FROM" -gt 0 ]] && print_blue "Retrying from node: $RETRY_FROM"
if [[ "$SSH_CMD" != "ssh" ]]; then
    echo "Using SSH command: $SSH_CMD"
fi

# Clear any one-time SSH authentication prompts
print_blue "Testing SSH connectivity to manager node..."
${SSH_CMD} "$MANAGER_NODE" "echo 'SSH connection established'" </dev/null >/dev/null 2>&1

# Get list of all swarm nodes
print_blue "Getting list of swarm nodes..."
echo "Running: $SSH_CMD $MANAGER_NODE 'docker node ls'"
echo

# Capture both stdout and stderr, redirect stdin from /dev/null to prevent SSH from reading the script
NODES=$(${SSH_CMD} "$MANAGER_NODE" "docker node ls --format '{{.Hostname}}'" </dev/null 2>&1)
EXIT_CODE=$?

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

# Test SSH connectivity to all nodes before proceeding
# print_blue "Testing SSH connectivity to all nodes..."
# FAILED_NODES=""
# NODE_INDEX=0
# for NODE in $NODES; do
#     ((NODE_INDEX++))
#
#     # Skip nodes before RETRY_FROM for SSH check too
#     if [[ $NODE_INDEX -lt $RETRY_FROM ]]; then
#         echo "⏭ $NODE - skipped"
#         continue
#     fi
#
#     # Extract user from MANAGER_NODE if present
#     if [[ "$MANAGER_NODE" == *"@"* ]]; then
#         SSH_USER="${MANAGER_NODE%%@*}"
#         NODE_TARGET="${SSH_USER}@${NODE}"
#     else
#         NODE_TARGET="$NODE"
#     fi
#
#     if ${SSH_CMD} "$NODE_TARGET" "echo 'SSH OK'" </dev/null >/dev/null 2>&1; then
#         echo "✓ $NODE"
#     else
#         echo "✗ $NODE - SSH connection failed"
#         FAILED_NODES="$FAILED_NODES $NODE"
#     fi
# done

# if [[ -n "$FAILED_NODES" ]]; then
#     print_red "✗ Failed to connect to some nodes:$FAILED_NODES"
#     echo
#     print_blue "Please ensure SSH access is configured for all swarm nodes."
#     exit 1
# fi

print_green "✓ SSH connectivity confirmed for all nodes"
echo

# For install and force_upgrade actions, set up overlay network BEFORE deploying to nodes
# Skip this if we're retrying from a specific node
if [[ "$ACTION" == "install" || "$ACTION" == "force_upgrade" ]] && [[ "$RETRY_FROM" -eq 0 ]]; then
    print_blue "Creating overlay network..."

    if $SSH_CMD "$MANAGER_NODE" "bash" <<'EOF'
        set -eu

        # Create overlay network if it doesn't exist
        NETWORK_NAME="better_stack_collector_overlay"
        if ! docker network ls | grep -q "$NETWORK_NAME"; then
            echo "Creating overlay network: $NETWORK_NAME"
            docker network create -d overlay --attachable "$NETWORK_NAME"
        else
            echo "Overlay network already exists: $NETWORK_NAME"
        fi
EOF
    then
        print_green "✓ Overlay network ready"
    else
        print_red "✗ Failed to create overlay network"
        exit 1
    fi
    echo
fi

# Deploy beyla to each node first (this creates the enrichment directories)
CURRENT=0
for NODE in $NODES; do
    ((CURRENT++))

    # Skip nodes before RETRY_FROM
    if [[ $CURRENT -lt $RETRY_FROM ]]; then
        print_blue "Skipping node: $NODE ($CURRENT/$NODE_COUNT) - already processed"
        continue
    fi

    # Extract user from MANAGER_NODE if present
    if [[ "$MANAGER_NODE" == *"@"* ]]; then
        SSH_USER="${MANAGER_NODE%%@*}"
        NODE_TARGET="${SSH_USER}@${NODE}"
    else
        NODE_TARGET="$NODE"
    fi

    case "$ACTION" in
        "install")
            print_blue "Installing on node: $NODE ($CURRENT/$NODE_COUNT)"
            ;;
        "uninstall")
            print_blue "Uninstalling from node: $NODE ($CURRENT/$NODE_COUNT)"
            ;;
        "force_upgrade")
            print_blue "Force upgrading on node: $NODE ($CURRENT/$NODE_COUNT)"
            ;;
    esac

    case "$ACTION" in
        "install")
            if $SSH_CMD "$NODE_TARGET" /bin/bash <<EOF
                set -eu
                echo "Setting up Better Stack Beyla..."

                # Create directory for enrichment data sharing
                echo "Creating enrichment directory..."
                mkdir -p /var/lib/better-stack/enrichment
                chmod 755 /var/lib/better-stack/enrichment

                # Download beyla docker-compose configuration
                echo "Downloading Beyla docker-compose configuration..."
                curl -sSL https://raw.githubusercontent.com/BetterStackHQ/collector/refs/heads/sl/swarm_separate_cluster_collector_image/swarm/docker-compose.beyla.yml \\
                    -o /tmp/docker-compose.beyla.yml

                # Update image tag if specified
                if [[ -n "\${IMAGE_TAG:-}" ]]; then
                    echo "Updating Beyla image tag to: \${IMAGE_TAG}"
                    sed -i "s|image: betterstack/collector-beyla:latest|image: betterstack/collector-beyla:\${IMAGE_TAG}|" /tmp/docker-compose.beyla.yml
                fi

                # Start beyla container
                echo "Starting Beyla container..."
                export HOSTNAME=\$(hostname)
                cd /tmp
                HOSTNAME="\$HOSTNAME" \\
                docker compose -p better-stack-beyla -f docker-compose.beyla.yml pull --policy always
                HOSTNAME="\$HOSTNAME" \\
                docker compose -p better-stack-beyla -f docker-compose.beyla.yml up -d --force-recreate

                echo "Checking deployment status..."
                docker ps --filter "name=better-stack" --format "table {{.Names}}\t{{.Status}}"
EOF
            then
                print_green "✓ Better Stack Beyla installed on $NODE"
            else
                print_red "✗ Failed to install on $NODE"
                echo
                print_blue "You can retry from current node using RETRY_FROM=$CURRENT"
                exit 1
            fi
            ;;

        "uninstall")
            if $SSH_CMD "$NODE_TARGET" /bin/bash <<EOF
                set -e
                echo "Stopping and removing Better Stack Beyla..."
                # Use project name to stop containers
                docker compose -p better-stack-beyla down 2>/dev/null || true
                # Also try to stop named container if it exists
                docker stop better-stack-beyla 2>/dev/null || true
                docker rm better-stack-beyla 2>/dev/null || true
                echo "Beyla container removed."
EOF
            then
                print_green "✓ Better Stack Beyla uninstalled from $NODE"
            else
                print_red "✗ Failed to uninstall from $NODE"
                echo
                print_blue "You can retry from current node using RETRY_FROM=$CURRENT"
                exit 1
            fi
            ;;

        "force_upgrade")
            if $SSH_CMD "$NODE_TARGET" /bin/bash <<EOF
                set -e
                echo "Stopping and removing Better Stack Beyla..."
                # Use project name to stop containers
                docker compose -p better-stack-beyla down 2>/dev/null || true
                # Also try to stop named container if it exists
                docker stop better-stack-beyla 2>/dev/null || true
                docker rm better-stack-beyla 2>/dev/null || true

                echo "Container removed. Waiting 3 seconds..."
                sleep 3

                echo "Setting up Better Stack Beyla..."

                # Create directory for enrichment data sharing
                echo "Creating enrichment directory..."
                mkdir -p /var/lib/better-stack/enrichment
                chmod 755 /var/lib/better-stack/enrichment

                # Download beyla docker-compose configuration
                echo "Downloading Beyla docker-compose configuration..."
                curl -sSL https://raw.githubusercontent.com/BetterStackHQ/collector/refs/heads/sl/swarm_separate_cluster_collector_image/swarm/docker-compose.beyla.yml \\
                    -o /tmp/docker-compose.beyla.yml

                # Update image tag if specified
                if [[ -n "\${IMAGE_TAG:-}" ]]; then
                    echo "Updating Beyla image tag to: \${IMAGE_TAG}"
                    sed -i "s|image: betterstack/collector-beyla:latest|image: betterstack/collector-beyla:\${IMAGE_TAG}|" /tmp/docker-compose.beyla.yml
                fi

                # Pull latest image and start container
                echo "Pulling latest image and starting container..."
                export HOSTNAME=\$(hostname)
                cd /tmp
                HOSTNAME="\$HOSTNAME" \\
                docker compose -p better-stack-beyla -f docker-compose.beyla.yml pull --policy always
                HOSTNAME="\$HOSTNAME" \\
                docker compose -p better-stack-beyla -f docker-compose.beyla.yml up -d --force-recreate

                echo "Checking deployment status..."
                docker ps --filter "name=better-stack" --format "table {{.Names}}\t{{.Status}}"
EOF
            then
                print_green "✓ Better Stack Beyla force upgraded on $NODE"
            else
                print_red "✗ Failed to force upgrade on $NODE"
                echo
                print_blue "You can retry from current node using RETRY_FROM=$CURRENT"
                exit 1
            fi
            ;;
    esac
    echo

done

# Now deploy collector swarm service after all nodes have beyla (and enrichment directories)
if [[ "$ACTION" == "install" || "$ACTION" == "force_upgrade" ]]; then
    print_blue "Deploying collector swarm service..."

    # Pass SWARM_NETWORKS, IMAGE_TAG, and other environment variables to the remote script
    if $SSH_CMD "$MANAGER_NODE" "ACTION='${ACTION}' SWARM_NETWORKS='${SWARM_NETWORKS:-}' IMAGE_TAG='${IMAGE_TAG:-latest}' COLLECTOR_SECRET='${COLLECTOR_SECRET}' BASE_URL='${BASE_URL:-}' CLUSTER_COLLECTOR='${CLUSTER_COLLECTOR:-}' PROXY_PORT='${PROXY_PORT:-}' bash" <<'EOF'

        # Determine which networks to attach collector to
        if [[ -n "$SWARM_NETWORKS" ]]; then
            # User specified networks - ensure better_stack_collector_overlay is included
            echo "Using user-specified networks: $SWARM_NETWORKS"
            if [[ "$SWARM_NETWORKS" != *"better_stack_collector_overlay"* ]]; then
                SELECTED_NETWORKS="better_stack_collector_overlay,$SWARM_NETWORKS"
            else
                SELECTED_NETWORKS="$SWARM_NETWORKS"
            fi
        else
            # Auto-detect overlay networks (excluding our own, ingress, and stack-created networks)
            echo "Auto-detecting swarm overlay networks..."
            OVERLAY_NETWORKS=$(docker network ls --filter driver=overlay --filter scope=swarm --format "{{.Name}}" | grep -v "^better_stack_collector_overlay$" | grep -v "^ingress$" | grep -v "^better-stack_default$" | sort)

            if [[ -n "$OVERLAY_NETWORKS" ]]; then
                # Count networks (not including better_stack_collector_overlay)
                NETWORK_COUNT=$(echo "$OVERLAY_NETWORKS" | grep -c .)

                echo "Found $NETWORK_COUNT additional swarm overlay networks (excluding better_stack_collector_overlay):"
                echo "$OVERLAY_NETWORKS" | sed 's/^/  - /'
                echo

                if [[ $NETWORK_COUNT -gt 2 ]]; then
                    echo "ERROR: More than 2 additional swarm overlay networks found!"
                    echo "Please specify which networks to attach to using:"
                    echo "  SWARM_NETWORKS=network1,network2 $0"
                    echo
                    echo "Example:"
                    echo "  SWARM_NETWORKS=my_app_network,frontend_network $0"
                    exit 1
                fi

                # Use all networks plus our own
                ADDITIONAL_NETS=$(echo "$OVERLAY_NETWORKS" | paste -sd, -)
                SELECTED_NETWORKS="better_stack_collector_overlay,$ADDITIONAL_NETS"
            else
                # Only our network exists
                SELECTED_NETWORKS="better_stack_collector_overlay"
            fi

            echo "Will attach collector to networks: $SELECTED_NETWORKS"
        fi

        # Export for use in compose file generation
        export SELECTED_NETWORKS
        echo "SELECTED_NETWORKS=$SELECTED_NETWORKS"

        # Download and deploy collector to swarm
        echo "Downloading swarm compose file for collector..."
        # TODO: Update this URL to main branch once merged
        if ! curl -fsSL https://raw.githubusercontent.com/BetterStackHQ/collector/refs/heads/sl/swarm_separate_cluster_collector_image/swarm/docker-compose.swarm-collector.yml \
            -o /tmp/docker-compose.swarm-collector.yml; then
            echo "ERROR: Failed to download compose file"
            exit 1
        fi

        # Update image tag
        sed -i "s|image: betterstack/collector:latest|image: betterstack/collector:${IMAGE_TAG}|" /tmp/docker-compose.swarm-collector.yml

        # Modify the compose file to add selected networks
        echo "Configuring networks in compose file..."

        # Replace the single network under services with our list
        # First, remove the existing networks section under the service
        sed -i '/^    networks:/,/^    ports:/{/^    networks:/d; /^        better_stack_collector_overlay:/,/^            - collector/d}' /tmp/docker-compose.swarm-collector.yml

        # Add our networks after the volumes section
        # Find the line with the last volume entry and add networks after it
        awk -v networks="$SELECTED_NETWORKS" '
        /^      - \/var\/lib\/better-stack\/enrichment:\/enrichment:rw$/ {
            print
            print "    networks:"
            split(networks, arr, ",")
            for (i in arr) {
                print "        " arr[i] ":"
                if (arr[i] == "better_stack_collector_overlay") {
                    print "          aliases:"
                    print "            - collector"
                }
            }
            next
        }
        { print }
        ' /tmp/docker-compose.swarm-collector.yml > /tmp/compose_temp.yml
        mv /tmp/compose_temp.yml /tmp/docker-compose.swarm-collector.yml

        # Replace the networks section at the bottom
        # Remove everything after "networks:" line
        sed -i '/^networks:/,$d' /tmp/docker-compose.swarm-collector.yml

        # Add the new networks section
        echo "networks:" >> /tmp/docker-compose.swarm-collector.yml
        IFS=','
        for net in $SELECTED_NETWORKS; do
            echo "  $net:" >> /tmp/docker-compose.swarm-collector.yml
            echo "    external: true" >> /tmp/docker-compose.swarm-collector.yml
            echo "    name: $net" >> /tmp/docker-compose.swarm-collector.yml
        done

        echo "Configured compose file with networks: $SELECTED_NETWORKS"

        # Deploy collector to swarm
        echo "Deploying collector to swarm..."
        
        # For force_upgrade, we need to remove the existing stack first to ensure network changes are applied
        if [[ "$ACTION" == "force_upgrade" ]]; then
            echo "Force upgrade mode: Removing existing stack to ensure clean deployment..."
            docker stack rm better-stack 2>/dev/null || true
            echo "Waiting for stack removal..."
            # Wait for the stack to be fully removed
            count=0
            while docker service ls | grep -q "better-stack_"; do
                if [ $count -gt 30 ]; then
                    echo "Warning: Stack removal taking longer than expected"
                    break
                fi
                sleep 1
                ((count++))
            done
            echo "Stack removed. Proceeding with deployment..."
        fi
        
        # Export environment variables for the stack
        export COLLECTOR_SECRET="$COLLECTOR_SECRET"
        export BASE_URL="${BASE_URL:-https://telemetry.betterstack.com}"
        export CLUSTER_COLLECTOR="${CLUSTER_COLLECTOR:-}"
        export HOSTNAME="${HOSTNAME:-}"
        export PROXY_PORT="${PROXY_PORT:-}"
        
        # Deploy with environment variables
        COLLECTOR_SECRET="$COLLECTOR_SECRET" \
        BASE_URL="${BASE_URL:-https://telemetry.betterstack.com}" \
        CLUSTER_COLLECTOR="${CLUSTER_COLLECTOR:-}" \
        HOSTNAME="${HOSTNAME:-}" \
        PROXY_PORT="${PROXY_PORT:-}" \
        docker stack deploy -c /tmp/docker-compose.swarm-collector.yml better-stack

        # Wait briefly for collector service to start
        echo "Waiting for collector service to start..."
        sleep 5

        echo "Collector service status:"
        docker service ls | grep better-stack || echo "No collector service found"
EOF
    then
        print_green "✓ Collector swarm service deployed"
    else
        print_red "✗ Failed to deploy collector swarm service"
        exit 1
    fi
    echo
fi

case "$ACTION" in
    "install")
        print_green "✓ Better Stack Collector deployed to swarm and Beyla installed on all nodes!"
        ;;
    "uninstall")
        print_green "✓ Better Stack Beyla successfully uninstalled from all nodes!"

        # Remove swarm stack and network
        print_blue "Removing collector service and network..."
        if $SSH_CMD "$MANAGER_NODE" /bin/bash <<'EOF'
            set -e

            # Remove swarm stack
            echo "Removing swarm stack..."
            docker stack rm better-stack 2>/dev/null || true


            # Wait for services to be removed
            echo "Waiting for services to be removed..."
            sleep 10

            # Remove overlay network
            NETWORK_NAME="better_stack_collector_overlay"
            if docker network ls | grep -q "$NETWORK_NAME"; then
                echo "Removing overlay network: $NETWORK_NAME"
                docker network rm "$NETWORK_NAME" 2>/dev/null || {
                    echo "Warning: Could not remove network. It may still be in use."
                }
            fi

            echo "Cleanup complete."
EOF
        then
            print_green "✓ Collector service and network removed"
        else
            print_red "✗ Warning: Could not fully remove collector service or network"
        fi
        ;;
    "force_upgrade")
        print_green "✓ Better Stack Collector and Beyla successfully force upgraded!"
        # The collector will be redeployed with proper network configuration
        ;;
esac
