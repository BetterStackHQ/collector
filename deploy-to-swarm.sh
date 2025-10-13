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

# Use SSH_CMD from environment or default to ssh
SSH_CMD="${SSH_CMD:-ssh}"
IMAGE_TAG="${IMAGE_TAG:-latest}"

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

# For install action, set up overlay network and cluster agent first
if [[ "$ACTION" == "install" ]]; then
    print_blue "Setting up overlay network and cluster agent service..."
    
    # Pass SWARM_NETWORKS to the remote script
    if $SSH_CMD "$MANAGER_NODE" SWARM_NETWORKS="${SWARM_NETWORKS:-}" /bin/bash <<'EOF'
        set -e
        
        # Create overlay network if it doesn't exist
        NETWORK_NAME="better_stack_collector_overlay"
        if ! docker network ls | grep -q "$NETWORK_NAME"; then
            echo "Creating overlay network: $NETWORK_NAME"
            docker network create -d overlay --attachable "$NETWORK_NAME"
        else
            echo "Overlay network already exists: $NETWORK_NAME"
        fi
        
        # Determine which networks to attach cluster agent to
        if [[ -n "$SWARM_NETWORKS" ]]; then
            # User specified networks - ensure better_stack_collector_overlay is included
            echo "Using user-specified networks: $SWARM_NETWORKS"
            if [[ "$SWARM_NETWORKS" != *"better_stack_collector_overlay"* ]]; then
                SELECTED_NETWORKS="better_stack_collector_overlay,$SWARM_NETWORKS"
            else
                SELECTED_NETWORKS="$SWARM_NETWORKS"
            fi
        else
            # Auto-detect overlay networks (excluding our own)
            echo "Auto-detecting swarm overlay networks..."
            OVERLAY_NETWORKS=$(docker network ls --filter driver=overlay --filter scope=swarm --format "{{.Name}}" | grep -v "^better_stack_collector_overlay$" | sort)
            
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
            
            echo "Will attach cluster agent to networks: $SELECTED_NETWORKS"
        fi
        
        # Export for use in compose file generation
        export SELECTED_NETWORKS
        
        # Download latest swarm compose file
        echo "Downloading swarm compose file for cluster agent..."
        curl -sSL https://raw.githubusercontent.com/BetterStackHQ/collector/main/swarm/docker-compose.swarm-cluster-agent.yml \
            -o /tmp/docker-compose.swarm-cluster-agent.yml
        
        # Modify the compose file to add selected networks
        echo "Configuring networks in compose file..."
        
        # Create a temporary file with the network configuration
        cat > /tmp/networks_service.txt <<EOF
    networks:
EOF
        IFS=','
        for net in $SELECTED_NETWORKS; do 
            echo "      - $net" >> /tmp/networks_service.txt
        done
        
        # Create networks definitions
        cat > /tmp/networks_definition.txt <<EOF

networks:
EOF
        IFS=','
        for net in $SELECTED_NETWORKS; do 
            cat >> /tmp/networks_definition.txt <<EOF
  $net:
    external: true
    name: $net
EOF
        done
        
        # Replace the networks section in the service (between 'networks:' and next section)
        awk '
        BEGIN { in_networks = 0 }
        /^    networks:/ { in_networks = 1; next }
        /^    [^ ]/ && in_networks { 
            in_networks = 0
            system("cat /tmp/networks_service.txt")
        }
        !in_networks { print }
        ' /tmp/docker-compose.swarm-cluster-agent.yml > /tmp/compose_temp.yml
        
        # Replace the networks definition section at the end
        awk '
        /^networks:/ { found_networks = 1 }
        !found_networks { print }
        END { system("cat /tmp/networks_definition.txt") }
        ' /tmp/compose_temp.yml > /tmp/docker-compose.swarm-cluster-agent.yml
        
        # Clean up temp files
        rm -f /tmp/networks_service.txt /tmp/networks_definition.txt /tmp/compose_temp.yml
        
        echo "Configured compose file with networks: $SELECTED_NETWORKS"
        
        # Check if cluster agent service already exists
        if docker service ls | grep -q "better-stack_cluster-agent"; then
            echo "Updating existing cluster agent service..."
            docker stack deploy -c /tmp/docker-compose.swarm-cluster-agent.yml better-stack
            echo "Waiting for service update to complete..."
            sleep 10
        else
            echo "Deploying cluster agent to swarm..."
            docker stack deploy -c /tmp/docker-compose.swarm-cluster-agent.yml better-stack
            echo "Waiting for cluster agent service to start..."
            sleep 10
        fi
        
        echo "Cluster agent service status:"
        docker service ls | grep better-stack || echo "No cluster agent service found"
EOF
    then
        print_green "✓ Overlay network and cluster agent service ready"
    else
        print_red "✗ Failed to set up overlay network or cluster agent service"
        exit 1
    fi
    echo
fi

# For uninstall action, remove swarm stack and network after nodes are cleaned
if [[ "$ACTION" == "uninstall" ]]; then
    CLEANUP_SWARM=true
fi

