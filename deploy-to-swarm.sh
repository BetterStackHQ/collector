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

# For install and force_upgrade actions, set up overlay network and cluster agent BEFORE deploying to nodes
# Skip this if we're retrying from a specific node
if [[ "$ACTION" == "install" || "$ACTION" == "force_upgrade" ]] && [[ "$RETRY_FROM" -eq 0 ]]; then
    print_blue "Setting up overlay network and cluster agent service..."
    
    # Pass SWARM_NETWORKS and IMAGE_TAG to the remote script
    if $SSH_CMD "$MANAGER_NODE" "SWARM_NETWORKS='${SWARM_NETWORKS:-}' IMAGE_TAG='${IMAGE_TAG:-latest}' bash" <<'EOF'
        set -eu
        
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
            # Auto-detect overlay networks (excluding our own and ingress)
            echo "Auto-detecting swarm overlay networks..."
            OVERLAY_NETWORKS=$(docker network ls --filter driver=overlay --filter scope=swarm --format "{{.Name}}" | grep -v "^better_stack_collector_overlay$" | grep -v "^ingress$" | sort)
            
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
        echo "SELECTED_NETWORKS=$SELECTED_NETWORKS"
        
        # Download latest swarm compose file
        echo "Downloading swarm compose file for cluster agent..."
        # TODO: Update this URL to main branch once merged
        if ! curl -fsSL https://raw.githubusercontent.com/BetterStackHQ/collector/refs/heads/sl/swarm_separate_cluster_collector_image/swarm/docker-compose.swarm-cluster-agent.yml \
            -o /tmp/docker-compose.swarm-cluster-agent.yml; then
            echo "ERROR: Failed to download compose file"
            exit 1
        fi
        
        # Update image tag
        sed -i "s|image: betterstack/collector-cluster-agent:latest|image: betterstack/collector-cluster-agent:${IMAGE_TAG}|" /tmp/docker-compose.swarm-cluster-agent.yml
        
        # Modify the compose file to add selected networks
        echo "Configuring networks in compose file..."
        
        # Replace the single network under services with our list
        # First, remove the existing networks section under the service
        sed -i '/^    networks:/,/^    [^ ]/{/^    networks:/d; /^      - /d;}' /tmp/docker-compose.swarm-cluster-agent.yml
        
        # Add our networks after the environment section
        # Find the line with "environment:" and add networks after its block
        awk -v networks="$SELECTED_NETWORKS" '
        /^    environment:/ { in_env = 1 }
        /^    [^ ]/ && in_env && !/^    environment:/ {
            in_env = 0
            print "    networks:"
            split(networks, arr, ",")
            for (i in arr) {
                print "      - " arr[i]
            }
        }
        { print }
        ' /tmp/docker-compose.swarm-cluster-agent.yml > /tmp/compose_temp.yml
        mv /tmp/compose_temp.yml /tmp/docker-compose.swarm-cluster-agent.yml
        
        # Replace the networks section at the bottom
        # Remove everything after "networks:" line
        sed -i '/^networks:/,$d' /tmp/docker-compose.swarm-cluster-agent.yml
        
        # Add the new networks section
        echo "networks:" >> /tmp/docker-compose.swarm-cluster-agent.yml
        IFS=','
        for net in $SELECTED_NETWORKS; do
            echo "  $net:" >> /tmp/docker-compose.swarm-cluster-agent.yml
            echo "    external: true" >> /tmp/docker-compose.swarm-cluster-agent.yml
            echo "    name: $net" >> /tmp/docker-compose.swarm-cluster-agent.yml
        done
        
        echo "Configured compose file with networks: $SELECTED_NETWORKS"
        
        # Check if cluster agent service already exists
        if docker service ls | grep -q "better-stack_cluster-agent"; then
            echo "Updating existing cluster agent service..."
            docker stack deploy -c /tmp/docker-compose.swarm-cluster-agent.yml better-stack
        else
            echo "Deploying cluster agent to swarm..."
            docker stack deploy -c /tmp/docker-compose.swarm-cluster-agent.yml better-stack
        fi
        
        # Wait briefly for cluster agent to start
        echo "Waiting for cluster agent service to start..."
        sleep 5
        
        echo "Cluster agent service status:"
        docker service ls | grep better-stack || echo "No cluster agent service found"
        
        # Check if the service is actually running
        REPLICAS=$(docker service ls --format "{{.Replicas}}" --filter name=better-stack_cluster-agent | head -1)
        if [[ "$REPLICAS" == "0/1" ]]; then
            echo "ERROR: Cluster agent service is not running!"
            echo "Checking service logs..."
            docker service ps better-stack_cluster-agent --no-trunc
            echo
            echo "Recent events:"
            docker service ps better-stack_cluster-agent --format "table {{.Name}}\t{{.Node}}\t{{.CurrentState}}\t{{.Error}}"
            echo
            echo "Service logs (if any):"
            docker service logs better-stack_cluster-agent --tail 50 2>&1 || echo "No logs available yet"
            echo
            echo "WARNING: Proceeding anyway, but network may not be available on all nodes"
        fi
        
        # Note: The overlay network will become visible on nodes when containers start using it
        echo "Overlay network created and will be available when containers start"
