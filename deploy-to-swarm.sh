#!/bin/bash

set -euo pipefail

# Check required environment variables
if [[ -z "${SWARM_NODE:-}" ]]; then
    echo "Error: SWARM_NODE environment variable is required"
    echo "Usage: SWARM_NODE=user@manager-node COLLECTOR_SECRET=secret [SSH_CMD='tsh ssh'] $0"
    exit 1
fi

if [[ -z "${COLLECTOR_SECRET:-}" ]]; then
    echo "Error: COLLECTOR_SECRET environment variable is required"
    echo "Usage: SWARM_NODE=user@manager-node COLLECTOR_SECRET=secret [SSH_CMD='tsh ssh'] $0"
    exit 1
fi

# Use SSH_CMD from environment or default to ssh
SSH_CMD="${SSH_CMD:-ssh}"

echo "Connecting to swarm node: $SWARM_NODE"
echo "Using SSH command: $SSH_CMD"

# Get list of all swarm nodes
echo "Getting list of swarm nodes..."
echo "Running: $SSH_CMD $SWARM_NODE 'docker node ls'"

# Capture both stdout and stderr, redirect stdin from /dev/null to prevent SSH from reading the script
NODES=$(${SSH_CMD} "$SWARM_NODE" "docker node ls --format '{{.Hostname}}'" </dev/null 2>&1)
EXIT_CODE=$?

echo "Exit code: $EXIT_CODE"

if [[ $EXIT_CODE -ne 0 ]]; then
    echo
    echo "Failed to connect to $SWARM_NODE (exit code: $EXIT_CODE)"
    echo
    echo "Error output:"
    echo "$NODES"
    echo
    echo "Please make sure '$SSH_CMD $SWARM_NODE' works on this machine and the server is a swarm manager."
    echo
    echo "Need to use different SSH user or command?"
    echo "Example: SWARM_NODE=\"user@host\" SSH_CMD=\"tsh ssh\" COLLECTOR_SECRET=\"...\" $0"
    echo
    exit 1
fi

if [[ -z "$NODES" ]]; then
    echo "Error: No nodes found in swarm"
    exit 1
fi

echo "Found $(echo "$NODES" | wc -l) nodes:"
echo "$NODES"
echo

# Debug: Show what we're about to iterate over
echo "Debug: NODES variable contains:"
echo "$NODES" | cat -A
echo

# Deploy to each node
for NODE in $NODES; do
    echo "Deploying to node: $NODE"
    
    # Extract user from SWARM_NODE if present
    if [[ "$SWARM_NODE" == *"@"* ]]; then
        SSH_USER="${SWARM_NODE%%@*}"
        NODE_TARGET="${SSH_USER}@${NODE}"
    else
        NODE_TARGET="$NODE"
    fi
    
    $SSH_CMD "$NODE_TARGET" /bin/bash <<EOF
        set -e
        echo "Fetching docker-compose.yml..."
        curl -sSL https://raw.githubusercontent.com/BetterStackHQ/collector/main/docker-compose.yml | \\
          COLLECTOR_SECRET="$COLLECTOR_SECRET" HOSTNAME=\$(hostname) \\
          docker compose -f - up -d
        
        echo "Checking deployment status..."
        docker ps --filter "name=better-stack" --format "table {{.Names}}\t{{.Status}}"
        echo "✓ Better Stack collector deployed to \$(hostname)"
        echo
EOF
    
done

echo "✓ Better Stack collector deployed to all swarm nodes"