# Deploy to each node
CURRENT=0
for NODE in $NODES; do
    ((CURRENT++))
    
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

    # Extract user from MANAGER_NODE if present
    if [[ "$MANAGER_NODE" == *"@"* ]]; then
        SSH_USER="${MANAGER_NODE%%@*}"
        NODE_TARGET="${SSH_USER}@${NODE}"
    else
        NODE_TARGET="$NODE"
    fi

    case "$ACTION" in
        "install")
            if $SSH_CMD "$NODE_TARGET" /bin/bash <<EOF
                set -e
                echo "Setting up Better Stack collector with split architecture..."
                
                # Download docker-compose.collector-beyla.yml
                echo "Downloading docker-compose configuration..."
                curl -sSL https://raw.githubusercontent.com/BetterStackHQ/collector/main/swarm/docker-compose.collector-beyla.yml \\
                    -o /tmp/docker-compose.collector-beyla.yml
                
                # Create directory for compose file
                mkdir -p /opt/better-stack
                mv /tmp/docker-compose.collector-beyla.yml /opt/better-stack/
                
                # Start collector and beyla containers
                echo "Starting collector and beyla containers..."
                cd /opt/better-stack
                export HOSTNAME=\$(hostname)
                COLLECTOR_SECRET="$COLLECTOR_SECRET" HOSTNAME="\$HOSTNAME" \\
                docker compose -f docker-compose.collector-beyla.yml pull
                COLLECTOR_SECRET="$COLLECTOR_SECRET" HOSTNAME="\$HOSTNAME" \\
                docker compose -f docker-compose.collector-beyla.yml up -d

                echo "Checking deployment status..."
                docker ps --filter "name=better-stack" --format "table {{.Names}}\t{{.Status}}"
EOF
            then
                print_green "✓ Better Stack collector installed on $NODE"
            else
                print_red "✗ Failed to install on $NODE"
                exit 1
            fi
            ;;
            
        "uninstall")
            if $SSH_CMD "$NODE_TARGET" /bin/bash <<EOF
                set -e
                echo "Stopping and removing Better Stack containers..."
                if [ -d /opt/better-stack ]; then
                    cd /opt/better-stack
                    docker compose -f docker-compose.collector-beyla.yml down 2>/dev/null || true
                    cd /
                    rm -rf /opt/better-stack
                else
                    # Fallback: try to stop containers directly
                    docker stop better-stack-collector better-stack-beyla 2>/dev/null || true
                    docker rm better-stack-collector better-stack-beyla 2>/dev/null || true
                fi
                echo "Containers removed."
EOF
            then
                print_green "✓ Better Stack collector uninstalled from $NODE"
            else
                print_red "✗ Failed to uninstall from $NODE"
                exit 1
            fi
            ;;
            
        "force_upgrade")
            if $SSH_CMD "$NODE_TARGET" /bin/bash <<EOF
                set -e
                echo "Stopping and removing Better Stack containers..."
                if [ -d /opt/better-stack ]; then
                    cd /opt/better-stack
                    docker compose -f docker-compose.collector-beyla.yml down 2>/dev/null || true
                else
                    # Fallback: try to stop containers directly
                    docker stop better-stack-collector better-stack-beyla 2>/dev/null || true
                    docker rm better-stack-collector better-stack-beyla 2>/dev/null || true
                fi
                
                echo "Containers removed. Waiting 3 seconds..."
                sleep 3
                
                echo "Setting up Better Stack collector with split architecture..."
                
                # Download docker-compose.collector-beyla.yml
                echo "Downloading docker-compose configuration..."
                curl -sSL https://raw.githubusercontent.com/BetterStackHQ/collector/main/swarm/docker-compose.collector-beyla.yml \\
                    -o /tmp/docker-compose.collector-beyla.yml
                
                # Create directory for compose file
                mkdir -p /opt/better-stack
                mv /tmp/docker-compose.collector-beyla.yml /opt/better-stack/
                
                # Pull latest images and start containers
                echo "Pulling latest images and starting containers..."
                cd /opt/better-stack
                export HOSTNAME=\$(hostname)
                COLLECTOR_SECRET="$COLLECTOR_SECRET" HOSTNAME="\$HOSTNAME" \\
                docker compose -f docker-compose.collector-beyla.yml pull
                COLLECTOR_SECRET="$COLLECTOR_SECRET" HOSTNAME="\$HOSTNAME" \\
                docker compose -f docker-compose.collector-beyla.yml up -d

                echo "Checking deployment status..."
                docker ps --filter "name=better-stack" --format "table {{.Names}}\t{{.Status}}"
EOF
            then
                print_green "✓ Better Stack collector force upgraded on $NODE"
            else
                print_red "✗ Failed to force upgrade on $NODE"
                exit 1
            fi
            ;;
    esac
    echo

done

case "$ACTION" in
    "install")
        print_green "✓ Better Stack collector successfully installed on all swarm nodes!"
        ;;
    "uninstall")
        print_green "✓ Better Stack collector successfully uninstalled from all swarm nodes!"
        
        # Remove swarm stack and network
        print_blue "Removing cluster agent service and network..."
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
            print_green "✓ Cluster agent service and network removed"
        else
            print_red "✗ Warning: Could not fully remove cluster agent service or network"
        fi
        ;;
    "force_upgrade")
        print_green "✓ Better Stack collector successfully force upgraded on all swarm nodes!"
        
        # Also update cluster agent service
        print_blue "Updating cluster agent service..."
        if $SSH_CMD "$MANAGER_NODE" /bin/bash <<'EOF'
            set -e
            
            # Update cluster agent service
            if docker service ls | grep -q "better-stack_cluster-agent"; then
                echo "Updating cluster agent service..."
                docker service update --force better-stack_cluster-agent
            else
                echo "No cluster agent service found to update"
            fi
EOF
        then
            print_green "✓ Cluster agent service updated"
        else
            print_red "✗ Warning: Could not update cluster agent service"
        fi
        ;;
esac