EOF
    then
        print_green "✓ Overlay network and cluster agent service ready"
    else
        print_red "✗ Failed to set up overlay network or cluster agent service"
        exit 1
    fi
    echo
elif [[ "$ACTION" == "install" || "$ACTION" == "force_upgrade" ]] && [[ "$RETRY_FROM" -gt 0 ]]; then
    print_blue "Skipping overlay network and cluster agent setup (RETRY_FROM=$RETRY_FROM)"
    echo
fi

# Deploy to each node
CURRENT=0
for NODE in $NODES; do
    ((CURRENT++))
    
    # Skip nodes before RETRY_FROM
    if [[ $CURRENT -lt $RETRY_FROM ]]; then
        print_blue "Skipping node: $NODE ($CURRENT/$NODE_COUNT) - already processed"
        continue
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
                set -eu
                echo "Setting up Better Stack collector with split architecture..."
                
                # Check if the overlay network is available on this node
                if ! docker network ls | grep -q "better_stack_collector_overlay"; then
                    echo "Note: Overlay network not yet visible on this node"
                    echo "It will become available when the container starts"
                fi
                
                # Download docker-compose.collector-beyla.yml
                echo "Downloading docker-compose configuration..."
                curl -sSL https://raw.githubusercontent.com/BetterStackHQ/collector/refs/heads/sl/swarm_separate_cluster_collector_image/swarm/docker-compose.collector-beyla.yml \\
                    -o /tmp/docker-compose.collector-beyla.yml
                
                # Start collector and beyla containers
                echo "Starting collector and beyla containers..."
                export HOSTNAME=\$(hostname)
                cd /tmp
                COLLECTOR_SECRET="$COLLECTOR_SECRET" HOSTNAME="\$HOSTNAME" \\
                docker compose -p better-stack-collector -f docker-compose.collector-beyla.yml pull
                COLLECTOR_SECRET="$COLLECTOR_SECRET" HOSTNAME="\$HOSTNAME" \\
                docker compose -p better-stack-collector -f docker-compose.collector-beyla.yml up -d

                echo "Checking deployment status..."
                docker ps --filter "name=better-stack" --format "table {{.Names}}\t{{.Status}}"
EOF
            then
                print_green "✓ Better Stack collector installed on $NODE"
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
                echo "Stopping and removing Better Stack containers..."
                # Use project name to stop containers
                docker compose -p better-stack-collector down 2>/dev/null || true
                # Also try to stop named containers if they exist
                docker stop better-stack-collector better-stack-beyla 2>/dev/null || true
                docker rm better-stack-collector better-stack-beyla 2>/dev/null || true
                echo "Containers removed."
EOF
            then
                print_green "✓ Better Stack collector uninstalled from $NODE"
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
                echo "Stopping and removing Better Stack containers..."
                # Use project name to stop containers
                docker compose -p better-stack-collector down 2>/dev/null || true
                # Also try to stop named containers if they exist
                docker stop better-stack-collector better-stack-beyla 2>/dev/null || true
                docker rm better-stack-collector better-stack-beyla 2>/dev/null || true
                
                echo "Containers removed. Waiting 3 seconds..."
                sleep 3
                
                echo "Setting up Better Stack collector with split architecture..."
                
                # Download docker-compose.collector-beyla.yml
                echo "Downloading docker-compose configuration..."
                curl -sSL https://raw.githubusercontent.com/BetterStackHQ/collector/refs/heads/sl/swarm_separate_cluster_collector_image/swarm/docker-compose.collector-beyla.yml \\
                    -o /tmp/docker-compose.collector-beyla.yml
                
                # Add node-specific alias for same-node communication
                # Since beyla is first and uses host network (no aliases), this will only match collector's aliases
                NODE_NAME=\$(hostname)
                sed -i "/aliases:/a\\          - collector-\$NODE_NAME" /tmp/docker-compose.collector-beyla.yml
                
                # Pull latest images and start containers
                echo "Pulling latest images and starting containers..."
                export HOSTNAME=\$(hostname)
                cd /tmp
                COLLECTOR_SECRET="$COLLECTOR_SECRET" HOSTNAME="\$HOSTNAME" \\
                docker compose -p better-stack-collector -f docker-compose.collector-beyla.yml pull
                COLLECTOR_SECRET="$COLLECTOR_SECRET" HOSTNAME="\$HOSTNAME" \\
                docker compose -p better-stack-collector -f docker-compose.collector-beyla.yml up -d

                echo "Checking deployment status..."
                docker ps --filter "name=better-stack" --format "table {{.Names}}\t{{.Status}}"
EOF
            then
                print_green "✓ Better Stack collector force upgraded on $NODE"
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
