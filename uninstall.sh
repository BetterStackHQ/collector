#!/bin/bash
set -e

echo "Uninstalling Better Stack Collector..."

# Check Docker
if ! docker version &> /dev/null; then
    echo "Docker is not installed or not running"
    exit 1
fi

# Check if docker compose v2 is available (happy path)
if docker compose version &> /dev/null 2>&1; then
    echo "Using docker compose v2 to stop and remove services..."
    docker compose -p better-stack-collector down
    echo "Better Stack Collector has been uninstalled successfully."
    exit 0
fi

# Fallback for docker-compose v1 or when compose is not available
echo "Docker Compose v2 not found, using direct Docker commands..."

# Stop and remove containers (eBPF agent first since it depends on collector)
# Handle both old (better-stack-beyla) and new (better-stack-ebpf) container names
for container in better-stack-ebpf better-stack-beyla better-stack-collector; do
    if docker ps -a --format "{{.Names}}" | grep -q "^${container}$"; then
        echo "Stopping container: $container"
        docker stop "$container" 2>/dev/null || true
        echo "Removing container: $container"
        docker rm "$container" 2>/dev/null || true
    fi
done

# Remove the project network
NETWORK_NAME="better-stack-collector_default"
if docker network ls --format "{{.Name}}" | grep -q "^${NETWORK_NAME}$"; then
    echo "Removing network: $NETWORK_NAME"
    docker network rm "$NETWORK_NAME" 2>/dev/null || true
fi

echo "Better Stack Collector has been uninstalled successfully."
