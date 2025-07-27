#!/bin/bash
set -e

# Check Docker
if ! docker version &> /dev/null; then
    echo "Please install Docker"
    exit 1
fi

# Check Docker Compose
if docker compose version &> /dev/null; then
    COMPOSE_CMD="docker compose"
elif docker-compose version &> /dev/null; then
    COMPOSE_CMD="docker-compose"
else
    echo "Please install Docker Compose"
    exit 1
fi

# Check COLLECTOR_SECRET
if [ -z "$COLLECTOR_SECRET" ]; then
    echo "Please set COLLECTOR_SECRET environment variable"
    exit 1
fi

# Set hostname if not provided
HOSTNAME="${HOSTNAME:-$(hostname)}"

# Create temporary directory and cd into it
TEMP_DIR=$(mktemp -d)
cd "$TEMP_DIR"

# Clean up on exit
trap "rm -rf $TEMP_DIR" EXIT

# Download beyla.yaml
curl -sSL https://raw.githubusercontent.com/BetterStackHQ/collector/main/beyla.yaml \
    -o beyla.yaml

# Download compose file
curl -sSL https://raw.githubusercontent.com/BetterStackHQ/collector/main/docker-compose.yml \
    -o docker-compose.yml

# Pull images first
COLLECTOR_SECRET="$COLLECTOR_SECRET" HOSTNAME="$HOSTNAME" \
    $COMPOSE_CMD -p better-stack-collector pull

# Run containers
COLLECTOR_SECRET="$COLLECTOR_SECRET" HOSTNAME="$HOSTNAME" \
    $COMPOSE_CMD -p better-stack-collector up -d