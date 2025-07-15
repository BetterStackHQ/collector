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

# Check required environment variables
if [[ -z "${MANAGER_NODE:-}" ]]; then
    print_red "Error: MANAGER_NODE environment variable is required"
    echo "Usage: MANAGER_NODE=user@manager-node COLLECTOR_SECRET=secret [SSH_CMD='tsh ssh'] $0"
    exit 1
fi

if [[ -z "${COLLECTOR_SECRET:-}" ]]; then
    print_red "Error: COLLECTOR_SECRET environment variable is required"
    echo "Usage: MANAGER_NODE=user@manager-node COLLECTOR_SECRET=secret [SSH_CMD='tsh ssh'] $0"
    exit 1
fi

# Use SSH_CMD from environment or default to ssh
SSH_CMD="${SSH_CMD:-ssh}"

print_blue "Connecting to swarm manager: $MANAGER_NODE"
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

# Deploy to each node
CURRENT=0
for NODE in $NODES; do
    ((CURRENT++))
    print_blue "Deploying to node: $NODE ($CURRENT/$NODE_COUNT)"
    
    # Extract user from MANAGER_NODE if present
    if [[ "$MANAGER_NODE" == *"@"* ]]; then
        SSH_USER="${MANAGER_NODE%%@*}"
        NODE_TARGET="${SSH_USER}@${NODE}"
    else
        NODE_TARGET="$NODE"
    fi
    
    if $SSH_CMD "$NODE_TARGET" /bin/bash <<EOF
        set -e
        echo "Running: docker compose up..."
        curl -sSL https://raw.githubusercontent.com/BetterStackHQ/collector/main/docker-compose.yml | \\
          COLLECTOR_SECRET="$COLLECTOR_SECRET" HOSTNAME=\$(hostname) \\
          docker compose -f - up -d
        
        echo "Checking deployment status..."
        docker ps --filter "name=better-stack" --format "table {{.Names}}\t{{.Status}}"
EOF
    then
        print_green "✓ Better Stack collector deployed to $NODE"
    else
        print_red "✗ Failed to deploy to $NODE"
        exit 1
    fi
    echo
    
done

print_green "✓✓✓ Better Stack collector successfully deployed to all swarm nodes!"